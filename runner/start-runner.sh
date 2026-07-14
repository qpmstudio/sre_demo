#!/bin/bash
set -e

IMAGE="local-action-runner:latest"
SOCK="/var/run/docker.sock"
KUBECONFIG="${HOME}/.kube/config"

echo "[start-runner] Checking prerequisites..."

if [ ! -S "$SOCK" ]; then
    echo "[start-runner] ERROR: $SOCK not found. Is Docker running?"
    exit 1
fi

if [ ! -f "$KUBECONFIG" ]; then
    echo "[start-runner] ERROR: $KUBECONFIG not found."
    exit 1
fi

: "${GITHUB_PAT:?GITHUB_PAT is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required (format: owner/repo)}"

echo "[start-runner] Building runner image..."
docker build -t "$IMAGE" "$(dirname "$0")"

echo "[start-runner] Starting runner container..."
docker run -d --rm \
    --name local-github-runner \
    -v "${SOCK}:${SOCK}" \
    -v "${KUBECONFIG}:/home/runner/.kube/config" \
    -e GITHUB_PAT \
    -e GITHUB_REPO \
    "$IMAGE"

echo "[start-runner] Runner container started. View logs: docker logs -f local-github-runner"
