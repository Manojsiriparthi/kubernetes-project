#!/usr/bin/env bash
# Commits the changed files (new image names), pushes a ci/images-<build> branch and opens a GitHub pull request.
# Needs these environment variables (set by the Jenkinsfile):
#   GH_TOKEN, GIT_URL, BASE_BRANCH, BUILD_NUMBER, BUILD_URL, JOB_NAME, IMAGE_TAG,
#   BACKEND_IMAGE, FRONTEND_IMAGE, ARTIFACT_BUCKET
# The pull request link is written to reports/pr-url.txt.
set -euo pipefail

# "https://github.com/owner/repo.git" -> "owner/repo"
repo="${GIT_URL%.git}"
repo="${repo#https://github.com/}"
pr_branch="ci/images-${BUILD_NUMBER}"

# Stop early with a clear message if the branch we want to merge into does not exist.
git ls-remote --exit-code --heads "$GIT_URL" "$BASE_BRANCH" >/dev/null \
  || { echo "Base branch '$BASE_BRANCH' does not exist in $GIT_URL. Create it first."; exit 1; }

# 1. Commit everything that changed (docker-compose.yml, Kubernetes manifests, package-lock.json).
#    reports/, .venv/ and node_modules/ are ignored by .gitignore.
git config user.name "Jenkins CI"
git config user.email "jenkins@localhost"
git checkout -b "$pr_branch"
git add -A
git status --short
git commit -m "ci: update frontend and backend images to ${IMAGE_TAG} (Jenkins build #${BUILD_NUMBER})"

# 2. Push. The token goes in an HTTP header, not in the URL, so it never ends up in the git config or the logs.
auth="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
git -c http.extraheader="AUTHORIZATION: basic ${auth}" push origin "$pr_branch"

# 3. Open the pull request through the GitHub API.
body="Automated pull request from Jenkins build #${BUILD_NUMBER} (${BUILD_URL}).

- Backend image: ${BACKEND_IMAGE}
- Frontend image: ${FRONTEND_IMAGE}

All stages passed: unit tests, SonarQube, dependency tests, Trivy and ECR scans, docker compose run,
smoke and integration tests, OWASP ZAP and JMeter.
Artifacts: s3://${ARTIFACT_BUCKET}/artifacts/${JOB_NAME}/${BUILD_NUMBER}/

Merging this pull request makes Argo CD deploy the new images."

jq -n --arg title "Update images to ${IMAGE_TAG}" --arg head "$pr_branch" --arg base "$BASE_BRANCH" --arg body "$body" \
  '{title: $title, head: $head, base: $base, body: $body}' > reports/pr-request.json

curl -fsS -X POST "https://api.github.com/repos/${repo}/pulls" \
  -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" \
  --data @reports/pr-request.json | jq -r '.html_url' | tee reports/pr-url.txt
