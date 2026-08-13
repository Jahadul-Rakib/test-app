pipeline {
    agent any

    options {
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timeout(time: 30, unit: 'MINUTES')
    }

    triggers {
        // Webhooks cannot reach a Jenkins server with no inbound route, so poll.
        // Matches Argo CD's 60s reconciliation, keeping both halves of the
        // push-to-pod delay at the same granularity.
        pollSCM('* * * * *')
    }

    environment {
        // Application
        APP_NAME = 'notes-app'

        // Container Registry
        REGISTRY = 'docker.io'
        REGISTRY_NAMESPACE = 'jahadulrakib'
        IMAGE_REPOSITORY = "${REGISTRY}/${REGISTRY_NAMESPACE}/${APP_NAME}"
        REGISTRY_CREDENTIALS_ID = 'dockerhub'

        // Git
        GIT_REPOSITORY = 'github.com/Jahadul-Rakib/test-app.git'
        GIT_BRANCH = 'main'
        GIT_CREDENTIALS_ID = 'github-token'

        // Helm / GitOps
        HELM_RELEASE = 'notes-app'
        HELM_CHART_DIR = 'helm/notes-app'
        HELM_VALUES_FILE = 'helm/notes-app/values.yaml'

        // CI
        CI_BOT_NAME = 'jenkins-ci'
        CI_BOT_EMAIL = 'jenkins-ci@users.noreply.github.com'
        // Stamped on the write-back commit; every stage below matches it with
        // a `changelog` when-condition, or the write-back retriggers forever.
        //
        // The regex is written out literally at each use, not held here: the
        // `changelog` condition is compiled at PARSE time, before env vars
        // exist, so "${CI_SKIP_PATTERN}" is validated as a regex itself and
        // fails with "Illegal repetition".
        CI_SKIP_TOKEN = '[ci skip]'

        // Security
        TRIVY_SEVERITY = 'HIGH,CRITICAL'
        TRIVY_EXIT_CODE = '1'
        // Outside the workspace -- CleanBeforeCheckout would wipe it every build.
        TRIVY_CACHE_DIR = '/var/tmp/jenkins-trivy-cache'

        // Optional Cosign signing -- both must be set for the stage to run.
        COSIGN_CREDENTIALS_ID = ''
        COSIGN_PASSWORD_CREDENTIALS_ID = ''
        // v3 removed --tlog-upload=false, which this pipeline depends on.
        COSIGN_MAJOR_VERSION = '2'

        // GIT_SHA, IMAGE_TAG and BUILD_TIMESTAMP are deliberately NOT declared
        // here. A pipeline-level environment{} entry is re-applied at the start
        // of every stage, so declaring them would overwrite whatever Checkout
        // assigned with the empty default from this block.
    }

    stages {

        stage('Checkout') {
            steps {
                script {
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

                    // Read the SHA from the workspace, not from checkout()'s
                    // return value -- that map comes back without GIT_COMMIT on
                    // current plugin versions and every image label silently
                    // renders empty.
                    env.GIT_SHA = sh(
                            script: 'git rev-parse HEAD',
                            returnStdout: true
                    ).trim()
                    env.IMAGE_TAG = env.GIT_SHA

                    env.BUILD_TIMESTAMP = sh(
                            script: 'date -u +%Y-%m-%dT%H:%M:%SZ',
                            returnStdout: true
                    ).trim()

                    echo "Application : ${env.APP_NAME}"
                    echo "Branch      : ${env.GIT_BRANCH}"
                    echo "Commit      : ${env.GIT_SHA}"
                    echo "Image       : ${env.IMAGE_REPOSITORY}:${env.IMAGE_TAG}"
                }
            }
        }

        stage('Build Image') {
            when {
                not { changelog '(?s).*\\[ci skip\\].*' }
            }
            options {
                timeout(time: 15, unit: 'MINUTES')
            }
            steps {
                sh '''
                    set -e

                    DOCKER_BUILDKIT=1 docker build \
                        --pull \
                        --label "org.opencontainers.image.title=$APP_NAME" \
                        --label "org.opencontainers.image.revision=$GIT_SHA" \
                        --label "org.opencontainers.image.source=https://$GIT_REPOSITORY" \
                        --label "org.opencontainers.image.created=$BUILD_TIMESTAMP" \
                        --label "org.opencontainers.image.version=$IMAGE_TAG" \
                        --tag "$IMAGE_REPOSITORY:$IMAGE_TAG" \
                        .
                '''
            }
        }

        // Runs before Push so a vulnerable image never reaches the registry,
        // and therefore can never be referenced by the GitOps write-back.
        stage('Scan Image') {
            when {
                not { changelog '(?s).*\\[ci skip\\].*' }
            }
            options {
                timeout(time: 15, unit: 'MINUTES')
            }
            steps {
                sh '''
                    set -e

                    mkdir -p "$TRIVY_CACHE_DIR"

                    # Download only when the cache is missing, so later builds need
                    # no network. No DB at all means nothing can be verified --
                    # fail rather than pass an unscanned image through.
                    if [ -f "$TRIVY_CACHE_DIR/db/trivy.db" ]; then
                        echo "Using cached vulnerability DB at $TRIVY_CACHE_DIR."
                        SKIP_UPDATE="--skip-db-update --skip-java-db-update"
                    else
                        echo "No cached DB found. Downloading once to seed $TRIVY_CACHE_DIR."
                        if ! trivy image --cache-dir "$TRIVY_CACHE_DIR" --download-db-only; then
                            echo "ERROR: vulnerability DB unavailable and no cached copy exists." >&2
                            exit 1
                        fi
                        SKIP_UPDATE=""
                    fi

                    TRIVY_COMMON="--cache-dir $TRIVY_CACHE_DIR \
                        --image-src docker \
                        --offline-scan \
                        $SKIP_UPDATE"

                    trivy image $TRIVY_COMMON \
                        --severity "$TRIVY_SEVERITY" \
                        --ignore-unfixed \
                        --scanners vuln,secret \
                        --exit-code "$TRIVY_EXIT_CODE" \
                        --format table \
                        --output trivy-image-report.txt \
                        "$IMAGE_REPOSITORY:$IMAGE_TAG"

                    # SBOM: lets this image be re-checked against future CVEs.
                    trivy image $TRIVY_COMMON \
                        --format cyclonedx \
                        --output sbom-cyclonedx.json \
                        "$IMAGE_REPOSITORY:$IMAGE_TAG"
                '''
            }
            post {
                always {
                    archiveArtifacts(
                            artifacts: 'trivy-image-report.txt,sbom-cyclonedx.json',
                            allowEmptyArchive: true,
                            fingerprint: false
                    )
                }
            }
        }

        stage('Validate Helm Chart') {
            when {
                not { changelog '(?s).*\\[ci skip\\].*' }
            }
            steps {
                sh '''
                    set -e

                    helm lint "$HELM_CHART_DIR"

                    # values.yaml carries a flat `image:` string --
                    # image.repository/tag would render image: "map[...]".
                    helm template "$HELM_RELEASE" "$HELM_CHART_DIR" \
                        --set image="$IMAGE_REPOSITORY:$IMAGE_TAG" \
                        > /dev/null

                    echo "Helm chart validation successful."
                '''
            }
        }

        stage('Push Image') {
            when {
                not { changelog '(?s).*\\[ci skip\\].*' }
            }
            options {
                // Registry pushes are the flakiest step in the pipeline.
                retry(3)
                timeout(time: 15, unit: 'MINUTES')
            }
            steps {
                withCredentials([
                        usernamePassword(
                                credentialsId: env.REGISTRY_CREDENTIALS_ID,
                                usernameVariable: 'REGISTRY_USER',
                                passwordVariable: 'REGISTRY_PASSWORD'
                        )
                ]) {
                    sh '''
                        set -e

                        echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY" --username "$REGISTRY_USER" --password-stdin
                        docker push "$IMAGE_REPOSITORY:$IMAGE_TAG"
                        docker logout "$REGISTRY"
                    '''
                }
            }
        }

        // Attaches a cosign signature and the SBOM to the pushed image, so the
        // cluster can verify provenance before admitting it.
        stage('Sign Image') {
            when {
                allOf {
                    not { changelog '(?s).*\\[ci skip\\].*' }
                    expression {
                        env.COSIGN_CREDENTIALS_ID?.trim() && env.COSIGN_PASSWORD_CREDENTIALS_ID?.trim()
                    }
                }
            }
            steps {
                withCredentials([
                        file(
                                credentialsId: env.COSIGN_CREDENTIALS_ID,
                                variable: 'COSIGN_KEY'
                        ),
                        string(
                                credentialsId: env.COSIGN_PASSWORD_CREDENTIALS_ID,
                                variable: 'COSIGN_PASSWORD'
                        ),
                        usernamePassword(
                                credentialsId: env.REGISTRY_CREDENTIALS_ID,
                                usernameVariable: 'REGISTRY_USER',
                                passwordVariable: 'REGISTRY_PASSWORD'
                        )]) {
                    sh '''
                        set -e

                        # Fail fast rather than on a confusing flag error.
                        FOUND=$(cosign version 2>/dev/null | awk '/^GitVersion:/ {print $2}')
                        FOUND_MAJOR=$(printf '%s' "$FOUND" | tr -d 'v' | cut -d. -f1)

                        if [ "$FOUND_MAJOR" != "$COSIGN_MAJOR_VERSION" ]; then
                            echo "ERROR: cosign v${COSIGN_MAJOR_VERSION}.x required, found ${FOUND:-none}." >&2
                            echo "  v3 removed --tlog-upload=false, which this stage depends on." >&2
                            echo "  Install a v2 release from https://github.com/sigstore/cosign/releases" >&2
                            exit 1
                        fi
                        echo "cosign $FOUND"

                        echo "$REGISTRY_PASSWORD" | docker login "$REGISTRY" --username "$REGISTRY_USER" --password-stdin

                        # --tlog-upload=false: rekor.sigstore.dev is unreachable
                        # with no egress. The Kyverno policy sets
                        # ctlog.ignoreTlog to match -- both or neither.
                        cosign sign --yes --tlog-upload=false \
                            --key "$COSIGN_KEY" "$IMAGE_REPOSITORY:$IMAGE_TAG"

                        cosign attach sbom --sbom sbom-cyclonedx.json "$IMAGE_REPOSITORY:$IMAGE_TAG"
                        docker logout "$REGISTRY"
                    '''
                }
            }
        }

        // Deploying is a git commit, not a kubectl call. Argo CD runs inside
        // the private cluster and pulls this change, so Jenkins never needs a
        // route to the API server.
        stage('Update GitOps') {
            when {
                not { changelog '(?s).*\\[ci skip\\].*' }
            }
            options {
                timeout(time: 10, unit: 'MINUTES')
            }
            steps {
                withCredentials([
                        usernamePassword(
                                credentialsId: env.GIT_CREDENTIALS_ID,
                                usernameVariable: 'GIT_USER',
                                passwordVariable: 'GIT_TOKEN'
                        )
                ]) {
                    sh '''
                        set -e

                        git config user.name "$CI_BOT_NAME"
                        git config user.email "$CI_BOT_EMAIL"

                        # Rebuilt from the remote tip each attempt -- a single
                        # push races any commit landing between fetch and push.
                        update_gitops() {
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
                                return 0
                            fi

                            git commit -m "chore(deploy): $APP_NAME -> $IMAGE_TAG $CI_SKIP_TOKEN"
                            git push "https://${GIT_USER}:${GIT_TOKEN}@${GIT_REPOSITORY}" "HEAD:$GIT_BRANCH"
                        }

                        for attempt in 1 2 3; do
                            if update_gitops; then
                                echo "GitOps write-back succeeded on attempt $attempt."
                                exit 0
                            fi

                            echo "GitOps write-back attempt $attempt failed. Retrying..."
                            sleep 5
                        done

                        echo "ERROR: GitOps write-back failed after 3 attempts." >&2
                        exit 1
                    '''
                }
            }
        }
    }

    post {
        always {
            sh '''
                docker logout "$REGISTRY" || true
                docker image rm -f "$IMAGE_REPOSITORY:$IMAGE_TAG" || true
            '''
        }
        success {
            echo "Pipeline successful: ${env.APP_NAME} @ ${env.GIT_SHA}"
        }
        failure {
            echo "Pipeline failed. Check the failed stage for details."
        }
    }
}