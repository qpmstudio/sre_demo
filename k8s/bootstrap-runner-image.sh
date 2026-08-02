#!/bin/bash
set -euo pipefail

KUBECTL="kubectl"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMG="192.168.3.49:30500/actions-runner:latest"

${KUBECTL} create namespace ci --dry-run=client -o yaml | ${KUBECTL} apply -f -
${KUBECTL} apply -f "${SCRIPT_DIR}/runner-sa.yaml"

# Build context: runner/ (Dockerfile + entrypoint.sh) via ConfigMap
${KUBECTL} create configmap runner-build-context -n ci \
  --from-file=Dockerfile="${REPO_ROOT}/runner/Dockerfile" \
  --from-file=entrypoint.sh="${REPO_ROOT}/runner/entrypoint.sh" \
  --dry-run=client -o yaml | ${KUBECTL} apply -f -

${KUBECTL} delete job build-runner-image -n ci --ignore-not-found
${KUBECTL} apply -f "${SCRIPT_DIR}/kaniko-bootstrap-job.yaml"

echo "[bootstrap] waiting for kaniko job..."
${KUBECTL} wait --for=condition=complete job/build-runner-image -n ci --timeout=600s \
  || { echo "[bootstrap] job failed:"; ${KUBECTL} logs job/build-runner-image -n ci --tail=50; exit 1; }

${KUBECTL} logs job/build-runner-image -n ci --tail=10

# Verify the image is in the registry
curl -s -o /dev/null -w "registry manifest -> %{http_code}\n" \
  "http://192.168.3.49:30500/v2/actions-runner/manifests/latest"

${KUBECTL} delete job build-runner-image -n ci --ignore-not-found
