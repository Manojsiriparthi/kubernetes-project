// CD pipeline (3 of 3). Run it after BOTH CI pipelines passed. It tests the two new images together
// (docker compose), then updates the Kubernetes files and raises a pull request into main.
// Argo CD deploys when that pull request is merged.
// Jenkins needs: python3 + jmeter on the server, plugin Slack, credentials 'GITHUB' (git checkout + push) and 'sonar-cred',
//                (the same 'GITHUB' credential, Username with password, is used to push and create the pull request). No AWS keys: the server's IAM role is used.
pipeline {
    agent any
    parameters {
        string(name: 'BRANCH', defaultValue: 'release/version1', description: 'Branch the CI pipelines pushed to; the pull request is raised from it')
        string(name: 'BASE_BRANCH', defaultValue: 'main', description: 'Branch the pull request goes into')
    }
    environment {
        AWS_DEFAULT_REGION   = 'us-east-1'
        ARTIFACT_BUCKET      = 'school-demo-terraform-state-513263709619-us-east-1'
        GIT_REPO             = 'Manojsiriparthi/kubernetes-project'
        // Port 18080 because Jenkins itself uses 8080.
        COMPOSE_PROJECT_NAME = 'school-demo-cd'
        FRONTEND_PORT        = '18080'
        BASE_URL             = 'http://localhost:18080'
    }
    stages {
        stage('Cleaning Workspace') {
            steps {
                sh 'docker compose -p school-demo-cd down -v --remove-orphans || true'
                cleanWs()
            }
        }
        stage('Checkout from Git') {
            steps {
                git branch: params.BRANCH, credentialsId: 'GITHUB', url: "https://github.com/${GIT_REPO}.git"
                sh 'mkdir -p reports'
            }
        }
        // The image names were written into docker-compose.yml by the two CI pipelines.
        stage('Read Images and ECR Login') {
            steps {
                script {
                    env.BACKEND_IMAGE  = sh(script: "sed -n -E 's|^ *image: (.*school-demo-backend:.*)|\\1|p' docker-compose.yml", returnStdout: true).trim()
                    env.FRONTEND_IMAGE = sh(script: "sed -n -E 's|^ *image: (.*school-demo-frontend:.*)|\\1|p' docker-compose.yml", returnStdout: true).trim()
                    if (env.BACKEND_IMAGE.endsWith(':local') || env.FRONTEND_IMAGE.endsWith(':local')) {
                        error 'docker-compose.yml still has :local images. Run the frontend CI and the backend CI first.'
                    }
                    env.REGISTRY = env.FRONTEND_IMAGE.split('/')[0]
                }
                sh 'aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin ${REGISTRY}'
            }
        }
        // The database tables are created from application/backend/init.sql on the first start.
        stage('Docker Compose Run') {
            steps {
                sh '''
                    docker compose -p ${COMPOSE_PROJECT_NAME} down -v --remove-orphans || true
                    docker compose -p ${COMPOSE_PROJECT_NAME} up -d --no-build
                    for i in $(seq 1 60); do
                      curl -fsS ${BASE_URL}/api/health/ready > /dev/null 2>&1 && exit 0
                      sleep 5
                    done
                    docker compose -p ${COMPOSE_PROJECT_NAME} logs > reports/compose-logs.txt
                    echo "The application did not become ready"; exit 1
                '''
            }
        }
        stage('Smoke Test') {
            steps {
                sh 'bash tests/smoke/smoke_test.sh | tee reports/smoke-tests.txt'
            }
        }
        // Who can reach whom: outside -> frontend -> backend -> database. The database must not be public.
        stage('Networking Check') {
            steps {
                sh '''
                    C="docker compose -p ${COMPOSE_PROJECT_NAME} exec -T"
                    {
                      curl -fsS ${BASE_URL}/ > /dev/null                                   && echo "PASS outside -> frontend"
                      $C frontend getent hosts backend > /dev/null                          && echo "PASS frontend resolves backend"
                      $C frontend wget -q -O /dev/null http://backend:5000/api/health/live  && echo "PASS frontend -> backend:5000"
                      $C backend python -c "import socket; socket.gethostbyname('postgres')" && echo "PASS backend resolves postgres"
                      curl -fsS ${BASE_URL}/api/health/ready > /dev/null                    && echo "PASS backend -> postgres (ready = SELECT 1)"
                      if curl -sS --max-time 3 telnet://localhost:5432 > /dev/null 2>&1; then echo "FAIL postgres is public"; exit 1; fi
                      echo "PASS postgres is not published to the host"
                    } | tee reports/network-tests.txt
                '''
            }
        }
        // Register a student, then look it up: frontend, backend and database all work together.
        stage('Integration Tests') {
            steps {
                sh '''
                    python3 -m venv .venv
                    .venv/bin/pip install --quiet -r tests/requirements.txt
                    .venv/bin/pytest tests/integration --junitxml=reports/integration-results.xml
                '''
            }
        }
        stage('Load Test (JMeter)') {
            steps {
                sh '''
                    jmeter -n -t tests/jmeter/load-test.jmx -l reports/jmeter-results.jtl -Jhost=localhost -Jport=${FRONTEND_PORT}
                    failed=$(awk -F, 'NR > 1 && $8 == "false"' reports/jmeter-results.jtl | wc -l)
                    echo "JMeter failed requests: $failed"
                    [ "$failed" -eq 0 ]
                '''
            }
        }
        stage('Push Artifacts to S3') {
            steps {
                sh 'aws s3 cp reports s3://${ARTIFACT_BUCKET}/artifacts/${JOB_NAME}/${BUILD_NUMBER}/tests/ --recursive --only-show-errors'
            }
        }
        stage('Update Kubernetes Images') {
            steps {
                sh '''
                    sed -i -E "s|image: [^[:space:]]*school-demo-backend[^[:space:]]*|image: ${BACKEND_IMAGE}|"   kubernetes/backend.yaml
                    sed -i -E "s|image: [^[:space:]]*school-demo-frontend[^[:space:]]*|image: ${FRONTEND_IMAGE}|" kubernetes/frontend.yaml
                    grep 'image:' kubernetes/backend.yaml kubernetes/frontend.yaml
                '''
            }
        }
        // Commit to the current branch and open a pull request into main (an open one is reused).
        stage('Create Pull Request') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'GITHUB', usernameVariable: 'GIT_USER', passwordVariable: 'GITHUB_TOKEN')]) {
                    sh '''
                        git config user.email "manojs.devops1@gmail.com"
                        git config user.name "manojsiriparthi"
                        git add kubernetes/backend.yaml kubernetes/frontend.yaml
                        git diff --cached --quiet || git commit -m "cd: deploy ${FRONTEND_IMAGE##*:} frontend and ${BACKEND_IMAGE##*:} backend"
                        git pull --rebase https://${GITHUB_TOKEN}@github.com/${GIT_REPO}.git ${BRANCH}
                        git push https://${GITHUB_TOKEN}@github.com/${GIT_REPO}.git HEAD:${BRANCH}

                        API=https://api.github.com/repos/${GIT_REPO}/pulls
                        OWNER=${GIT_REPO%%/*}
                        PR=$(curl -fsS -H "Authorization: Bearer ${GITHUB_TOKEN}" "${API}?state=open&head=${OWNER}:${BRANCH}&base=${BASE_BRANCH}" | jq -r '.[0].html_url // empty')
                        if [ -z "$PR" ]; then
                          jq -n --arg t "Deploy ${FRONTEND_IMAGE##*:} / ${BACKEND_IMAGE##*:}" --arg h "${BRANCH}" --arg b "${BASE_BRANCH}" \
                            --arg body "Tested by Jenkins build #${BUILD_NUMBER}: smoke, networking, integration and load tests passed.
Backend: ${BACKEND_IMAGE}
Frontend: ${FRONTEND_IMAGE}
Merge to let Argo CD deploy." '{title:$t, head:$h, base:$b, body:$body}' > pr.json
                          PR=$(curl -fsS -X POST -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" --data @pr.json ${API} | jq -r '.html_url')
                          rm -f pr.json
                        fi
                        echo "$PR" | tee reports/pr-url.txt
                    '''
                }
                script { env.PR_URL = readFile('reports/pr-url.txt').trim() }
            }
        }
    }
    post {
        success {
            slackSend(channel: '#devops-notifications', color: 'good',
                message: "CD #${env.BUILD_NUMBER}: testing completed, pull request raised: ${env.PR_URL} :white_check_mark:")
        }
        failure {
            slackSend(channel: '#devops-notifications', color: 'danger',
                message: "CD #${env.BUILD_NUMBER} failed: ${env.BUILD_URL}console :x:")
        }
        always {
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
            junit allowEmptyResults: true, testResults: 'reports/*-results.xml'
            sh '''
                docker compose -p school-demo-cd down -v --remove-orphans || true
                docker rmi "${FRONTEND_IMAGE:-none}" "${BACKEND_IMAGE:-none}" 2>/dev/null || true
            '''
            cleanWs()
        }
    }
}
