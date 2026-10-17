// CI pipeline 1 of 3 - FRONTEND. Builds, tests, scans and pushes the frontend image, then writes its name into docker-compose.yml.
// No AWS keys in Jenkins: the Jenkins server's IAM role gives access to ECR and S3.
// Jenkins needs: tools nodejs + sonarqube (Java 21 is already on the server), SonarQube server 'sonar-server', Dependency-Check 'DP-Check',
//                plugins Slack + SonarQube Scanner + OWASP Dependency-Check, credentials 'GITHUB' (git checkout + push) and 'sonar-cred',
//                (the same 'GITHUB' credential, Username with password, is used to push).
pipeline {
    agent any
    tools {
        nodejs 'nodejs'
    }
    parameters {
        string(name: 'BRANCH', defaultValue: 'release/version1', description: 'Branch to build; the new image name is pushed back to it')
    }
    environment {
        SCANNER_HOME       = tool 'sonarqube'
        AWS_DEFAULT_REGION = 'us-east-1'
        ECR_REPO_NAME      = 'school-demo-frontend'
        ARTIFACT_BUCKET    = 'school-demo-terraform-state-513263709619-us-east-1'
        GIT_REPO           = 'Manojsiriparthi/kubernetes-project'
        MAX_CRITICAL       = '5'   // stop the build when Trivy or ECR finds MORE than this many CRITICAL issues
        APP_DIR            = 'application/frontend'
    }
    stages {
        stage('Cleaning Workspace') {
            steps {
                cleanWs()
            }
        }
        stage('Checkout from Git') {
            steps {
                git branch: params.BRANCH, credentialsId: 'GITHUB', url: "https://github.com/${GIT_REPO}.git"
                script {
                    def account = sh(script: 'aws sts get-caller-identity --query Account --output text', returnStdout: true).trim()
                    env.REPOSITORY_URI = "${account}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
                    env.IMAGE_TAG      = "${BUILD_NUMBER}"
                    env.IMAGE          = "${env.REPOSITORY_URI}/${ECR_REPO_NAME}:${BUILD_NUMBER}"
                }
                sh 'mkdir -p reports'
            }
        }
        stage('Sonarqube Analysis') {
            steps {
                dir(env.APP_DIR) {
                    withSonarQubeEnv('sonar-server') {
                        sh ''' $SCANNER_HOME/bin/sonar-scanner \
                        -Dsonar.projectName=school-demo-frontend \
                        -Dsonar.projectKey=school-demo-frontend \
                        -Dsonar.sources=. \
                        -Dsonar.exclusions=node_modules/**,tests/** '''
                    }
                }
            }
        }
        stage('Quality Gate Check') {
            steps {
                script {
                    waitForQualityGate abortPipeline: true, credentialsId: 'sonar-cred'
                }
            }
        }
        stage('Install NPM Dependencies') {
            steps {
                dir(env.APP_DIR) {
                    sh 'npm install'
                }
            }
        }
        stage('Unit Tests (npm test)') {
            steps {
                dir(env.APP_DIR) {
                    sh 'npm test'
                }
            }
        }
        stage('OWASP Dependency-Check Scan') {
            steps {
                dir(env.APP_DIR) {
                    dependencyCheck additionalArguments: '--scan ./ --disableYarnAudit --disableNodeAudit', odcInstallation: 'DP-Check'
                    dependencyCheckPublisher pattern: '**/dependency-check-report.xml'
                }
            }
        }
        stage('Trivy File Scan') {
            steps {
                sh 'trivy fs ${APP_DIR} > reports/trivyfs-frontend.txt'
            }
        }
        stage('Docker Image Build') {
            steps {
                sh '''
                    docker system prune -f
                    docker container prune -f
                    docker build --platform linux/amd64 -t ${IMAGE} ${APP_DIR}
                '''
            }
        }
        // Scan before pushing: HIGH and CRITICAL go to the report; more than MAX_CRITICAL fixable CRITICAL findings fail the build.
        stage('Trivy Image Scan') {
            steps {
                sh '''
                    trivy image --severity HIGH,CRITICAL --ignore-unfixed -o reports/trivyimage-frontend.txt ${IMAGE}
                    trivy image --severity CRITICAL --ignore-unfixed -f json -o reports/trivy-critical-frontend.json ${IMAGE}
                    critical=$(jq '[.Results[]?.Vulnerabilities[]?] | length' reports/trivy-critical-frontend.json)
                    echo "Trivy CRITICAL findings: $critical (limit ${MAX_CRITICAL})"
                    [ "$critical" -le "${MAX_CRITICAL}" ]
                '''
            }
        }
        stage('ECR Image Push') {
            steps {
                sh '''
                    # Create the ECR repository if it does not exist yet (scan on push, same as Terraform).
                    aws ecr describe-repositories --repository-names ${ECR_REPO_NAME} --region ${AWS_DEFAULT_REGION} > /dev/null 2>&1 \\
                      || aws ecr create-repository --repository-name ${ECR_REPO_NAME} --region ${AWS_DEFAULT_REGION} \\
                           --image-scanning-configuration scanOnPush=true --image-tag-mutability IMMUTABLE
                    aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin ${REPOSITORY_URI}
                    docker push ${IMAGE}
                '''
            }
        }
        // ECR scans on push (scan_on_push in Terraform). Wait for the result and fail when CRITICAL is more than MAX_CRITICAL.
        stage('ECR Image Scan') {
            steps {
                sh '''
                    aws ecr wait image-scan-complete --repository-name ${ECR_REPO_NAME} --image-id imageTag=${IMAGE_TAG}
                    aws ecr describe-image-scan-findings --repository-name ${ECR_REPO_NAME} --image-id imageTag=${IMAGE_TAG} > reports/ecr-scan-frontend.json
                    critical=$(jq -r '.imageScanFindings.findingSeverityCounts.CRITICAL // 0' reports/ecr-scan-frontend.json)
                    echo "ECR CRITICAL findings: $critical"
                    [ "$critical" -le "${MAX_CRITICAL}" ]
                '''
            }
        }
        // Folders in S3: artifacts/<job>/<build>/frontend/{scans,dependency-check}
        stage('Push Artifacts to S3') {
            steps {
                sh '''
                    DEST=s3://${ARTIFACT_BUCKET}/artifacts/${JOB_NAME}/${BUILD_NUMBER}
                    aws s3 cp reports ${DEST}/scans/ --recursive --only-show-errors
                    aws s3 cp ${APP_DIR}/dependency-check-report.xml ${DEST}/dependency-check/ --only-show-errors || true
                '''
            }
        }
        stage('Update Image in docker-compose.yml') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'GITHUB', usernameVariable: 'GIT_USER', passwordVariable: 'GITHUB_TOKEN')]) {
                    sh '''
                        git config user.email "manojs.devops1@gmail.com"
                        git config user.name "manojsiriparthi"
                        sed -i -E "s|image: [^[:space:]]*school-demo-frontend[^[:space:]]*|image: ${IMAGE}|" docker-compose.yml
                        grep school-demo-frontend docker-compose.yml
                        git add docker-compose.yml
                        git commit -m "ci(frontend): update image to ${IMAGE_TAG}"
                        # The backend CI may push to the same branch at the same time: rebase and retry.
                        for i in 1 2 3 4 5; do
                          git pull --rebase https://${GITHUB_TOKEN}@github.com/${GIT_REPO}.git ${BRANCH} \
                            && git push https://${GITHUB_TOKEN}@github.com/${GIT_REPO}.git HEAD:${BRANCH} && exit 0
                          sleep $((i * 3))
                        done
                        exit 1
                    '''
                }
            }
        }
    }
    post {
        success {
            slackSend(channel: '#devops-notifications', color: 'good',
                message: "Frontend CI #${env.BUILD_NUMBER} completed. Image updated in docker-compose.yml: ${env.IMAGE} :white_check_mark:")
        }
        failure {
            slackSend(channel: '#devops-notifications', color: 'danger',
                message: "Frontend CI #${env.BUILD_NUMBER} failed: ${env.BUILD_URL}console :x:")
        }
        unstable {
            slackSend(channel: '#devops-notifications', color: 'warning',
                message: "Frontend CI #${env.BUILD_NUMBER} is unstable: ${env.BUILD_URL} :warning:")
        }
        always {
            archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
            sh 'docker rmi ${IMAGE} 2>/dev/null || true'
            cleanWs()
        }
    }
}
