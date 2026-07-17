#!/bin/bash
set -e
exec 2>&1

# ── helpers ─────────────────────────────────────────────────────────────────

elapsed=0
SECTION_START=${SECTION_START:-$(date +%s)}

ts() {
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')
    elapsed=$(($(date +%s) - SECTION_START))
    printf "[%s  +%4ds] %s\n" "$now" "$elapsed" "$*"
}

log_section() {
    echo ""
    ts "╔══════════════════════════════════════════════════════════════"
    ts "║  $*"
    ts "╚══════════════════════════════════════════════════════════════"
}

log_subsection() {
    ts "── $* ──"
}

_curl() {
    local desc="$1"; shift
    ts "→ ${desc}"

    # Try 1: force TLS 1.2 — Docker Desktop DNS proxy at 198.18.0.73
    # rejects TLS 1.3 (error:0A000126: unexpected eof while reading)
    if curl -s --max-time 15 --connect-timeout 10 --tls-max 1.2 "$@" 2>/tmp/curl_err.$$; then
        rm -f /tmp/curl_err.$$
        return 0
    fi
    local err1
    err1=$(cat /tmp/curl_err.$$ 2>/dev/null || true)

    # Try 2: direct (TLS 1.3) — fallback for environments without the proxy
    ts "→ retry TLS 1.3: ${desc}"
    if curl -s --max-time 15 --connect-timeout 10 "$@" 2>/tmp/curl_err.$$; then
        rm -f /tmp/curl_err.$$
        return 0
    fi
    local err2
    err2=$(cat /tmp/curl_err.$$ 2>/dev/null || true)

    # Try 3: specific IPs for api.github.com
    ts "→ retry --resolve: ${desc}"
    local resolve_arg=""
    if echo "$*" | grep -q "api.github.com"; then
        for ip in 140.82.121.6 140.82.121.5 20.205.243.166; do
            if curl -s --max-time 15 --connect-timeout 10 --tls-max 1.2 \
                --resolve "api.github.com:443:${ip}" "$@" 2>/tmp/curl_err.$$; then
                rm -f /tmp/curl_err.$$
                return 0
            fi
            ts "  tried ${ip} — failed, next..."
        done
        rm -f /tmp/curl_err.$$
        return 1
    fi
    if curl -s --max-time 15 --connect-timeout 10 --tls-max 1.2 $resolve_arg "$@" 2>/tmp/curl_err.$$; then
        rm -f /tmp/curl_err.$$
        return 0
    fi
    local err3
    err3=$(cat /tmp/curl_err.$$ 2>/dev/null || true)

    # All attempts failed
    ts "ERROR: all attempts failed for: ${desc}"
    ts "  TLS 1.2  : ${err1}"
    ts "  direct   : ${err2}"
    ts "  --resolve: ${err3}"
    rm -f /tmp/curl_err.$$
    return 1
}

# ── environment diagnostics ─────────────────────────────────────────────────

log_section "Runner Entrypoint — Environment Diagnostics"

ts "User       : $(whoami)  (uid=$(id -u)  gid=$(id -g))"
ts "Hostname   : $(hostname)"
ts "Home       : $HOME"
ts "Workdir    : $(pwd)"
ts "Shell      : ${SHELL}"
ts "Kernel     : $(uname -srm)"
ts "Arch       : $(uname -m)"
ts "Uptime     : $(uptime 2>/dev/null || echo 'N/A')"

log_subsection "Disk Usage"
df -h / /tmp 2>/dev/null | while read -r line; do ts "$line"; done

log_subsection "Installed Tools"
ts "curl       : $(curl --version 2>&1 | head -1 || echo 'NOT FOUND')"
ts "jq         : $(jq --version 2>&1 || echo 'NOT FOUND')"
ts "git        : $(git --version 2>&1 || echo 'NOT FOUND')"
ts "docker-cli : $(docker --version 2>&1 || echo 'NOT FOUND')"
ts "kubectl    : $(kubectl version kubectl version --client 2>&1 | head -1 || echo 'NOT FOUND')"

log_subsection "Network Interfaces"
ip addr show 2>/dev/null | grep -E '^[0-9]|inet ' | while read -r line; do ts "$line"; done || ts "ip command unavailable"

# ── mandatory env vars ──────────────────────────────────────────────────────

: "${GITHUB_PAT:?GITHUB_PAT is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required (format: owner/repo)}"

API_BASE="https://api.github.com/repos/${GITHUB_REPO}/actions/runners"
ts "GITHUB_REPO: ${GITHUB_REPO}"
ts "GITHUB_ORG : ${GITHUB_ORG:-not set}"
ts "API Base    : ${API_BASE}"
ts "PAT         : length=${#GITHUB_PAT} chars, prefix=${GITHUB_PAT:0:4}***"
ts "Runner Name : local-$(hostname)-$$"

# ── network pre-flight ──────────────────────────────────────────────────────

log_section "Network Pre-flight Checks"

log_subsection "DNS: api.github.com"
ts "$(dig +short api.github.com 2>/dev/null || nslookup api.github.com 2>/dev/null || echo 'dig/nslookup not available')"

log_subsection "TCP: api.github.com:443"
if timeout 5 bash -c "echo >/dev/tcp/api.github.com/443" 2>/dev/null; then
    ts "TCP 443 → api.github.com: REACHABLE"
else
    ts "TCP 443 → api.github.com: UNREACHABLE (will retry via curl)"
fi

log_subsection "HTTP: api.github.com"
HTTP_TEST=$(_curl "api.github.com reachability" -o /dev/null -w "HTTP %{http_code} in %{time_total}s" https://api.github.com 2>&1)
ts "api.github.com → $(echo "$HTTP_TEST" | tail -1)"

# ── Docker daemon check ─────────────────────────────────────────────────────

log_section "Docker Daemon Connectivity"

if [ -S /var/run/docker.sock ]; then
    ts "docker.sock: EXISTS at /var/run/docker.sock"
    DOCKER_INFO=$(timeout 5 docker info --format '{{.ServerVersion}} | Containers:{{.Containers}} Running:{{.ContainersRunning}} | Images:{{.Images}} | OS:{{.OperatingSystem}}' 2>&1)
    ts "docker info: ${DOCKER_INFO}"
else
    ts "WARNING: /var/run/docker.sock not found — container builds will fail"
fi

# ── Kubeconfig check ────────────────────────────────────────────────────────

log_section "Kubernetes Connectivity"

: "${KUBECONFIG:?KUBECONFIG is required}"
ts "KUBECONFIG  : ${KUBECONFIG}"
if [ -f "$KUBECONFIG" ]; then
    ts "kubeconfig  : EXISTS ($(wc -c < "$KUBECONFIG") bytes)"
    K8S_INFO=$(timeout 5 kubectl cluster-info 2>&1 | head -2)
    ts "cluster-info: $(echo "$K8S_INFO" | tr '\n' ' ')"
    K8S_NODES=$(timeout 5 kubectl get nodes --no-headers 2>&1 | wc -l)
    ts "nodes       : ${K8S_NODES}"
else
    ts "ERROR: kubeconfig file not found at ${KUBECONFIG}"
    exit 1
fi

# ── PAT validation ──────────────────────────────────────────────────────────

log_section "GitHub PAT Validation"

# Use -w to extract HTTP code reliably (response body is JSON, doesn't contain "HTTP \d+")
set +e
PAT_RESP=$(_curl "PAT check for ${GITHUB_REPO}" -w "\n__HTTP_CODE__:%{http_code}" \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPO}" 2>&1)
PAT_EXIT=$?
set -e

PAT_HTTP=$(echo "$PAT_RESP" | grep '__HTTP_CODE__:' | sed 's/.*__HTTP_CODE__://')
PAT_BODY=$(echo "$PAT_RESP" | grep -v '__HTTP_CODE__:')

if [ "$PAT_EXIT" = "0" ] && [ -n "$PAT_HTTP" ]; then
    ts "PAT → ${GITHUB_REPO}: HTTP ${PAT_HTTP}"
    if [ "$PAT_HTTP" = "200" ]; then
        ts "PAT → ${GITHUB_REPO}: VALID"
    elif [ "$PAT_HTTP" = "404" ]; then
        ts "ERROR: Repo '${GITHUB_REPO}' not found or PAT lacks access"
        ts "       Verify the repo exists and the PAT has 'repo' scope."
        exit 1
    elif [ "$PAT_HTTP" = "401" ]; then
        ts "ERROR: PAT invalid or expired"
        exit 1
    else
        ts "WARNING: Unexpected HTTP ${PAT_HTTP} from GitHub API"
    fi
else
    ts "WARNING: All PAT check attempts failed — check network/proxy"
    ts "         Set HTTPS_PROXY if you have a proxy available."
fi

# ── cleanup trap ────────────────────────────────────────────────────────────

cleanup() {
    echo ""
    log_section "Cleanup — Deregistering Runner"
    ts "Removing runner '${RUNNER_NAME:-unknown}' from ${GITHUB_REPO}..."

    REMOVE_RESP=$(_curl "Remove token" -X POST \
        -H "Authorization: token ${GITHUB_PAT}" \
        -H "Accept: application/vnd.github+json" \
        "${API_BASE}/remove-token" 2>&1)
    REMOVE_TOKEN=$(echo "$REMOVE_RESP" | jq -r '.token' 2>/dev/null)

    if [ -n "$REMOVE_TOKEN" ] && [ "$REMOVE_TOKEN" != "null" ]; then
        ts "Got remove token, deregistering..."
        ./config.sh remove --token "${REMOVE_TOKEN}"
        ts "Runner deregistered successfully."
    else
        ts "Could not obtain remove token (body: ${REMOVE_RESP:0:200})"
        ts "The runner may need manual removal from GitHub UI."
    fi
}
trap cleanup EXIT

# ── runner registration ─────────────────────────────────────────────────────

log_section "Step 1 — Fetching Registration Token"

set +e
REG_RESP=$(_curl "Registration token" -w "\n__HTTP_CODE__:%{http_code}" -X POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "${API_BASE}/registration-token" 2>&1)
REG_EXIT=$?
set -e

HTTP_CODE=$(echo "$REG_RESP" | grep '__HTTP_CODE__:' | sed 's/.*__HTTP_CODE__://')
REG_BODY=$(echo "$REG_RESP" | awk '/^{/,/^}/')
REG_TOKEN=$(echo "$REG_BODY" | jq -r '.token' 2>/dev/null)

ts "HTTP         : ${HTTP_CODE}"
ts "Token        : ${REG_TOKEN:0:10}*** (length=${#REG_TOKEN})"
ts "Response     : $(echo "$REG_BODY" | jq -c '.' 2>/dev/null || echo "$REG_BODY")"

if [ "$HTTP_CODE" != "201" ]; then
    ts "FATAL: Registration failed — expected HTTP 201, got ${HTTP_CODE}"
    ts "       Verify GITHUB_PAT has admin:org or repo scope."
    exit 1
fi

if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
    ts "FATAL: Registration token is empty or null"
    exit 1
fi

RUNNER_NAME="local-$(hostname)-$$"

log_section "Step 2 — Configuring Runner"
ts "Runner name  : ${RUNNER_NAME}"
ts "Runner URL   : https://github.com/${GITHUB_REPO}"

runuser -u runner -- ./config.sh \
    --url "https://github.com/${GITHUB_REPO}" \
    --token "${REG_TOKEN}" \
    --unattended \
    --name "${RUNNER_NAME}" \
    </dev/null 2>&1 | while read -r line; do ts "$line"; done

log_section "Step 3 — Starting Runner"
ts "Runner is now online. Waiting for jobs from ${GITHUB_REPO}..."
ts "Press Ctrl+C to stop and deregister."
echo ""

# Fix ownership so runner user can read config files
chown -R runner:runner /home/runner 2>/dev/null || true

# Ensure runner user can access docker.sock (host's GID differs from container's docker group)
SOCK_GID=$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)
if [ -n "$SOCK_GID" ] && ! id -G runner 2>/dev/null | tr ' ' '\n' | grep -qx "$SOCK_GID"; then
    groupadd -g "$SOCK_GID" docker_sock 2>/dev/null || true
    usermod -a -G "$(getent group "$SOCK_GID" | cut -d: -f1)" runner 2>/dev/null || true
fi

exec runuser -u runner -- ./run.sh
