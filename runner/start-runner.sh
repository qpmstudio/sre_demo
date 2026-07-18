#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="local-action-runner:latest"
KUBECONFIG="${HOME}/.kube/config"
RUNNER_VERSION="2.323.0"
RUNNER_ARCHIVE="${SCRIPT_DIR}/actions-runner.tar.gz"

GITHUB_REPO="${1:?Usage: $0 <owner/repo> [--shell]}"
CONTAINER_NAME="gh-runner-${GITHUB_REPO//\//-}"

echo "[start-runner] Checking prerequisites..."

: "${DOCKER_HOST:?DOCKER_HOST is required (e.g. tcp://host.docker.internal:2375)}"

if ! docker info >/dev/null 2>&1; then
    echo "[start-runner] ERROR: Cannot connect to Docker at ${DOCKER_HOST}"
    exit 1
fi

if [ ! -f "$KUBECONFIG" ]; then
    echo "[start-runner] ERROR: $KUBECONFIG not found."
    exit 1
fi

: "${GITHUB_PAT:?GITHUB_PAT is required}"

# Download runner binary if not already cached
if [ ! -f "$RUNNER_ARCHIVE" ]; then
    RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    MIRRORS=(
        "$RUNNER_URL"
        "https://mirror.ghproxy.com/$RUNNER_URL"
        "https://ghproxy.com/$RUNNER_URL"
    )

    for url in "${MIRRORS[@]}"; do
        echo "[start-runner] Trying: $url"
        rm -f "$RUNNER_ARCHIVE"
        if curl -fsSL --connect-timeout 30 --max-time 600 -o "$RUNNER_ARCHIVE" "$url"; then
            SIZE=$(stat -c%s "$RUNNER_ARCHIVE" 2>/dev/null || echo 0)
            if [ "$SIZE" -gt 50000000 ]; then
                echo "[start-runner] Download OK (${SIZE} bytes)"
                break
            else
                echo "[start-runner] File too small (${SIZE} bytes), retrying..."
                rm -f "$RUNNER_ARCHIVE"
            fi
        else
            echo "[start-runner] Download failed from this source."
        fi
    done

    if [ ! -f "$RUNNER_ARCHIVE" ]; then
        echo "[start-runner] ERROR: All download sources failed."
        echo "[start-runner] Please download manually:"
        echo "  curl -L -o $RUNNER_ARCHIVE \"$RUNNER_URL\""
        exit 1
    fi

    echo "[start-runner] Runner binary cached at ${RUNNER_ARCHIVE}"
else
    echo "[start-runner] Using cached runner binary."
fi

# echo "[start-runner] Building runner image..."
# docker build -t "$IMAGE" "$SCRIPT_DIR"

echo "[start-runner] Starting runner container (foreground for debugging)..."
# Clean up any previous runner container
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[start-runner] Removing previous runner container..."
    docker stop "${CONTAINER_NAME}" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}" 2>/dev/null || true
fi

# Read and encode kubeconfig to pass via env (avoids WSL2 file-sharing mount issues)
KUBECONFIG_B64=$(base64 -w 0 "${KUBECONFIG}")

if [ "${2:-}" = "--shell" ]; then
    echo "[start-runner] Starting interactive shell in runner container..."
    docker run --rm -it \
        --name "${CONTAINER_NAME}" \
        -e DOCKER_HOST="tcp://host.docker.internal:2375" \
        -e GITHUB_PAT \
        -e GITHUB_REPO="${GITHUB_REPO}" \
        -e KUBECONFIG="/tmp/kubeconfig" \
        -e KUBECONFIG_B64="${KUBECONFIG_B64}" \
        --entrypoint bash \
        "$IMAGE"
else
    echo "[start-runner] Starting runner container in background..."
    docker run -d --rm \
        --name "${CONTAINER_NAME}" \
        -e DOCKER_HOST="tcp://host.docker.internal:2375" \
        -e GITHUB_PAT \
        -e GITHUB_REPO="${GITHUB_REPO}" \
        -e KUBECONFIG="/tmp/kubeconfig" \
        -e KUBECONFIG_B64="${KUBECONFIG_B64}" \
        "$IMAGE"
fi
