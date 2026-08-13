#!/usr/bin/env sh
#
# Creates the Argo CD repository credential so Argo CD can clone this private
# repo. Run before applying application.yaml.
#
#   ./argocd/repo-secret.sh
#
# Supply a username and token; everything else -- the secret-type label, the
# key names Argo CD expects -- is filled in here.
#
# The token is read from a hidden prompt so it never lands in shell history or
# the process list. Export ARGOCD_REPO_TOKEN first to run non-interactively.
#
# Safe to re-run: `kubectl apply` updates the secret in place, which is how you
# rotate the token later.
#
# BOOTSTRAP: Argo CD needs this to clone the repo that holds the chart, so it
# cannot come from the chart itself -- that would be circular. This is why the
# credential is applied by hand rather than managed by Argo CD.
#
# Use a PAT with READ-ONLY `repo` scope. Argo CD only clones; keep it distinct
# from the write-scoped token Jenkins uses so either can be revoked alone.
#
# Alternative, if you have the argocd CLI and are logged in -- it creates an
# equivalent secret for you:
#
#   argocd repo add "$REPO_URL" --username "$GIT_USERNAME" --password <TOKEN>
#
set -eu

NAMESPACE="${NAMESPACE:-argocd}"
SECRET_NAME="${SECRET_NAME:-notes-app-repo}"
GIT_USERNAME="${GIT_USERNAME:-Jahadul-Rakib}"
# Must match spec.source.repoURL in application.yaml EXACTLY -- scheme and
# trailing .git included. A mismatch means Argo CD never associates this
# credential with the repo, and the clone fails as if it did not exist.
REPO_URL="${REPO_URL:-https://github.com/Jahadul-Rakib/test-app.git}"

if [ -z "${ARGOCD_REPO_TOKEN:-}" ]; then
    printf 'GitHub read-only PAT for %s: ' "$GIT_USERNAME" >&2
    stty -echo 2>/dev/null || true
    read -r ARGOCD_REPO_TOKEN
    stty echo 2>/dev/null || true
    printf '\n' >&2
fi

if [ -z "$ARGOCD_REPO_TOKEN" ]; then
    echo "ERROR: no token supplied." >&2
    exit 1
fi

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  labels:
    # Without this label Argo CD ignores the Secret entirely and the clone
    # still fails -- it is what marks it as a repository credential.
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${REPO_URL}
  username: ${GIT_USERNAME}
  password: ${ARGOCD_REPO_TOKEN}
EOF

echo
echo "Verifying ${NAMESPACE}/${SECRET_NAME}:"
kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}{"\n"}'

cat <<'EOF'

Next:

  kubectl apply -f argocd/application.yaml
  kubectl -n argocd get application notes-app -w

If it reports ComparisonError or "authentication required", REPO_URL above does
not match spec.source.repoURL in application.yaml, or the PAT lacks repo scope.
EOF
