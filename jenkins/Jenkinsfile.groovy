// ============================================================================
// CI pipeline for the school demo. Read it top to bottom: each stage is one step of the plan.
//
//  1 Clean up + Checkout       6 Build images              12 Smoke tests
//  2 Install dependencies      7 Trivy image scan          13 Integration tests
//  3 Unit tests                8 Push to ECR               14 DAST (OWASP ZAP)
//  4 SAST (SonarQube)          9 ECR image scan            15 Load test (JMeter)
//  5 Dependency tests         10 Update docker-compose     16 Update Kubernetes manifests
//                             11 Run docker compose        17 Store artifacts in S3
//                                                          18 Commit + raise pull request
//
// The pipeline ENDS when the pull request is raised and Slack is told.
// CD is Argo CD: when the PR is merged into main, Argo CD deploys it (see argocd/application.yaml).
//
// Jenkins credentials to create (type "Secret text"):
//   github-token   GitHub token with repo scope      sonar-token   SonarQube token
//   slack-webhook  Slack incoming-webhook URL
// AWS access (ECR, S3) comes from the IAM role of the Jenkins server. Tools come from scripts/pre-tools.sh.
// ============================================================================

// Runs shell commands with bash and "stop at the first error" (plain sh would let a failure inside a pipe pass).
def bash(String commands) {
    sh(script: "#!/usr/bin/env bash\nset -euo pipefail\n" + commands)
}

// Sends a Slack message. If Slack is not configured yet the build is NOT failed; the problem is only logged.
def slack(String color, String text) {
    try {
        withCredentials([string(credentialsId: 'slack-webhook', variable: 'SLACK_URL')]) {
            withEnv(["SLACK_COLOR=${color}", "SLACK_TEXT=${text}"]) {
                bash '''
                    jq -n --arg text "$SLACK_TEXT" --arg color "$SLACK_COLOR" '{attachments: [{color: $color, text: $text}]}' \
                      | curl -fsS -X POST -H 'Content-type: application/json' --data @- "$SLACK_URL" > /dev/null
                '''
            }
        }
    } catch (err) {
        echo "Slack message skipped: ${err.message}"
    }
}

// Copies the reports/ folder to S3: same bucket as the Terraform state, folder artifacts/.
def uploadReportsToS3() {
    bash 'aws s3 cp reports "s3://$ARTIFACT_BUCKET/artifacts/$JOB_NAME/$BUILD_NUMBER/" --recursive --only-show-errors'
    env.REPORTS_UPLOADED = 'true'
}

pipeline {
    agent any   // one Jenkins server that has docker, aws, trivy, node, python and jmeter installed

    options {
        timestamps()
        timeout(time: 90, unit: 'MINUTES')
        disableConcurrentBuilds()          // the docker compose test stack uses fixed names and a fixed port
        skipDefaultCheckout(true)          // we check out ourselves, after cleaning the workspace
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    parameters {
        string(name: 'GIT_URL', defaultValue: 'https://github.com/Manojsiriparthi/kubernetes-project', description: 'Repository to build')
        string(name: 'BRANCH', defaultValue: 'release/version1', description: 'Release branch to build (release/version1 or release/version2)')
        string(name: 'BASE_BRANCH', defaultValue: 'main', description: 'Branch the pull request goes into (Argo CD watches it)')
    }

    environment {
        // AWS
        AWS_REGION      = 'us-east-1'
        PROJECT_NAME    = 'school-demo'
        ARTIFACT_BUCKET = 'school-demo-terraform-state-513263709619-us-east-1'

        // SonarQube: the scanner container reaches the server by name, this server reaches it on localhost.
        SONAR_HOST_URL_DOCKER = 'http://sonarqube:9000'
        SONAR_HOST_URL        = 'http://localhost:9000'
        SONAR_USER_HOME       = "${WORKSPACE}/.sonar"   // scanner cache, inside the workspace so clean-up removes it

        // The test copy of the app started by docker compose. Port 18080 because Jenkins itself uses 8080.
        COMPOSE_PROJECT_NAME = 'school-demo-ci'
        FRONTEND_PORT        = '18080'
        BASE_URL             = 'http://localhost:18080'
    }

    stages {

        // ---- 1. Start clean -------------------------------------------------------------------------------
        stage('Clean up') {
            steps {
                // Stop a test stack left behind by an earlier failed run, then empty the workspace.
                sh 'docker compose -p "$COMPOSE_PROJECT_NAME" down -v --remove-orphans || true'
                deleteDir()
            }
        }

        stage('Checkout') {
            steps {
                git url: params.GIT_URL, branch: params.BRANCH
                sh 'mkdir -p reports/zap reports/jmeter reports/dependency-check'
                script {
                    // Image tag = build number + commit, e.g. 42-1a2b3c4. ECR tags are immutable, so every build needs a new one.
                    env.IMAGE_TAG = "${env.BUILD_NUMBER}-" + sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
                    def account = sh(script: 'aws sts get-caller-identity --query Account --output text', returnStdout: true).trim()
                    def registry = "${account}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
                    env.ECR_REGISTRY   = registry
                    env.BACKEND_REPO   = "${env.PROJECT_NAME}-backend"
                    env.FRONTEND_REPO  = "${env.PROJECT_NAME}-frontend"
                    env.BACKEND_IMAGE  = "${registry}/${env.BACKEND_REPO}:${env.IMAGE_TAG}"
                    env.FRONTEND_IMAGE = "${registry}/${env.FRONTEND_REPO}:${env.IMAGE_TAG}"
                }
            }
        }

        // ---- 2. Dependencies ------------------------------------------------------------------------------
        stage('Install dependencies') {
            steps {
                // Backend: pip inside a virtualenv (.venv). Frontend: npm install.
                sh '''
                    python3 -m venv .venv
                    .venv/bin/pip install --quiet -r tests/requirements.txt
                    cd application/frontend && npm install --no-fund
                '''
            }
        }

        // ---- 3. Unit tests (no database or network needed) ------------------------------------------------
        stage('Unit tests') {
            steps {
                sh '.venv/bin/pytest application/backend/tests --cov=application/backend --cov-report=xml:reports/coverage.xml --junitxml=reports/backend-results.xml'
                sh 'cd application/frontend && npm test'
            }
        }

        // ---- 4. SAST: SonarQube static code analysis ------------------------------------------------------
        // The details (run scanner, wait, check quality gate) are in jenkins/scripts/sonar-scan.sh.
        stage('SAST - SonarQube') {
            steps {
                withCredentials([string(credentialsId: 'sonar-token', variable: 'SONAR_TOKEN')]) {
                    sh 'bash jenkins/scripts/sonar-scan.sh'
                }
            }
        }

        // ---- 5. Dependency tests: known-vulnerable libraries ----------------------------------------------
        // A finding makes the build UNSTABLE (yellow) but does not stop the pipeline.
        stage('Dependency tests') {
            steps {
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    sh '.venv/bin/pip-audit -r application/backend/requirements.txt -o reports/pip-audit.txt'
                }
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    sh 'cd application/frontend && npm audit --audit-level=high'
                }
                catchError(buildResult: 'UNSTABLE', stageResult: 'UNSTABLE') {
                    // Slow on the first run: it downloads the vulnerability database (cached in a Docker volume).
                    sh '''
                        chmod 777 reports/dependency-check
                        docker run --rm -v "$WORKSPACE/application:/src:ro" -v "$WORKSPACE/reports/dependency-check:/report" \
                          -v dependency-check-data:/usr/share/dependency-check/data owasp/dependency-check:latest \
                          --scan /src --format HTML --out /report --project school-demo --failOnCVSS 9
                    '''
                }
            }
        }

        // ---- 6. Build the two images (for x86, which is what the EKS nodes are) --------------------------
        stage('Build images') {
            steps {
                sh '''
                    docker build --platform linux/amd64 -t "$BACKEND_IMAGE"  application/backend
                    docker build --platform linux/amd64 -t "$FRONTEND_IMAGE" application/frontend
                '''
            }
        }

        // ---- 7. Trivy: scan the images BEFORE pushing them -----------------------------------------------
        // The report lists HIGH and CRITICAL. Only CRITICAL (with a fix available) fails the build.
        stage('Trivy image scan') {
            steps {
                sh '''
                    trivy image --severity HIGH,CRITICAL --ignore-unfixed -o reports/trivy-backend.txt  "$BACKEND_IMAGE"
                    trivy image --severity HIGH,CRITICAL --ignore-unfixed -o reports/trivy-frontend.txt "$FRONTEND_IMAGE"
                    trivy image --severity CRITICAL --ignore-unfixed --exit-code 1 --quiet "$BACKEND_IMAGE"
                    trivy image --severity CRITICAL --ignore-unfixed --exit-code 1 --quiet "$FRONTEND_IMAGE"
                '''
            }
        }

        // ---- 8. Push to ECR -------------------------------------------------------------------------------
        stage('Push images to ECR') {
            steps {
                bash '''
                    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"
                    docker push "$BACKEND_IMAGE"
                    docker push "$FRONTEND_IMAGE"
                    printf '%s\\n%s\\n' "$BACKEND_IMAGE" "$FRONTEND_IMAGE" > reports/images.txt
                '''
            }
        }

        // ---- 9. ECR scans every image on push (set in Terraform). Wait for it and fail on CRITICAL --------
        stage('ECR image scan') {
            steps {
                bash '''
                    for repo in "$BACKEND_REPO" "$FRONTEND_REPO"; do
                      aws ecr wait image-scan-complete --repository-name "$repo" --image-id imageTag="$IMAGE_TAG"
                      aws ecr describe-image-scan-findings --repository-name "$repo" --image-id imageTag="$IMAGE_TAG" > "reports/ecr-scan-$repo.json"
                      critical="$(jq -r '.imageScanFindings.findingSeverityCounts.CRITICAL // 0' "reports/ecr-scan-$repo.json")"
                      echo "$repo: $critical CRITICAL finding(s)"
                      [[ "$critical" -eq 0 ]]
                    done
                '''
            }
        }

        // ---- 10. Put the new image names into docker-compose.yml (this change goes into the pull request) -
        stage('Update docker-compose images') {
            steps {
                sh '''
                    sed -i -E "s|image: [^[:space:]]*school-demo-backend[^[:space:]]*|image: $BACKEND_IMAGE|"   docker-compose.yml
                    sed -i -E "s|image: [^[:space:]]*school-demo-frontend[^[:space:]]*|image: $FRONTEND_IMAGE|" docker-compose.yml
                    grep 'image:' docker-compose.yml
                '''
            }
        }

        // ---- 11. Start the whole app: PostgreSQL + backend + frontend ------------------------------------
        // PostgreSQL creates the tables from application/backend/init.sql the first time it starts.
        stage('Run docker compose') {
            steps {
                bash '''
                    docker compose -p "$COMPOSE_PROJECT_NAME" down -v --remove-orphans || true   # -v = start with an empty database
                    docker compose -p "$COMPOSE_PROJECT_NAME" up -d --no-build

                    # Wait (up to 5 minutes) until the backend can reach the database.
                    ready=false
                    for _ in $(seq 1 60); do
                      if curl -fsS "$BASE_URL/api/health/ready" > /dev/null 2>&1; then ready=true; break; fi
                      sleep 5
                    done
                    if [[ "$ready" != "true" ]]; then
                      docker compose -p "$COMPOSE_PROJECT_NAME" logs > reports/compose-logs.txt
                      echo "The application did not become ready"; exit 1
                    fi

                    # Check inside PostgreSQL: the table exists and the 4 seed students were inserted.
                    docker compose -p "$COMPOSE_PROJECT_NAME" exec -T postgres psql -U school_app -d school -c '\\dt' | tee reports/postgres-tables.txt
                    grep -q students reports/postgres-tables.txt
                    rows="$(docker compose -p "$COMPOSE_PROJECT_NAME" exec -T postgres psql -U school_app -d school -tAc 'SELECT count(*) FROM students')"
                    echo "students rows: $rows"
                    [[ "$rows" -ge 4 ]]
                '''
            }
        }

        // ---- 12. Smoke tests: is the whole chain alive? (frontend -> backend -> database) ----------------
        stage('Smoke tests') {
            steps {
                bash 'tests/smoke/smoke_test.sh | tee reports/smoke-tests.txt'
            }
        }

        // ---- 13. Integration tests: register a student, then look it up (writes and reads the database) --
        stage('Integration tests') {
            steps {
                sh '.venv/bin/pytest tests/integration --junitxml=reports/integration-results.xml'
            }
        }

        // ---- 14. DAST: OWASP ZAP attacks the running app from outside (passive baseline scan) ------------
        stage('DAST - OWASP ZAP') {
            steps {
                // -I: warnings do not fail the build, only real failures do.
                sh '''
                    chmod 777 reports/zap
                    docker run --rm --network host -v "$WORKSPACE/reports/zap:/zap/wrk:rw" zaproxy/zap-stable:latest \
                      zap-baseline.py -t "$BASE_URL" -r zap-report.html -I
                '''
            }
        }

        // ---- 15. Load test with JMeter. Fails if any request failed (column 8 of the results is "success") -
        stage('Load test - JMeter') {
            steps {
                bash '''
                    rm -rf reports/jmeter && mkdir -p reports/jmeter
                    jmeter -n -t tests/jmeter/load-test.jmx -l reports/jmeter/results.jtl -e -o reports/jmeter/html \
                      -Jhost=localhost -Jport="$FRONTEND_PORT"
                    failed="$(awk -F, 'NR > 1 && $8 == "false"' reports/jmeter/results.jtl | wc -l)"
                    echo "JMeter failed requests: $failed"
                    [[ "$failed" -eq 0 ]]
                '''
            }
        }

        // ---- 16. Everything passed: put the new images into the Kubernetes manifests ---------------------
        stage('Update Kubernetes manifests') {
            steps {
                sh '''
                    sed -i -E "s|image: [^[:space:]]*school-demo-backend[^[:space:]]*|image: $BACKEND_IMAGE|"   kubernetes/backend.yaml
                    sed -i -E "s|image: [^[:space:]]*school-demo-frontend[^[:space:]]*|image: $FRONTEND_IMAGE|" kubernetes/frontend.yaml
                    grep 'image:' kubernetes/backend.yaml kubernetes/frontend.yaml
                '''
            }
        }

        // ---- 17. Keep all reports in S3 -------------------------------------------------------------------
        stage('Store artifacts in S3') {
            steps {
                script { uploadReportsToS3() }
            }
        }

        // ---- 18. Commit, push a branch, open a pull request into main. The pipeline stops here. -----------
        // The details are in jenkins/scripts/create-pr.sh. Merging the PR is what makes Argo CD deploy.
        stage('Commit and raise pull request') {
            steps {
                withCredentials([string(credentialsId: 'github-token', variable: 'GH_TOKEN')]) {
                    sh 'bash jenkins/scripts/create-pr.sh'
                }
                script { env.PR_URL = readFile('reports/pr-url.txt').trim() }
            }
        }
    }

    post {
        always {
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true   // reports on the Jenkins build page
            junit allowEmptyResults: true, testResults: 'reports/*-results.xml' // test results graph
            script {
                // If the build failed before stage 17, still keep whatever reports exist.
                if (env.REPORTS_UPLOADED != 'true') {
                    try { uploadReportsToS3() } catch (err) { echo "S3 upload skipped: ${err.message}" }
                }
            }
            // Clean up: stop the test stack and delete the images built here so the server disk does not fill up.
            sh '''
                docker compose -p "$COMPOSE_PROJECT_NAME" down -v --remove-orphans || true
                docker rmi "${FRONTEND_IMAGE:-none}" "${BACKEND_IMAGE:-none}" 2>/dev/null || true
            '''
        }
        success {
            script { slack('good', "Pull request raised: ${env.PR_URL}\nJenkins build #${env.BUILD_NUMBER} passed. Merge it and Argo CD will deploy.") }
        }
        unstable {
            script { slack('warning', "Pull request raised: ${env.PR_URL}\nJenkins build #${env.BUILD_NUMBER} is UNSTABLE (dependency findings): ${env.BUILD_URL}") }
        }
        failure {
            script { slack('danger', "Jenkins build #${env.BUILD_NUMBER} FAILED: ${env.BUILD_URL}console") }
        }
    }
}
