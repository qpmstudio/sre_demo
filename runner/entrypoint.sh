#!/bin/bash
set -e

: "${GITHUB_PAT:?GITHUB_PAT is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required (format: owner/repo)}"

API_BASE="https://api.github.com/repos/${GITHUB_REPO}/actions/runners"

cleanup() {
    echo "[runner] Deregistering runner..."
    REMOVE_TOKEN=$(curl -s -X POST \
        -H "Authorization: token ${GITHUB_PAT}" \
        -H "Accept: application/vnd.github+json" \
        "${API_BASE}/remove-token" | jq -r '.token')

    if [ -n "$REMOVE_TOKEN" ] && [ "$REMOVE_TOKEN" != "null" ]; then
        ./config.sh remove --token "${REMOVE_TOKEN}"
        echo "[runner] Deregistered."
    else
        echo "[runner] Could not obtain remove token."
    fi
}
trap cleanup EXIT

echo "[runner] Fetching registration token..."
REG_TOKEN=$(curl -s -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "${API_BASE}/registration-token" | jq -r '.token')

if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
    echo "[runner] ERROR: Failed to get registration token"
    exit 1
fi

echo "[runner] Configuring runner for ${GITHUB_REPO}..."
./config.sh \
    --url "https://github.com/${GITHUB_REPO}" \
    --token "${REG_TOKEN}" \
    --unattended \
    --replace \
    --name "local-runner-$(hostname)"

echo "[runner] Starting runner..."
./run.sh
