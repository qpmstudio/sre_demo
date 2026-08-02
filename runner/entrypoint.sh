#!/bin/bash
set -e
exec 2>&1

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

: "${GITHUB_PAT:?GITHUB_PAT is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required (owner/repo)}"

# The actions-runner binary refuses to run as root by default. The container
# runs as root so kaniko can build images, so opt in explicitly.
export RUNNER_ALLOW_RUNASROOT=1

API_BASE="https://api.github.com/repos/${GITHUB_REPO}/actions/runners"
RUNNER_NAME="local-$(hostname)-$$"

# ── in-cluster kubeconfig from the mounted ServiceAccount token ──
ts "=== Generating in-cluster kubeconfig ==="
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
if [ -d "$SA_DIR" ] && [ -f "$SA_DIR/token" ]; then
  kubectl config set-cluster ci --server=https://kubernetes.default.svc \
    --certificate-authority="$SA_DIR/ca.crt" >/dev/null
  kubectl config set-credentials ci --token="$(cat "$SA_DIR/token")" >/dev/null
  kubectl config set-context ci --cluster=ci --user=ci >/dev/null
  kubectl config use-context ci >/dev/null
  ts "kubeconfig ready; nodes: $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
else
  ts "WARNING: no SA token mounted — kubectl will not work"
fi

cleanup() {
  ts "=== Deregistering runner ==="
  REMOVE_TOKEN=$(curl -s --tls-max 1.2 -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "${API_BASE}/remove-token" | jq -r '.token' 2>/dev/null || true)
  if [ -n "$REMOVE_TOKEN" ] && [ "$REMOVE_TOKEN" != "null" ]; then
    ./config.sh remove --token "$REMOVE_TOKEN" || true
    ts "Runner deregistered."
  else
    ts "Could not obtain remove token; may need manual cleanup."
  fi
}
trap cleanup EXIT

ts "=== Registering runner ==="
REG_TOKEN=$(curl -s --tls-max 1.2 -X POST \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Accept: application/vnd.github+json" \
  "${API_BASE}/registration-token" | jq -r '.token' 2>/dev/null || true)
if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
  ts "FATAL: failed to get registration token (check PAT scope/repo admin)"
  exit 1
fi

./config.sh --url "https://github.com/${GITHUB_REPO}" \
  --token "$REG_TOKEN" --unattended --name "$RUNNER_NAME"

ts "=== Runner online. Waiting for jobs ==="
./run.sh
