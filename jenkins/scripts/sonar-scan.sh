#!/usr/bin/env bash
# SAST with SonarQube: run the scanner, wait for the analysis, and fail if the quality gate is not OK.
# Needs these environment variables (set by the Jenkinsfile):
#   SONAR_TOKEN, SONAR_HOST_URL (as seen from this host), SONAR_HOST_URL_DOCKER (as seen from the scanner container)
set -euo pipefail

# 1. Run the scanner in a container on the same Docker network as the SonarQube server.
#    It runs as the current user so the files it writes in the workspace can be deleted later.
docker run --rm --user "$(id -u):$(id -g)" --network tools-net \
  -e SONAR_HOST_URL="$SONAR_HOST_URL_DOCKER" -e SONAR_TOKEN \
  -e SONAR_USER_HOME=/usr/src/.sonar \
  -v "$WORKSPACE:/usr/src" sonarsource/sonar-scanner-cli:latest

# 2. The scanner only uploads the analysis; SonarQube processes it in the background. Wait until it is done.
task_url="$(grep '^ceTaskUrl=' .scannerwork/report-task.txt | cut -d= -f2-)"
task_url="${task_url/$SONAR_HOST_URL_DOCKER/$SONAR_HOST_URL}"

status=""
for _ in $(seq 1 60); do
  status="$(curl -fsS -u "$SONAR_TOKEN:" "$task_url" | jq -r '.task.status')"
  [[ "$status" == "SUCCESS" ]] && break
  if [[ "$status" == "FAILED" || "$status" == "CANCELED" ]]; then
    echo "SonarQube analysis $status"
    exit 1
  fi
  sleep 5
done
[[ "$status" == "SUCCESS" ]] || { echo "Timed out waiting for SonarQube"; exit 1; }

# 3. Read the quality gate result (OK or ERROR) and fail the build on ERROR.
analysis_id="$(curl -fsS -u "$SONAR_TOKEN:" "$task_url" | jq -r '.task.analysisId')"
gate="$(curl -fsS -u "$SONAR_TOKEN:" "$SONAR_HOST_URL/api/qualitygates/project_status?analysisId=${analysis_id}" \
  | tee reports/sonar-quality-gate.json | jq -r '.projectStatus.status')"
echo "SonarQube quality gate: $gate"
[[ "$gate" == "OK" ]]
