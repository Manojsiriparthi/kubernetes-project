# 01 - First deployment, step by step

This guide takes you from an empty AWS account to a running website, with a CI pipeline (Jenkins) and automatic
deployment (Argo CD). Every step has the exact commands. If a word is new to you, read the matching document in this
folder (see the list at the bottom).

**The big picture in one paragraph.** You create servers and networks in AWS with Terraform (infrastructure).
Kubernetes (EKS) runs your website. Jenkins checks the code, builds container images, tests them and opens a pull
request that contains the new image names. When you merge that pull request into the `main` branch, Argo CD sees the
change in GitHub and updates the running website by itself.

```
 You push code ──> Jenkins (CI) ──> pull request into main ──> you merge ──> Argo CD (CD) ──> website updated
```

> Cost warning: EKS, 5 servers, a NAT gateway and load balancers cost real money (roughly 300 USD per month if left
> running). Destroy everything when you finish practising (Step 12).

---

## Step 0 - What you need before you start

| You need | Why |
|---|---|
| An AWS account and an IAM user with enough rights (AdministratorAccess is easiest for learning) | Terraform creates the network, cluster, servers |
| A GitHub account and this repository | Jenkins and Argo CD read the code from it |
| One Ubuntu 22.04/24.04 server for Jenkins (recommended: 4 vCPU, 16 GB RAM, 60 GB disk, e.g. EC2 `t3.xlarge`) | Runs Jenkins, SonarQube, Docker and the scanners |
| A Slack workspace (optional) | Receives messages when the pipeline finishes |

Find your own public IP (you will need it in Step 3):

```bash
curl -s ifconfig.me
```

Write it down as `x.x.x.x/32` (the `/32` means "only this one address").

---

## Step 1 - Clone the repository and install the tools

Run everything on the Ubuntu server (it can also be your own Linux machine).

```bash
git clone https://github.com/Manojsiriparthi/kubernetes-project.git
cd kubernetes-project
git switch release/version1          # the branch we deploy first
sudo ./scripts/pre-tools.sh          # installs all tools (takes about 10 minutes)
```

What `pre-tools.sh` installs and starts:

| Tool | Used for | Where it listens |
|---|---|---|
| Docker | builds and runs containers | - |
| Jenkins | the CI pipeline | port 8080 |
| SonarQube (container) | code quality scan (SAST) | port 9000 |
| Prometheus + Grafana (containers) | monitoring of this Jenkins server (the cluster has its own, see doc 06) | 9090, 3000 |
| Terraform, AWS CLI, kubectl, Helm, Argo CD CLI | create and manage the cluster | - |
| Trivy, Node.js 20, Python 3, JMeter | security scan, frontend tests, backend tests, load test | - |

Check that it worked:

```bash
docker --version && terraform version && aws --version && kubectl version --client && helm version --short
sudo docker ps                       # you should see sonarqube, prometheus, grafana running
```

**Give the Jenkins server permission to use AWS.** The pipeline pushes images to ECR and uploads reports to S3. Attach
an IAM role to the server (EC2 console, Instance, Actions, Security, Modify IAM role) with this policy. Replace
`YOUR_BUCKET` with the bucket name from Step 2:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["ecr:GetAuthorizationToken"], "Resource": "*" },
    { "Effect": "Allow",
      "Action": ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
                 "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
                 "ecr:DescribeImageScanFindings", "ecr:DescribeRepositories", "ecr:CreateRepository"],
      "Resource": "arn:aws:ecr:us-east-1:*:repository/school-demo-*" },
    { "Effect": "Allow", "Action": ["s3:PutObject"], "Resource": "arn:aws:s3:::YOUR_BUCKET/artifacts/*" }
  ]
}
```

Test it:

```bash
sudo -u jenkins aws sts get-caller-identity     # must print your account number, not an error
sudo -u jenkins docker ps                       # must work (the jenkins user is in the docker group)
```

If the second command fails, restart Jenkins once: `sudo systemctl restart jenkins`.

---

## Step 2 - Create the place where Terraform keeps its memory (S3 bucket)

Terraform remembers what it created in a "state file". We store it in an S3 bucket so it is safe and versioned.
The repository expects this bucket (see `infra/backend.tf`):

```
school-demo-terraform-state-513263709619-us-east-1
```

That name contains the AWS account number `513263709619`. **If your account number is different, pick your own name**
(bucket names are global, so it must be unique), then change it in two places:

1. `infra/backend.tf`, the `bucket = "..."` line.
2. `jenkins/Jenkinsfile.frontend.groovy`, `jenkins/Jenkinsfile.backend.groovy` and `jenkins/Jenkinsfile.cd.groovy`, the `ARTIFACT_BUCKET = '...'` line in each.

Also replace `513263709619` in the image lines of `kubernetes/backend.yaml` and `kubernetes/frontend.yaml` (the
Jenkins pipeline rewrites those lines later, but the first value must be a real ECR address).

Create the bucket (use your own name):

```bash
BUCKET=school-demo-terraform-state-513263709619-us-east-1
aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

- Versioning keeps old copies of the state, so a mistake can be undone.
- Encryption and "block public access" keep it private.
- The same bucket also stores Jenkins reports, in a different folder: `artifacts/`.

---

## Step 3 - Tell Terraform your values (`infra/terraform.tfvars`)

Create the file `infra/terraform.tfvars` (it is ignored by git on purpose, so your IP is not published):

```hcl
# Who may talk to the Kubernetes API (kubectl, Terraform's Helm steps). Use your own IP with /32.
cluster_endpoint_public_access_cidrs = ["203.0.113.10/32"]

# Who may open Argo CD, Prometheus, Alertmanager and Grafana in a browser. Add your teammates' IPs here too.
team_access_cidrs = ["203.0.113.10/32"]

# Optional. Leave these out if you do not need them.
# alertmanager_slack_webhook_url  = "https://hooks.slack.com/services/XXX/YYY/ZZZ"
# cluster_admin_principal_arns    = ["arn:aws:iam::123456789012:role/PlatformAdmins"]
# cluster_developer_principal_arns = []
# cluster_viewer_principal_arns    = []
```

What these mean (a "CIDR" is just an IP range; `/32` is one address):

| Value | Protects | If you forget it |
|---|---|---|
| `cluster_endpoint_public_access_cidrs` | the Kubernetes API of the cluster | Terraform refuses to start (value is required, and `0.0.0.0/0` is blocked) |
| `team_access_cidrs` | the team tools web pages | same |

Important: **the machine that runs `terraform apply` must be in `cluster_endpoint_public_access_cidrs`**, because
Terraform also installs software into the cluster. If your IP changes later, update the file and apply again.

The other settings (region `us-east-1`, 3 availability zones, node sizes) have good defaults, see doc 02.

---

## Step 4 - Create the infrastructure

The easy way is the helper script. It asks you to type `1` (create) or `2` (destroy):

```bash
./scripts/infra.sh
# Enter 1 or 2: 1
```

It runs, in order: `terraform init`, `terraform fmt`, `terraform validate`, `terraform plan` (shows what will be
created, then asks you to type `yes`), `terraform apply`, then prints the web addresses of the team tools.

The same thing by hand:

```bash
cd infra
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
cd ..
```

It takes 25-40 minutes, mostly waiting for the EKS cluster and the servers. The order is automatic:
network, then the cluster, then the servers (nodes), then the add-ons.

> If the apply stops with an error saying the Helm provider cannot reach the cluster, run
> `terraform -chdir=infra apply -target=module.eks_cluster` once and then run the normal apply again.

**Connect kubectl to the new cluster:**

```bash
aws eks update-kubeconfig --name school-demo-eks --region us-east-1
kubectl get nodes -L workload
```

You should see 5 nodes: 1 `public`, 3 `application`, 1 `database`, all `Ready`. Now look at everything that was
installed:

```bash
kubectl get pods -A
```

Expect pods for `coredns`, `aws-node`, `kube-proxy`, `ebs-csi`, `aws-load-balancer-controller`,
`cluster-autoscaler`, `metrics-server`, `argocd-*` and `kube-prometheus-stack-*` (the last two groups can take a
few more minutes to become `Running`).

---

## Step 5 - Open the team tools

```bash
kubectl get ingress -A
```

Look for the `ADDRESS` column of the Grafana ingress (all team tools share one address, called the "ALB"):

| Tool | Address | Login |
|---|---|---|
| Argo CD | `http://<ALB-ADDRESS>:8080` | user `admin`, password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Grafana | `http://<ALB-ADDRESS>:3000` | user `admin`, password: `terraform -chdir=infra output -raw grafana_admin_password` |
| Prometheus | `http://<ALB-ADDRESS>:9090` | none (protected by your IP only) |
| Alertmanager | `http://<ALB-ADDRESS>:9093` | none (protected by your IP only) |

Only the IPs in `team_access_cidrs` can open them. The ALB takes a few minutes to start answering.

---

## Step 6 - Tell Argo CD which repository and branch to watch

```bash
kubectl apply -f argocd/application.yaml
```

This file ([argocd/application.yaml](../argocd/application.yaml)) says: repository
`https://github.com/Manojsiriparthi/kubernetes-project`, branch `main`, folder `kubernetes`. Argo CD will now keep the
cluster equal to that folder.

At this moment `main` is empty, so Argo CD shows an error ("path does not exist"). That is normal. It turns green after
the first pull request is merged in Step 9.

---

## Step 7 - Set up Jenkins

Open `http://<jenkins-server-public-ip>:8080` (open port 8080 in the server's security group, only to your IP).

### 7.1 First login

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Paste the password into the unlock page, click **Continue**, then select **Install suggested plugins**. Wait for the
install to finish, create your Jenkins admin user, and click **Save and Finish**.

### 7.2 Install/check the plugins

The suggested install usually includes what the pipeline needs. To check or add a plugin:

1. In Jenkins, open **Manage Jenkins** > **Plugins** > **Available plugins**.
2. Search for each plugin below. Select it only if it is not already installed.
3. Click **Install** (or **Install and restart Jenkins** if Jenkins asks for a restart).
4. If you installed plugins without restarting, restart Jenkins from **Manage Jenkins** when prompted.

| Search for this plugin | Plugin ID | Required? | What it does |
|---|---|---|---|
| Pipeline | `workflow-aggregator` | Yes | Runs the Jenkinsfile pipeline |
| Git | `git` | Yes | Checks out the repository |
| Credentials Binding | `credentials-binding` | Yes | Makes tokens available to pipeline steps securely |
| Timestamper | `timestamper` | Yes | Provides the `timestamps()` pipeline option |
| JUnit | `junit` | Yes | Publishes test results |
| Pipeline: Stage View | `pipeline-stage-view` | Optional | Shows the pipeline stages visually |

**Plugin versions:** do not type a version number. Jenkins Update Center selects the newest version compatible with
your installed Jenkins. This project does not pin plugin versions. If Jenkins reports a dependency, allow it to install
the required dependencies too.

No Slack plugin is needed: the pipeline sends the Slack message with a simple web call. You also do not need the
Jenkins NodeJS or Python plugins: the pipeline uses programs installed on the server and available on its `PATH`.

### 7.3 Tools and versions on the Jenkins server

These are server programs, **not Jenkins plugins**. `scripts/pre-tools.sh` installs them; there is no need to add them
under **Manage Jenkins > Tools** for this pipeline.

| Tool | Version this project requests | Used for |
|---|---|---|
| Java | 21 | Runs Jenkins |
| Node.js | 20.x | Frontend tests and `npm audit` |
| Python | Python 3 from the server OS (minor version is not pinned) | Backend tests and `pip-audit` |
| Apache JMeter | 5.6.3 | Load tests |
| Helm | 3.18.4 | Kubernetes package management |
| Jenkins | LTS from the Jenkins package repository (exact release is not pinned) | Runs the pipeline |
| Docker, Terraform, AWS CLI, `kubectl`, Argo CD CLI, Trivy | Installed by the setup script; exact releases are not pinned | Build, scan, and cloud/Kubernetes operations |

Node.js installation is skipped if `node` is already present, so check that it is version 20 before running the job.
To verify the actual versions on the server, run:

```bash
java -version
node --version
npm --version
python3 --version
docker --version
docker compose version
jmeter --version
trivy --version
```

If Node.js is not version 20, install Node.js 20 on the server and restart Jenkins so the Jenkins service picks up the
correct `PATH`.

### 7.4 Add Jenkins credentials (Manage Jenkins > Credentials > System > Global credentials)

For each credential, click **Add Credentials**, choose **Kind: Secret text**, paste the secret into **Secret**, enter the
ID exactly as shown, then click **Create**:

| ID | Secret | How to get it |
|---|---|---|
| `GITHUB` (Username with password) | a GitHub token as the password | GitHub, Settings, Developer settings, Fine-grained tokens. Repository access: this repo. Permissions: **Contents: Read and write**, **Pull requests: Read and write** |
| `sonar-cred` | a SonarQube token | SonarQube (Step 7.4), top right icon, My Account, Security, Generate token |
| `slack-token` | Slack app token | Slack Notification plugin: Manage Jenkins > System > Slack, workspace + this credential, channel `#devops-notifications` |

AWS needs no credential here: the server's IAM role (Step 1) is used.

### 7.5 SonarQube

1. Open `http://<jenkins-server-public-ip>:9000`.
2. Log in with `admin` / `admin`, then change the password when asked.
3. Create the token for `sonar-cred` (table above).
4. You do not need to create the projects: `school-demo-frontend` and `school-demo-backend` appear on the first scan
(the keys are set in the two CI Jenkinsfiles).
5. The pipeline waits for the "Quality Gate" result (default gate: "Sonar way"). If the gate fails, the build fails.

### 7.6 ECR login

Nothing to configure: the pipeline logs in to ECR itself with
`aws ecr get-login-password ... | docker login`, using the server's IAM role. To test by hand:

```bash
sudo -u jenkins bash -c 'aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com'
```

You should see `Login Succeeded`.

### 7.7 Jenkins tool and server settings the pipelines expect

The three Jenkinsfiles use these names (Manage Jenkins > Tools / System). Create them with exactly these names:

| Where | Name | Value |
|---|---|---|
| Tools > NodeJS (frontend job only) | `nodejs` | Node.js 20 |
| Tools > SonarQube Scanner | `sonarqube` | install automatically |
| Tools > Dependency-Check | `DP-Check` | install from github.com |
| System > SonarQube servers | `sonar-server` | `http://localhost:9000` + the `sonar-cred` credential |

Extra plugins for these pipelines: **SonarQube Scanner**, **OWASP Dependency-Check**, **Slack Notification**
(Slack channel `#devops-notifications`, set up under Manage Jenkins > System > Slack).
Extra credential: `GITHUB` (Username with password: your GitHub user and token). It is used for checkout, push and the pull request. `jq`, `trivy`, `python3` and `jmeter` come from
`pre-tools.sh`.

Check the `environment { ... }` block at the top of each Jenkinsfile (`AWS_DEFAULT_REGION`, `ARTIFACT_BUCKET`, `GIT_REPO`).

### 7.8 Create the three jobs

For each row: Jenkins home, **New Item**, type **Pipeline**, Definition = **Pipeline script from SCM**, SCM = **Git**,
Repository URL = `https://github.com/Manojsiriparthi/kubernetes-project`, Branch Specifier = `*/release/version1`.

| Job name | Script Path | What it does |
|---|---|---|
| `school-demo-frontend-ci` | `jenkins/Jenkinsfile.frontend.groovy` | test, scan, build and push the frontend image, update `docker-compose.yml` |
| `school-demo-backend-ci` | `jenkins/Jenkinsfile.backend.groovy` | same for the backend |
| `school-demo-cd` | `jenkins/Jenkinsfile.cd.groovy` | run the new images with docker compose, test, update `kubernetes/*.yaml`, raise the pull request |

---

## Step 8 - Run the pipeline for version 1

1. Run `school-demo-frontend-ci` and `school-demo-backend-ci` (**Build with Parameters**, default branch
   `release/version1`). Each one pushes its new image name into `docker-compose.yml` on that branch.
2. When both are green, run `school-demo-cd`. It tests both images together and opens the pull request into `main`.
3. Watch **Console Output**. The first run takes 20-40 minutes (downloads scanner databases). Slack gets a message
   when each pipeline ends; the CD message contains the pull request link.

### Merge the pull request into main

Open the pull request link. The first time, GitHub may say **"This branch has conflicts"**, because `main` is empty
and the release branch changed files that existed before. Fix it once like this on your server:

```bash
git fetch origin
git switch ci/images-1                      # use the branch name shown in the pull request
git merge -s ours origin/main -m "Merge main, keep release content"
git push origin ci/images-1
```

(`-s ours` means: "treat main as merged, keep everything from this branch".) Reload the pull request: the conflict is
gone. Choose **Squash and merge**. Squash gives you exactly **one commit per release**, which makes rollback easy.

### Argo CD deploys it

Within about 3 minutes Argo CD notices the new commit on `main` and deploys it (or click **Refresh** and **Sync** in
the Argo CD web page). Watch it:

```bash
kubectl get pods -n school-demo -w          # press Ctrl+C to stop
kubectl get ingress -n school-demo
```

Open the `ADDRESS` of the `frontend` ingress in a browser: `http://<address>`. You see the version 1 website.
Try the student lookup: first name `Ananya`, last name `Rao`, class `10`.

---

## Step 9 - Deploy version 2 (same pipeline, other branch)

1. Update the version 2 branch with what is now on `main`, so the next pull request has no conflicts:

   ```bash
   git fetch origin
   git switch release/version2
   git merge -s ours origin/main -m "Merge main, keep version 2 content"
   git push origin release/version2
   ```

2. In Jenkins, change the job's **Branch Specifier** to `*/release/version2` (Configure, Pipeline), then
   **Build with Parameters** and set `BRANCH` = `release/version2`, `BASE_BRANCH` = `main`. Build.
3. When the pull request appears, **Squash and merge** it.
4. Argo CD updates the same website. Watch the rolling update (new pods start, old ones stop, one at a time):

   ```bash
   kubectl rollout status deployment/frontend -n school-demo
   kubectl get pods -n school-demo -w
   ```

5. Reload the same website address. It is now the indigo version 2 page with the "Version 2.0" badge. The address did
   not change and the site kept answering during the update (no downtime).

---

## Step 10 - Roll back to version 1 (undo the last release)

Because version 2 is one commit on `main`, undoing it means reverting that one commit:

- **On GitHub:** open the merged version 2 pull request and click **Revert**. GitHub makes a new pull request that
  undoes it. Merge it.
- **Or on your server:**

  ```bash
  git switch main && git pull
  git log --oneline -3                       # find the version 2 commit
  git revert <commit-id>
  git push origin main
  ```

Argo CD sees the new commit and rolls the website back to version 1 with the same zero-downtime rolling update.

---

## Step 11 - Check that everything works, and learn while you do it

Run these and read the output. Each command is explained in doc 04 (section "Commands you should learn").

```bash
kubectl get pods -n school-demo -o wide          # are all pods Running? on which node?
kubectl get svc -n school-demo                   # services (internal addresses)
kubectl get ingress -n school-demo               # the public address of the website
kubectl get pvc -n school-demo                   # the database disk
kubectl describe pod -n school-demo -l app=backend     # details and events of a pod
kubectl logs -n school-demo deployment/backend --tail=50
kubectl get events -n school-demo --sort-by=.lastTimestamp
kubectl get hpa -n school-demo                   # autoscaling status
```

Test the networking from inside the cluster (frontend pod talks to the backend by name):

```bash
kubectl exec -n school-demo deploy/frontend -- wget -qO- http://backend:5000/api/health/ready
```

Expected answer: `{"status":"ready"}`.

---

## Step 12 - Remove everything (stop paying)

```bash
./scripts/infra.sh
# Enter 1 or 2: 2          (type "destroy" to confirm)
```

It deletes the Argo CD applications and the `school-demo` namespace first (so the load balancers are removed),
then the add-ons, servers, cluster and network, in that order. At the end it checks that no load balancer is left
behind. The S3 bucket from Step 2 is not deleted (delete it by hand if you want).

---

## Where to read more

| Document | What it explains |
|---|---|
| [02-infrastructure.md](02-infrastructure.md) | every part of the AWS and cluster setup, and why |
| [03-application.md](03-application.md) | the website itself: frontend, backend, database |
| [04-kubernetes.md](04-kubernetes.md) | every Kubernetes file, line by line |
| [05-jenkins-pipeline.md](05-jenkins-pipeline.md) | every stage of the CI pipeline |
| [06-monitoring.md](06-monitoring.md) | metrics, dashboards, alerts |

## Common problems

| Problem | Cause and fix |
|---|---|
| `terraform apply` says access denied | your AWS user lacks rights; use an administrator user for learning |
| Helm provider cannot connect | your IP is not in `cluster_endpoint_public_access_cidrs`, or run the targeted apply from Step 4 |
| Pods stay `Pending` | not enough room on the nodes: `kubectl describe pod <name>` and read the Events at the bottom |
| Pod `ImagePullBackOff` | the image tag is not in ECR yet: run the Jenkins pipeline so it pushes the images |
| Argo CD `ComparisonError` / path not found | `main` is still empty: merge the first pull request |
| Team tool page does not open | your current IP is not in `team_access_cidrs`; wait a few minutes after creation |
| Jenkins build fails at SonarQube | wrong `sonar-cred`, or SonarQube still starting (wait, check `docker ps`) |
