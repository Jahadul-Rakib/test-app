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
        // Stamped onto the write-back commit, and matched by the `changelog`
        // when-condition on every stage below. Without that guard the
        // write-back commit re-triggers this job forever.
        CI_SKIP_TOKEN = '[ci skip]'
        CI_SKIP_PATTERN = '(?s).*\\[ci skip\\].*'

        // Security
        TRIVY_SEVERITY = 'HIGH,CRITICAL'
        TRIVY_EXIT_CODE = '1'
        TRIVY_CACHE_DIR = '/var/tmp/jenkins-trivy-cache'

        // Optional Cosign signing -- both must be set for the stage to run.
        COSIGN_CREDENTIALS_ID = ''
        COSIGN_PASSWORD_CREDENTIALS_ID = ''
        // Pinned major version, asserted before signing. v3 removed
        // --tlog-upload=false and demands a --signing-config with no
        // transparency log service instead, which cannot work on an agent with
        // no egress to rekor.sigstore.dev. Verified working on v2.6.5.
        COSIGN_MAJOR_VERSION = '2'

        // Runtime values, populated during Checkout
        GIT_SHA = ''
        IMAGE_TAG = ''
        BUILD_TIMESTAMP = ''
    }

    stages {

        stage('Checkout') {
            steps {
                script {
                    // The checkout step returns the SCM vars, so there is no
                    // need to shell out to `git rev-parse` for the commit.
                    def scmVars = checkout([
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

                    env.GIT_SHA = scmVars.GIT_COMMIT
                    env.IMAGE_TAG = scmVars.GIT_COMMIT

                    // RFC 3339, for the OCI created label.
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
                not { changelog "${CI_SKIP_PATTERN}" }
            }
            options {
                timeout(time: 15, unit: 'MINUTES')
            }
            steps {
                // OCI labels trace a running container back to the exact commit
                // that produced it.
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
                not { changelog "${CI_SKIP_PATTERN}" }
            }
            options {
                timeout(time: 15, unit: 'MINUTES')
            }
            steps {
                sh '''
                    set -e

                    mkdir -p "$TRIVY_CACHE_DIR"

                    # Download only when the cache is missing. Once seeded, every
                    # later build reuses it and touches the network not at all,
                    # which is what keeps this working on an agent with no egress.
                    # A missing DB means nothing can be verified, so that case
                    # fails the stage rather than passing an unscanned image on
                    # to the registry.
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

                    # SBOM of what actually shipped: lets this image be
                    # re-checked against future CVEs without a rebuild.
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
                not { changelog "${CI_SKIP_PATTERN}" }
            }
            steps {
                sh '''
                    set -e

                    helm lint "$HELM_CHART_DIR"

                    # values.yaml carries a single flat `image:` string, so
                    # override that same key. image.repository / image.tag would
                    # coerce it into a map and render image: "map[...]".
                    helm template "$HELM_RELEASE" "$HELM_CHART_DIR" \
                        --set image="$IMAGE_REPOSITORY:$IMAGE_TAG" \
                        > /dev/null

                    echo "Helm chart validation successful."
                '''
            }
        }

        stage('Push Image') {
            when {
                not { changelog "${CI_SKIP_PATTERN}" }
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
                    not { changelog "${CI_SKIP_PATTERN}" }
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

                        # Fail fast on the wrong major version rather than
                        # halfway through signing with a confusing flag error.
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

                        # --tlog-upload=false: cosign otherwise publishes the
                        # signature to the public Rekor transparency log at
                        # rekor.sigstore.dev, which an agent with no egress
                        # cannot reach -- the stage would hang, then fail. The
                        # Kyverno policy sets ctlog.ignoreTlog to match; if the
                        # two disagree every verification fails.
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
                not { changelog "${CI_SKIP_PATTERN}" }
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

                        # Rebuilt from the current remote tip on every attempt.
                        # A single push races any commit landing between fetch
                        # and push; retrying against a fresh base is what makes
                        # this safe to run alongside human pushes.
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