#!/usr/bin/env bash
# =============================================================================
# Credentials for the k3s-lab CI/CD stack. Run from the repository root:
#
#     ./k3s-lab/setup-credentials.sh
#
# Creates:
#   1. argocd/notes-app-repo    -- lets Argo CD clone the private repo
#   2. jenkins/jenkins-creds    -- the four credentials the Jenkinsfile needs
#   3. re-runs `helm upgrade jenkins` so JCasC turns (2) into real Jenkins
#      credentials with the exact IDs the Jenkinsfile looks up
#
# Every prompt reads with echo off, so nothing reaches your shell history, the
# process list, or this file. Re-runnable: each step is an upsert, so this is
# also the rotation path.
#
# The cosign key and password are read from abc_local_setup/cosign/ rather than
# prompted -- they are files, not strings you can sensibly paste.
# =============================================================================
set -euo pipefail

: "${KUBECONFIG:=$HOME/.kube/k3s-lab.yaml}"
export KUBECONFIG
echo "Using KUBECONFIG=$KUBECONFIG"

REPO_URL="https://github.com/Jahadul-Rakib/test-app.git"
GITHUB_USER="Jahadul-Rakib"
DOCKERHUB_USER="jahadulrakib"
COSIGN_KEY_FILE="abc_local_setup/cosign/cosign.key"
COSIGN_PASSWORD_FILE="abc_local_setup/cosign/cosign.password"

for f in "$COSIGN_KEY_FILE" "$COSIGN_PASSWORD_FILE"; do
    [ -r "$f" ] || { echo "ERROR: cannot read $f -- run from the repo root." >&2; exit 1; }
done

# --- collect -----------------------------------------------------------------
# `read -rs` = raw (no backslash mangling in a token) + silent (no echo).
read -rs -p "GitHub PAT  (repo scope, WRITE -- Update GitOps commits back): " GH_PAT; echo
read -rs -p "Docker Hub access token: " DH_TOKEN; echo

[ -n "$GH_PAT" ]   || { echo "ERROR: empty GitHub PAT."   >&2; exit 1; }
[ -n "$DH_TOKEN" ] || { echo "ERROR: empty Docker Hub token." >&2; exit 1; }

# --- 1. Argo CD repository credential ----------------------------------------
# Bootstrap credential: it cannot come from the chart, because Argo CD needs it
# to clone the repo that holds the chart. Without it the Application sits in
#   ComparisonError: failed to list refs: authentication required
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: notes-app-repo
  namespace: argocd
  labels:
    # Argo CD ignores the Secret entirely without this label -- the clone then
    # fails exactly as if it did not exist.
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  # Must match spec.source.repoURL in argocd/application.yaml byte for byte.
  url: ${REPO_URL}
  username: ${GITHUB_USER}
  password: ${GH_PAT}
EOF
echo "  [1/3] argocd/notes-app-repo"

# --- 2. Jenkins credential material ------------------------------------------
# The trailing newline is stripped from the password: cosign would otherwise
# treat it as part of the passphrase and fail to decrypt the key. The KEY keeps
# its newlines -- it is a PEM and pem.Decode needs the markers on their own
# lines.
kubectl -n jenkins create secret generic jenkins-creds \
    --from-literal=github-username="${GITHUB_USER}" \
    --from-literal=github-password="${GH_PAT}" \
    --from-literal=dockerhub-username="${DOCKERHUB_USER}" \
    --from-literal=dockerhub-password="${DH_TOKEN}" \
    --from-file=cosign-key="${COSIGN_KEY_FILE}" \
    --from-literal=cosign-password="$(tr -d '\n' < "${COSIGN_PASSWORD_FILE}")" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "  [2/3] jenkins/jenkins-creds"

unset GH_PAT DH_TOKEN

# --- 3. JCasC: turn the secret into Jenkins credentials -----------------------
# Done declaratively rather than by clicking in the UI, so the credentials
# survive a pod restart and a PVC rebuild. additionalExistingSecrets mounts each
# key under /run/secrets/additional/, where JCasC reads it as ${<secret>-<key>}.
#
# The IDs below must match the Jenkinsfile's lookups exactly.
INGRESS_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

cat <<'VALUES' | helm upgrade jenkins jenkins/jenkins \
    --namespace jenkins --version 5.9.54 --reuse-values -f - \
    --set controller.jenkinsUrl="http://${INGRESS_IP}/jenkins" \
    --wait --timeout 12m >/dev/null
controller:
  additionalExistingSecrets:
    - {name: jenkins-creds, keyName: github-username}
    - {name: jenkins-creds, keyName: github-password}
    - {name: jenkins-creds, keyName: dockerhub-username}
    - {name: jenkins-creds, keyName: dockerhub-password}
    - {name: jenkins-creds, keyName: cosign-key}
    - {name: jenkins-creds, keyName: cosign-password}
  JCasC:
    configScripts:
      credentials: |
        credentials:
          system:
            domainCredentials:
              - credentials:
                  - usernamePassword:
                      scope: GLOBAL
                      id: "github-token"
                      username: "${jenkins-creds-github-username}"
                      password: "${jenkins-creds-github-password}"
                      description: "GitHub PAT -- clone + GitOps write-back"
                  - usernamePassword:
                      scope: GLOBAL
                      id: "dockerhub"
                      username: "${jenkins-creds-dockerhub-username}"
                      password: "${jenkins-creds-dockerhub-password}"
                      description: "Docker Hub -- kaniko/crane push"
                  - string:
                      scope: GLOBAL
                      id: "cosign-key"
                      secret: "${jenkins-creds-cosign-key}"
                      description: "cosign private key (PEM)"
                  - string:
                      scope: GLOBAL
                      id: "cosign-key-password"
                      secret: "${jenkins-creds-cosign-password}"
                      description: "cosign key password"
VALUES
echo "  [3/3] Jenkins JCasC applied"

echo
echo "Done. Verify:"
echo "  kubectl -n argocd get application notes-app        # sync must leave Unknown"
echo "  open http://${INGRESS_IP}/jenkins/credentials/     # 4 IDs, all GLOBAL"
