# 05 - The Jenkins pipeline explained

This document explains the CI (Continuous Integration) pipeline in
[jenkins/Jenkinsfile.groovy](../jenkins/Jenkinsfile.groovy), stage by stage. First the big idea, then every stage
with: **what it does, why, what problem it solves, what makes it fail.**

---

## 1. The big idea

**CI** = every time you finish a piece of code, a robot builds it, tests it, scans it for security problems, and
only if everything is fine prepares it for release. **CD** (Continuous Delivery/Deployment) = another robot puts the
approved release on the servers. Here:

| Job | Tool | Trigger |
|---|---|---|
| CI | **Jenkins** (this pipeline) | you click Build (or a webhook) |
| Approval | **GitHub pull request** | a person clicks **Merge** |
| CD | **Argo CD** | a new commit appears on `main` |

The pipeline **ends** by opening a pull request and telling Slack. It never touches the cluster itself. That is
deliberate: git is the single source of truth, and a human approves every release.

```
code --> [Jenkins: test, scan, build, push images, update image names] --> Pull Request --> merge --> [Argo CD] --> cluster
```

---

## 2. Files involved

| File | Job |
|---|---|
| `jenkins/Jenkinsfile.groovy` | the pipeline: stages in order |
| `jenkins/scripts/sonar-scan.sh` | run SonarQube and check its verdict |
| `jenkins/scripts/create-pr.sh` | commit, push a branch, open the pull request |
| `sonar-project.properties` | SonarQube settings |
| `tests/` and `application/*/tests/` | the tests the stages run |
| `docker-compose.yml` | the test copy of the app |

---

## 3. How to read a Jenkinsfile

```groovy
pipeline {                      // everything lives in here
    agent any                   // run on any Jenkins server (we have one)
    options { ... }             // timeouts, history, one build at a time
    parameters { ... }          // questions Jenkins asks when you press Build
    environment { ... }         // variables available in every stage
    stages { stage('X') { steps { ... } } ... }   // the steps, in order
    post { always {...} success {...} failure {...} }   // what to do at the end
}
```

### The small helper functions at the top
- `bash(...)`: runs shell commands with `set -euo pipefail` = "stop at the first error, treat unset variables and
  failed pipes as errors". Plain `sh` would let a failure inside a pipe pass silently.
- `slack(color, text)`: sends the Slack message with `curl`. If Slack is not configured the build is **not** failed.
- `uploadReportsToS3()`: copies the `reports/` folder to S3.

### Options
| Option | Meaning | Why |
|---|---|---|
| `timestamps()` | time on each log line | find slow steps |
| `timeout(90 minutes)` | kill the build after 90 min | a stuck build cannot block the server forever |
| `disableConcurrentBuilds()` | one build at a time | the test copy of the app uses fixed names and port 18080 |
| `skipDefaultCheckout(true)` | we do the checkout ourselves | so the workspace is cleaned first |
| `buildDiscarder(20)` | keep the last 20 builds | save disk |

### Parameters (the questions asked at "Build with Parameters")
| Name | Default | Meaning |
|---|---|---|
| `GIT_URL` | this repository | what to build |
| `BRANCH` | `release/version1` (or 2, per branch) | which release branch to build |
| `BASE_BRANCH` | `main` | where the pull request goes (Argo CD watches it) |

### Environment
`AWS_REGION`, `PROJECT_NAME` (ECR repos are `<name>-frontend/-backend`), `ARTIFACT_BUCKET` (S3), SonarQube addresses
(`sonarqube:9000` from inside Docker, `localhost:9000` from the server), `COMPOSE_PROJECT_NAME`, `FRONTEND_PORT=18080`
and `BASE_URL`. **Edit these first** if your region, project or bucket differ.

### Credentials used
`sonar-token`, `github-token`, `slack-webhook` (Jenkins "Secret text"). Jenkins hides them in the logs. AWS access
comes from the server's IAM role.

---

## 4. The 19 stages

(The numbered comments inside the Jenkinsfile group "Clean up" and "Checkout" as one step, so they count 18.)

### 1. Clean up
Stops any test copy of the app left by an earlier failed build (`docker compose down -v`) and empties the workspace.
*Problem solved:* old files or containers cannot influence a new build ("works on my machine" surprises).

### 2. Checkout
Downloads the branch from GitHub. Creates the `reports/` folders. Works out:
- `IMAGE_TAG` = build number + commit id, e.g. `12-a1b2c3d`. ECR tags are immutable, so every build needs a new one.
- The ECR address from your AWS account number: `<account>.dkr.ecr.us-east-1.amazonaws.com`.
- The final image names, e.g. `<account>.dkr.ecr...amazonaws.com/school-demo-backend:12-a1b2c3d`.

### 3. Install dependencies
Creates a Python virtual environment (`.venv`, so nothing is installed system-wide), installs test libraries from
`tests/requirements.txt`, and runs `npm install` for the frontend tests.
*Fails when:* a package cannot be downloaded.

### 4. Unit tests
Small, fast tests that need no database or network:
- backend: `pytest` (also writes a coverage report for SonarQube and a results file for Jenkins);
- frontend: `npm test` (loads the real page in a fake browser).
*Why first:* the cheapest and fastest checks run first; there is no point scanning code that does not even pass its
own tests.

### 5. SAST - SonarQube (static code analysis)
SAST = *Static Application Security Testing*: read the **source code** (without running it) looking for bugs,
security weaknesses and code smells. `sonar-scan.sh`:
1. runs the scanner container on the same Docker network as the SonarQube container;
2. waits until SonarQube finishes processing (it works in the background);
3. reads the **Quality Gate** (a pass/fail rule set); **fails the build if the gate is ERROR**.
*Fails when:* the code breaks the quality rules, the token is wrong, or SonarQube is not running.

### 6. Dependency tests
Checks that the *libraries* we use have no known security holes (CVEs):
- `pip-audit` for the Python libraries;
- `npm audit` for the frontend libraries;
- OWASP Dependency-Check (slow the first time: it downloads the vulnerability database, cached in a Docker volume).
A finding makes the build **UNSTABLE (yellow)**, not failed. *Why:* you see the warning but a new CVE in a library
does not stop all work; decide per case.

### 7. Build images
`docker build --platform linux/amd64` for the backend and frontend. `--platform` because the cluster's servers are
x86; building on an ARM laptop would otherwise create images that cannot run.

### 8. Trivy image scan
Trivy opens each built image and checks the operating-system packages and libraries *inside* it for known
vulnerabilities. Two runs: one writes a report of HIGH and CRITICAL findings; one **fails the build on CRITICAL**
findings that have a fix available (`--ignore-unfixed`: nobody can act on a problem with no fix).
*Why before pushing:* a bad image never reaches the registry.

### 9. Push images to ECR
Logs in to ECR (`aws ecr get-login-password | docker login`) and pushes both images. The list is saved to
`reports/images.txt`.

### 10. ECR image scan
ECR scans every pushed image (setting `scan_on_push` in Terraform). The stage waits for the scan to finish
(`aws ecr wait image-scan-complete`), saves the findings and **fails on any CRITICAL**. A second opinion, from AWS.

### 11. Update docker-compose images
`sed` rewrites the `image:` lines of `docker-compose.yml` to the images just pushed. *Why:* the next stage must test
**exactly** the images that will be deployed, not a fresh local build.

### 12. Run docker compose
Starts the whole application (PostgreSQL, backend, frontend) on the Jenkins server on port 18080. `down -v` first
gives an **empty database**, so PostgreSQL really runs `init.sql` and creates the table. Then:
- waits (up to 5 minutes) until `/api/health/ready` answers;
- opens PostgreSQL itself, lists the tables, checks `students` exists and has at least 4 rows.
*Problem solved:* proves the images start, connect to each other and the database is initialised.

### 13. Smoke tests
`tests/smoke/smoke_test.sh`: four quick questions to the running app: does the home page load; does the API answer
through the proxy; does the readiness check pass (database reachable); is the seeded student found? A "smoke test"
asks only "does it catch fire when switched on?".

### 14. Integration tests
`tests/integration/test_api.py` (pytest): registers a new student, then looks them up, checks case-insensitive search,
an unknown student, and error answers. *Why:* it proves frontend, backend and database really work *together*
(writing and reading data).

### 15. DAST - OWASP ZAP
DAST = *Dynamic Application Security Testing*: attack the **running** website from the outside like a hacker's tool
would. ZAP's "baseline" mode is passive and safe: it browses the site and reports missing security headers, risky
cookies and similar problems. Warnings do not fail the build (`-I`), real failures do. The HTML report is saved.

### 16. Load test - JMeter
`tests/jmeter/load-test.jmx`: 10 virtual users, 20 rounds each, hitting the home page, the health check and a student
lookup. The stage counts failed requests in the result file and **fails if any request failed**. It also writes an HTML
report with response times.

### 17. Update Kubernetes manifests
Only reached when everything above passed. `sed` writes the new image names into `kubernetes/backend.yaml` and
`kubernetes/frontend.yaml`. These two changed lines are what Argo CD will deploy.

### 18. Store artifacts in S3
Copies the `reports/` folder (test results, scan reports, ZAP and JMeter reports, table list, image list) to
`s3://<bucket>/artifacts/<job>/<build number>/` and also keeps them on the Jenkins page.
*Problem solved:* evidence that a release was tested stays available even after the Jenkins server is gone.

### 19. Commit and raise pull request
`create-pr.sh`:
1. checks the base branch (`main`) exists on GitHub;
2. creates a branch `ci/images-<build number>` and commits the changed files;
3. pushes it, sending the GitHub token in a header (never in the web address, so it is not written to config or logs);
4. calls the GitHub API to open a pull request into `main` with a description (images, build link, S3 folder);
5. writes the pull request link to `reports/pr-url.txt`.

---

## 5. The `post` section (runs at the end, always)

| Block | What it does |
|---|---|
| `always` | publishes test results and archives reports; uploads reports to S3 if the "Store artifacts in S3" stage never ran (a failed build keeps its evidence); stops the test containers (`docker compose down -v`); deletes the images built here to save disk |
| `success` | Slack: "Pull request raised: <link>. Merge it and Argo CD will deploy." |
| `unstable` | Slack: the PR link plus "UNSTABLE (dependency findings)" |
| `failure` | Slack: "FAILED" with the link to the console log |

---

## 6. What a green run looks like, and what you do next

1. All stages are green (dependency findings may make it yellow).
2. Slack shows the pull request link.
3. Open it, read the diff (only the image lines and anything else that changed), **Squash and merge**.
4. Argo CD deploys it within minutes. Watch with `kubectl get pods -n school-demo -w`.

## 7. Running the pipeline for version 2

Same job, other branch: set the job's branch to `release/version2` (or build with parameter
`BRANCH=release/version2`). Before that, update the branch with `main` (doc 01, Step 9) so the pull request has no
conflicts.

---

## 8. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `docker: permission denied` | the `jenkins` user is not in the docker group | `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| `Unable to locate credentials` (aws) | the server has no IAM role | attach the role from doc 01, Step 1 |
| Sonar stage: `401` | wrong/expired `sonar-token` | create a new token and update the Jenkins credential |
| Sonar stage: connection refused | SonarQube container not running | `docker ps`, `docker start sonarqube` |
| `Base branch 'main' does not exist` | the branch name is wrong | check `BASE_BRANCH` |
| Push rejected / 403 | token lacks *Contents: write* or *Pull requests: write* | recreate the token |
| ECR push `tag invalid, already exists` | the same tag was pushed before | use a new build number (a new build does this) |
| Trivy fails with CRITICAL | a library/OS package has a critical fix | update the base image or library, rebuild |
| JMeter fails | errors under load | open `reports/jmeter/html/index.html` |
| Compose never becomes ready | database or backend crashed | read `reports/compose-logs.txt` |
| Slack does nothing | `slack-webhook` missing | create it; builds still pass |

## 9. Things to know

- The pipeline commits with `git add -A`: everything changed in the workspace goes into the pull request.
  `.gitignore` excludes `reports/`, `.venv/`, `node_modules/` and `.sonar/`. `package-lock.json` created by
  `npm install` is included, which is good.
- Tool versions and Docker image tags (`latest` for the scanners) are not pinned; for a repeatable build, pin them.
- The Dependency-Check stage can be slow; skip it by removing that block if you are in a hurry.
