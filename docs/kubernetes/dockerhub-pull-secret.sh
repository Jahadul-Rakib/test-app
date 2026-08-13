#!/usr/bin/env sh
#
# Creates the image pull secret for docker.io/jahadulrakib/notes-app.
#
# Supply a username and token; kubectl builds the .dockerconfigjson itself,
# including the base64 `auth` field. Nothing to assemble or encode by hand.
#
#   ./kubernetes/dockerhub-pull-secret.sh
#
# The token is read from a hidden prompt so it never lands in shell history or
# the process list. Export DOCKERHUB_TOKEN first to run non-interactively.
#
# Safe to re-run: the generated manifest is piped through `kubectl apply`, so
# this creates the secret the first time and rotates the token on later runs.
# (`kubectl create secret` alone would fail with AlreadyExists.)
#
# The chart never creates this secret -- it only references it by name via
# imagePullSecrets in helm/notes-app/values.yaml. That keeps the token out of
# git, since Argo CD renders the chart straight from the repo.
#
# NAMESPACE: must be where the POD runs, not argocd. It is consumed by the
# kubelet on behalf of your pod. Putting it in argocd is the usual cause of
# ImagePullBackOff with "pull access denied". Keep this in step with
# spec.destination.namespace in argocd/application.yaml.
#
# Only needed if the image repository is private. If it is public the kubelet
# pulls anonymously and this secret is never read.
#
set -eu

NAMESPACE="${NAMESPACE:-default}"
SECRET_NAME="${SECRET_NAME:-dockerhub-pull}"
DOCKERHUB_SERVER="${DOCKERHUB_SERVER:-https://index.docker.io/v1/}"
DOCKERHUB_USER="${DOCKERHUB_USER:-jahadulrakib}"

if [ -z "${DOCKERHUB_TOKEN:-}" ]; then
    printf 'Docker Hub token for %s: ' "$DOCKERHUB_USER" >&2
    stty -echo 2>/dev/null || true
    read -r DOCKERHUB_TOKEN
    stty echo 2>/dev/null || true
    printf '\n' >&2
fi

if [ -z "$DOCKERHUB_TOKEN" ]; then
    echo "ERROR: no token supplied." >&2
    exit 1
fi

kubectl create secret docker-registry "$SECRET_NAME" \
    --namespace "$NAMESPACE" \
    --docker-server="$DOCKERHUB_SERVER" \
    --docker-username="$DOCKERHUB_USER" \
    --docker-password="$DOCKERHUB_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Verifying ${NAMESPACE}/${SECRET_NAME}:"
kubectl -n "$NAMESPACE" get secret "$SECRET_NAME" \
    -o jsonpath='{.type}{"\n"}'
