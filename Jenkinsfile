// =============================================================================
// notes-app CI -- Kubernetes-native, no Docker daemon anywhere.
//
// This pipeline builds with KANIKO, not `docker build`. On K3s (and any other
// containerd cluster) there is no /var/run/docker.sock to mount, so the whole
// docker-in-Jenkins pattern is unavailable. Kaniko builds an OCI image from a
// Dockerfile inside an unprivileged container instead.
//
// The build/scan/push order is deliberate and is the reason for the tarball:
//
//     kaniko --no-push --tar-path   ->  trivy --input  ->  crane push
//
// Kaniko's usual mode builds AND pushes in one shot, which would put an
// unscanned image in the registry and only then let Trivy look at it. Writing a
// tarball first keeps the original invariant -- a vulnerable image never
// reaches the registry -- and makes it stricter than the docker version ever
// was: crane pushes the exact bytes Trivy scanned, not a rebuild that might
// differ.
//
// Setup, credentials and the cluster this runs on: k3s-lab/README.md
// =============================================================================

pipeline {

    // Each build gets a throwaway pod. The three containers share
    // /home/jenkins/agent, so the tarball written by kaniko is visible to trivy
    // and crane with no artifact passing.
    agent {
        kubernetes {
            defaultContainer 'tools'
            yaml '''
apiVersion: v1
kind: Pod
spec:
  # The agent SA the Jenkins chart creates. Nothing here talks to the API
  # server, but the pod still needs an SA that exists.
  serviceAccountName: jenkins-agent
  restartPolicy: Never
  containers:
    # helm, trivy, cosign, git -- the same image the controller runs, so the
    # tooling is pinned in exactly one place.
    - name: tools
      image: docker.io/jahadulrakib/jenkins-devops-kubernetes:lts-jdk21
      command: ["sleep"]
      args: ["infinity"]
      resources:
        requests: {cpu: 100m, memory: 512Mi}
        limits:   {memory: 1200Mi}

    # Distroless -- there is no /bin/sh, only /busybox. `command: cat` + tty is
    # the standard trick to keep it alive for `container('kaniko')` steps.
    - name: kaniko
      image: gcr.io/kaniko-project/executor:v1.23.2-debug
      command: ["/busybox/cat"]
      tty: true
      # Kaniko unpacks base-image layers onto the container root filesystem, so
      # it must be root. It does NOT need privileged or a docker socket.
      securityContext:
        runAsUser: 0
      resources:
        requests: {cpu: 200m, memory: 512Mi}
        limits:   {memory: 1500Mi}

    # ~20 MB. Pushes the scanned tarball; also what makes "push the artifact you
    # scanned" possible at all.
    - name: crane
      image: gcr.io/go-containerregistry/crane:debug
      command: ["/busybox/sh", "-c", "sleep infinity"]
      resources:
        requests: {cpu: 50m, memory: 128Mi}
        limits:   {memory: 512Mi}
'''
        }
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
        timeout(time: 30, unit: 'MINUTES')
    }

    triggers {
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
        // One generic chart at helm/ serves any app -- the app's identity lives
        // in values.yaml (nameOverride + image), not in the chart path.
        HELM_RELEASE = 'notes-app'
        HELM_CHART_DIR = 'helm'
        HELM_VALUES_FILE = 'helm/values.yaml'

        // CI
        CI_BOT_NAME = 'jenkins-ci'
        CI_BOT_EMAIL = 'jenkins-ci@users.noreply.github.com'
        CI_SKIP_TOKEN = '[ci skip]'

        // Security
        TRIVY_SEVERITY = 'HIGH,CRITICAL'
        TRIVY_EXIT_CODE = '1'
        TRIVY_CACHE_DIR = '/var/tmp/jenkins-trivy-cache'

        // Optional Cosign signing -- both must be set for the stage to run.
        COSIGN_CREDENTIALS_ID = 'cosign-key'
        COSIGN_PASSWORD_CREDENTIALS_ID = 'cosign-key-password'
        COSIGN_MAJOR_VERSION = '2'

        // Where kaniko, crane and cosign all look for registry auth. Set as a
        // DIRECTORY (they append /config.json). Living in the workspace is what
        // lets three containers share one login.
        DOCKER_CONFIG = "${WORKSPACE}/.docker"

        // The build artifact that moves between containers.
        IMAGE_TARBALL = "${WORKSPACE}/image.tar"
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

        // One login for the whole pod. Kaniko and crane are distroless -- there
        // is no `docker login` to run in them -- so the config.json they both
        // read is written by hand here, once.
        stage('Registry Auth') {
            when {
                not { changelog '(?s).*\\[ci skip\\].*' }
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

                        mkdir -p "$DOCKER_CONFIG"

                        # 0600 before anything is written -- the file holds a
                        # registry token in reversible base64, not a hash.
                        umask 077

                        # Docker Hub is addressed by its v1 alias in auth files
                        # even though pushes go to registry-1.docker.io. Using
                        # "docker.io" here produces a config kaniko reads
                        # without error and then 401s on push.
                        AUTH=$(printf '%s:%s' "$REGISTRY_USER" "$REGISTRY_PASSWORD" | base64 | tr -d '\\n')

                        cat > "$DOCKER_CONFIG/config.json" <<JSON
{
  "auths": {
    "https://index.docker.io/v1/": { "auth": "$AUTH" }
  }
}
JSON
                        echo "Wrote registry auth for $REGISTRY_USER to \\$DOCKER_CONFIG."
                    '''
                }
            }
        }

        stage('Build Image') {
            when {
                not { changelog '(?s).*\\[ci skip\\].*' }
            }
            options {
                timeout(time: 20, unit: 'MINUTES')
            }
            steps {
                container('kaniko') {
                    // /busybox/sh: the kaniko image has no /bin/sh.
                    sh '''#!/busybox/sh
                        set -e

                        # --no-push + --tar-path is the whole point: build now,
                        # push only after Trivy has passed. --destination is
                        # still required, because it is what stamps the ref
                        # INTO the tarball -- crane later pushes it under
                        # exactly this name.
                        #
                        # The flag is --tar-path. NOT --tarball-path, which
                        # kaniko rejects by printing its entire help text and
                        # exiting 1, with no line saying which flag was wrong.
                        #
                        # --context dir:// -- the shared workspace, already
                        # checked out by the tools container.
                        /kaniko/executor \
                            --context "dir://$WORKSPACE" \
                            --dockerfile "$WORKSPACE/Dockerfile" \
                            --destination "$IMAGE_REPOSITORY:$IMAGE_TAG" \
                            --no-push \
                            --tar-path "$IMAGE_TARBALL" \
                            --single-snapshot \
                            --label "org.opencontainers.image.title=$APP_NAME" \
                            --label "org.opencontainers.image.revision=$GIT_SHA" \
                            --label "org.opencontainers.image.source=https://$GIT_REPOSITORY" \
                            --label "org.opencontainers.image.created=$BUILD_TIMESTAMP" \
                            --label "org.opencontainers.image.version=$IMAGE_TAG"

                        ls -la "$IMAGE_TARBALL"
                    '''
                }
            }
        }

        // Gates the push. Scans the tarball rather than a registry ref, so
        // nothing has been published at the point this can still fail.
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

                    # --input, NOT --image-src docker: there is no docker daemon
                    # to read from. This is the kaniko tarball on disk.
                    TRIVY_COMMON="--cache-dir $TRIVY_CACHE_DIR \
                        --offline-scan \
                        $SKIP_UPDATE"

                    trivy image $TRIVY_COMMON \
                        --input "$IMAGE_TARBALL" \
                        --severity "$TRIVY_SEVERITY" \
                        --ignore-unfixed \
                        --scanners vuln,secret \
                        --exit-code "$TRIVY_EXIT_CODE" \
                        --format table \
                        --output trivy-image-report.txt

                    # SBOM: lets this image be re-checked against future CVEs.
                    trivy image $TRIVY_COMMON \
                        --input "$IMAGE_TARBALL" \
                        --format cyclonedx \
                        --output sbom-cyclonedx.json
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

                    # The GPU path is not exercised by the default values, so it
                    # would rot unnoticed. Renders the extra resource limit,
                    # nodeSelector and toleration in one pass.
                    helm template "$HELM_RELEASE" "$HELM_CHART_DIR" \
                        --set image="$IMAGE_REPOSITORY:$IMAGE_TAG" \
                        --set gpu.enabled=true \
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
                container('crane') {
                    sh '''#!/busybox/sh
                        set -e

                        # The bytes Trivy just cleared -- not a rebuild. crane
                        # reads $DOCKER_CONFIG/config.json for auth, written in
                        # the Registry Auth stage.
                        crane push "$IMAGE_TARBALL" "$IMAGE_REPOSITORY:$IMAGE_TAG"

                        crane digest "$IMAGE_REPOSITORY:$IMAGE_TAG"
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
                        string(
                                credentialsId: env.COSIGN_CREDENTIALS_ID,
                                variable: 'COSIGN_KEY'
                        ),
                        string(
                                credentialsId: env.COSIGN_PASSWORD_CREDENTIALS_ID,
                                variable: 'COSIGN_PASSWORD'
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

                        # No `docker login` -- cosign reads $DOCKER_CONFIG too.

                        # ---- Rebuild the PEM --------------------------------
                        # Jenkins' "Secret text" field is a single-line password
                        # input. Pasting a multi-line PEM into it concatenates
                        # every line into one, and cosign then dies with
                        # `reading key: invalid pem block` -- Go's pem.Decode
                        # requires the BEGIN marker on its own line. The body is
                        # base64 and survives the concatenation intact, so the
                        # block can be reassembled losslessly.
                        PEM_LABEL='ENCRYPTED SIGSTORE PRIVATE KEY'
                        PEM_BEGIN="-----BEGIN ${PEM_LABEL}-----"
                        PEM_END="-----END ${PEM_LABEL}-----"

                        KEY_LINES=$(printf '%s\n' "$COSIGN_KEY" | wc -l | tr -d ' ')
                        echo "cosign key: ${#COSIGN_KEY} chars, ${KEY_LINES} line(s)"

                        # Drop CR only. The markers contain SPACES, so stripping
                        # whitespace before locating them destroys the very
                        # thing being searched for.
                        CLEAN=$(printf '%s' "$COSIGN_KEY" | tr -d '\\r')

                        BODY=""
                        case "$CLEAN" in
                            *"$PEM_BEGIN"*"$PEM_END"*)
                                BODY=${CLEAN#*"$PEM_BEGIN"}
                                BODY=${BODY%"$PEM_END"*}
                                # Now safe: the body is base64, which carries no
                                # meaningful whitespace.
                                BODY=$(printf '%s' "$BODY" | tr -d ' \\t\\n')
                                ;;
                        esac

                        if [ -z "$BODY" ]; then
                            echo "ERROR: the '$COSIGN_CREDENTIALS_ID' credential is not a cosign private key." >&2
                            echo "  Expected a PEM bounded by:" >&2
                            echo "    $PEM_BEGIN" >&2
                            echo "    $PEM_END" >&2
                            echo "  Got ${#COSIGN_KEY} chars over ${KEY_LINES} line(s) with no such block." >&2
                            echo "  A single-line paste is fine and is repaired here; a TRUNCATED" >&2
                            echo "  paste is not -- re-enter the credential from" >&2
                            echo "  abc_local_setup/cosign/cosign.key if this persists." >&2
                            exit 1
                        fi

                        # Written to a file rather than re-exported, so the
                        # trailing newline after the END marker is guaranteed --
                        # some pem.Decode paths reject a block without it. umask
                        # keeps it 0600; the trap removes it on any exit path.
                        COSIGN_KEY_FILE=$(mktemp)
                        trap 'rm -f "$COSIGN_KEY_FILE"' EXIT
                        (
                            umask 077
                            {
                                printf '%s\\n' "$PEM_BEGIN"
                                printf '%s' "$BODY" | fold -w 64
                                printf '\\n%s\\n' "$PEM_END"
                            } > "$COSIGN_KEY_FILE"
                        )

                        # --tlog-upload=false: rekor.sigstore.dev is unreachable
                        # with no egress. The Kyverno policy sets
                        # ctlog.ignoreTlog to match -- both or neither.
                        cosign sign --yes --tlog-upload=false \
                            --key "$COSIGN_KEY_FILE" "$IMAGE_REPOSITORY:$IMAGE_TAG"

                        cosign attach sbom --sbom sbom-cyclonedx.json "$IMAGE_REPOSITORY:$IMAGE_TAG"
                    '''
                }
            }
        }

        // Deploying is a git commit, not a kubectl call. Argo CD runs inside
        // the cluster and pulls this change, so Jenkins never needs a route to
        // the API server.
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
                        #
                        # Every git call uses the credentialed URL. `origin` has
                        # no credentials attached, so `git fetch origin` fails
                        # with "could not read Username" and, because set -e is
                        # disabled inside a function used as an if-condition,
                        # the failure used to sail through as success.
                        REMOTE="https://${GIT_USER}:${GIT_TOKEN}@${GIT_REPOSITORY}"

                        update_gitops() {
                            git fetch "$REMOTE" "$GIT_BRANCH" || return 1
                            git checkout -B "$GIT_BRANCH" FETCH_HEAD || return 1

                            # sed, not python3 -- the agent image has no python.
                            sed -i "s|^image:.*|image: $IMAGE_REPOSITORY:$IMAGE_TAG|" \
                                "$HELM_VALUES_FILE" || return 1

                            # Prove the rewrite landed. Without this a failed
                            # edit looks identical to "nothing to do".
                            if ! grep -q "^image: $IMAGE_REPOSITORY:$IMAGE_TAG$" "$HELM_VALUES_FILE"; then
                                echo "ERROR: could not rewrite image line in $HELM_VALUES_FILE" >&2
                                return 1
                            fi

                            git add "$HELM_VALUES_FILE" || return 1

                            if git diff --cached --quiet; then
                                echo "GitOps manifest already at $IMAGE_TAG."
                                return 0
                            fi

                            git commit -m "chore(deploy): $APP_NAME -> $IMAGE_TAG $CI_SKIP_TOKEN" || return 1
                            git push "$REMOTE" "HEAD:$GIT_BRANCH" || return 1
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
            // No `docker logout` / `docker image rm`: nothing was ever loaded
            // into a daemon. Removing the auth file and the tarball is the
            // whole cleanup, and the pod is deleted seconds later anyway.
            sh '''
                rm -rf "$DOCKER_CONFIG" || true
                rm -f "$IMAGE_TARBALL" || true
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
