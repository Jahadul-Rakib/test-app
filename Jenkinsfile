pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timeout(time: 30, unit: 'MINUTES')
    }

    triggers {
        pollSCM('H/3 * * * *')
    }

    environment {
        // =========================================================
        // Application
        // =========================================================
        APP_NAME = 'notes-app'

        // =========================================================
        // Container Registry
        // =========================================================
        REGISTRY = 'docker.io'
        REGISTRY_NAMESPACE = 'jahadulrakib'

        // =========================================================
        // Git
        // =========================================================
        GIT_REPOSITORY = 'github.com/Jahadul-Rakib/test-app.git'
        GIT_BRANCH = 'main'
        GIT_CREDENTIALS_ID = 'github-token'

        // =========================================================
        // Docker Registry Credentials
        // =========================================================
        REGISTRY_CREDENTIALS_ID = 'dockerhub'

        // =========================================================
        // Helm / GitOps
        // =========================================================
        HELM_RELEASE = 'notes-app'
        HELM_CHART_DIR = 'helm/notes-app'
        HELM_VALUES_FILE = 'helm/notes-app/values.yaml'

        // =========================================================
        // CI Configuration
        // =========================================================
        CI_BOT_NAME = 'jenkins-ci'
        CI_BOT_EMAIL = 'jenkins-ci@users.noreply.github.com'
        CI_SKIP_TOKEN = '[ci skip]'

        // =========================================================
        // Runtime values
        // =========================================================
        GIT_SHA = ''
        IMAGE_TAG = ''
        SKIP_BUILD = 'false'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout([
                        $class           : 'GitSCM',
                        branches         : [[name: "*/${env.GIT_BRANCH}"]],
                        extensions       : [
                                [$class: 'CleanBeforeCheckout'],
                                [$class: 'CloneOption', shallow: false, noTags: true, timeout: 20]
                        ],
                        userRemoteConfigs: [
                                [
                                        url          : "https://${env.GIT_REPOSITORY}",
                                        credentialsId: env.GIT_CREDENTIALS_ID
                                ]
                        ]
                ])

                script {
                    env.GIT_SHA = sh(
                            script: 'git rev-parse HEAD',
                            returnStdout: true
                    ).trim()

                    env.IMAGE_TAG = env.GIT_SHA

                    def commitMessage = sh(
                            script: 'git log -1 --pretty=%s',
                            returnStdout: true
                    ).trim()

                    env.SKIP_BUILD = commitMessage.contains(env.CI_SKIP_TOKEN).toString()

                    echo "Application : ${env.APP_NAME}"
                    echo "Branch      : ${env.GIT_BRANCH}"
                    echo "Commit      : ${env.GIT_SHA}"
                    echo "Image       : ${env.REGISTRY}/${env.REGISTRY_NAMESPACE}/${env.APP_NAME}:${env.IMAGE_TAG}"
                    echo "Skip Build  : ${env.SKIP_BUILD}"
                }
            }
        }

        stage('Build Image') {
            when {
                expression {
                    env.SKIP_BUILD != 'true'
                }
            }
            steps {
                sh '''
                    set -e
                    docker build --pull --tag "$REGISTRY/$REGISTRY_NAMESPACE/$APP_NAME:$IMAGE_TAG" .
                '''
            }
        }

        stage('Validate Helm Chart') {
            when {
                expression {
                    env.SKIP_BUILD != 'true'
                }
            }
            steps {
                sh '''
                    set -e
                    helm lint "$HELM_CHART_DIR"
                    helm template \
                        "$HELM_RELEASE" \
                        "$HELM_CHART_DIR" \
                        --set image.repository="$REGISTRY/$REGISTRY_NAMESPACE/$APP_NAME" \
                        --set image.tag="$IMAGE_TAG" \
                        > /dev/null
                    echo "Helm chart validation successful."
                '''
            }
        }

        stage('Push Image') {
            when {
                expression { env.SKIP_BUILD != 'true' }
            }
            steps {
                withCredentials([usernamePassword(
                        credentialsId: env.REGISTRY_CREDENTIALS_ID,
                        usernameVariable: 'REGISTRY_USER',
                        passwordVariable: 'REGISTRY_PASSWORD')]) {
                    sh '''
                        set -e
                        echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY" --username "$REGISTRY_USER" --password-stdin
                        docker push "$REGISTRY/$REGISTRY_NAMESPACE/$APP_NAME:$IMAGE_TAG"
                        docker logout "$REGISTRY"
                    '''
                }
            }
        }

        stage('Update GitOps') {
            when {
                expression { env.SKIP_BUILD != 'true' }
            }
            steps {
                withCredentials([usernamePassword(
                        credentialsId: env.GIT_CREDENTIALS_ID,
                        usernameVariable: 'GIT_USER',
                        passwordVariable: 'GIT_TOKEN')]) {
                    sh '''
                set -e

                git config user.name "$CI_BOT_NAME"
                git config user.email "$CI_BOT_EMAIL"

                git fetch origin "$GIT_BRANCH"
                git checkout -B "$GIT_BRANCH" "origin/$GIT_BRANCH"

                python3 - "$HELM_VALUES_FILE" "$IMAGE_REPOSITORY:$IMAGE_TAG" <<'PY'
import sys
from pathlib import Path

values_file = Path(sys.argv[1])
image = sys.argv[2]

lines = values_file.read_text().splitlines(keepends=True)
updated = False

for i, line in enumerate(lines):
    if line.startswith("image:"):
        newline = "\\n" if line.endswith("\\n") else ""
        lines[i] = f"image: {image}{newline}"
        updated = True
        break

if not updated:
    raise SystemExit("ERROR: image field not found in values.yaml")

values_file.write_text("".join(lines))
PY

                git add "$HELM_VALUES_FILE"

                if git diff --cached --quiet; then
                    echo "GitOps manifest is already up to date."
                    exit 0
                fi

                git commit -m "chore(deploy): $APP_NAME -> $IMAGE_TAG $CI_SKIP_TOKEN"

                git push "https://${GIT_USER}:${GIT_TOKEN}@${GIT_REPOSITORY}" "HEAD:$GIT_BRANCH"
            '''
                }
            }
        }
    }

    post {
        always {
            sh '''
                docker logout "$REGISTRY" || true
                docker image rm -f "$REGISTRY/$REGISTRY_NAMESPACE/$APP_NAME:$IMAGE_TAG" || true
            '''
        }

        success {
            script {
                if (env.SKIP_BUILD == 'true') {
                    echo "CI write-back commit detected. Build skipped."
                } else {
                    echo "CI successful: ${env.APP_NAME}:${env.IMAGE_TAG}"
                    echo "GitOps manifest updated. Argo CD will synchronize the deployment."
                }
            }
        }

        failure {
            echo "Pipeline failed. Check the failed stage for details."
        }
    }
}