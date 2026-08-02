#!/bin/bash
set -e
exec 2>&1

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

: "${GITHUB_PAT:?GITHUB_PAT is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required (owner/repo)}"

# The actions-runner binary refuses to run as root by default. The runner runs
# as root in the container (container-scoped); image builds happen in a
# separate kaniko Job, so opt in explicitly.
export RUNNER_ALLOW_RUNASROOT=1

API_BASE="https://api.github.com/repos/${GITHUB_REPO}/actions/runners"
# Stable name so a pod restart re-registers the same runner. The Deployment
# sets a fixed pod hostname (github-runner), so the name survives pod
# recreation. Ghosts left by an unclean shutdown are removed at next startup
# by the stale-runner-removal logic below, which works because the hostname
# (and thus runner name) is stable across pod recreation.
RUNNER_NAME="local-$(hostname)"

# ── in-cluster kubeconfig from the mounted ServiceAccount token ──
ts "=== Generating in-cluster kubeconfig ==="
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
if [ -d "$SA_DIR" ] && [ -f "$SA_DIR/token" ]; then
  kubectl config set-cluster ci --server=https://kubernetes.default.svc \
    --certificate-authority="$SA_DIR/ca.crt" >/dev/null
  kubectl config set-credentials ci --token="$(cat "$SA_DIR/token")" >/dev/null
  kubectl config set-context ci --cluster=ci --user=ci >/dev/null
  kubectl config use-context ci >/dev/null
  ts "kubeconfig ready; namespaces: $(kubectl get namespaces --no-headers 2>/dev/null | wc -l)"
else
  ts "WARNING: no SA token mounted — kubectl will not work"
fi

# Idempotent re-registration: drop any existing runner with our stable name
# before registering. Otherwise a stale registration left by an unclean
# shutdown makes config.sh --unattended fail with "A runner exists with the
# same name" and, via set -e, crash-loops the pod.
ts "=== Removing stale runner registrations for '${RUNNER_NAME}' ==="
EXISTING=$(curl -s --tls-max 1.2 \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Accept: application/vnd.github+json" \
  "${API_BASE}" | jq -r --arg name "$RUNNER_NAME" \
    '.runners[]? | select(.name == $name) | .id' || true)
for id in $EXISTING; do
  ts "Removing stale runner id=${id}"
  curl -s --tls-max 1.2 -X DELETE \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "${API_BASE}/${id}" >/dev/null || true
done

ts "=== Registering runner ==="
REG_TOKEN=$(curl -s --tls-max 1.2 -X POST \
  -H "Authorization: token ${GITHUB_PAT}" \
  -H "Accept: application/vnd.github+json" \
  "${API_BASE}/registration-token" | jq -r '.token' 2>/dev/null || true)
if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
  ts "FATAL: failed to get registration token (check PAT scope/repo admin)"
  exit 1
fi

# --disableupdate: the runner previously auto-updated (2.323.0 -> 2.336.0)
# DURING a workflow job, killing the in-flight Deploy step. Disabling the
# self-update keeps the running version stable across the job lifetime.
./config.sh --url "https://github.com/${GITHUB_REPO}" \
  --token "$REG_TOKEN" --unattended --name "$RUNNER_NAME" --disableupdate

ts "=== Runner online. Waiting for jobs ==="
# exec so run.sh (and its Runner.Listener) becomes PID 1: SIGTERM from
# kubelet reaches the listener directly for a graceful shutdown, instead of
# being absorbed by this wrapper bash waiting on a foreground child.
exec ./run.sh
