> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在本地 Docker Desktop 上搭建 GitHub Actions self-hosted runner + Go demo 应用，实现 push → build → deploy → verify 的开发闭环

**Architecture:** Runner 容器通过 DooD 模式挂载宿主机 docker.sock 和 kubeconfig，直接操控 Docker 和 K8s。Demo 应用是标准 Go HTTP 服务，多阶段构建为 ~8MB 的 Alpine 镜像，部署到本地 K8s 的 demo-dev 命名空间。

**Tech Stack:** Go 1.22+ (stdlib), Docker (multi-stage), Kubernetes (ClusterIP), GitHub Actions (self-hosted), Bash

## Global Constraints

- Go 仅使用标准库，无第三方依赖
- Runner 基础镜像 ubuntu:22.04
- Demo 运行镜像 alpine:3.20
- K8s Namespace: demo-dev, Service: ClusterIP:8080
- 镜像: demo-app:dev-latest, imagePullPolicy: IfNotPresent
- 所有 .sh 文件需要可执行权限

---

### Task 1: Demo 应用 — Go 模块与健康检查接口

**Files:**
- Create: `demo/go.mod`
- Create: `demo/main.go`

**Interfaces:**
- Consumes: none
- Produces: Go HTTP server on :8080, `GET /health` → `{"status":"ok","started_at":"<RFC3339>"}`

- [ ] **Step 1: 创建 go.mod**

`demo/go.mod`:
```go
module sre-demo

go 1.22
```

- [ ] **Step 2: 创建 main.go**

`demo/main.go`:
```go
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

var startedAt = time.Now()

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)

	log.Printf("demo-app listening on :8080, started at %s", startedAt.Format(time.RFC3339))
	if err := http.ListenAndServe(":8080", mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status":     "ok",
		"started_at": startedAt.Format(time.RFC3339),
	})
}
```

- [ ] **Step 3: 本地验证 Demo 应用**

```bash
cd demo && go run main.go &
sleep 1
curl -s localhost:8080/health
# 预期: {"started_at":"...","status":"ok"}
kill %1
```

- [ ] **Step 4: 验证 go.mod 整洁**

```bash
cd demo && go mod tidy
```

- [ ] **Step 5: Commit**

```bash
git add demo/go.mod demo/main.go
git commit -m "feat: 添加 Go demo 应用及 /health 接口"
```

---

### Task 2: Demo 应用 — Dockerfile（多阶段构建）

**Files:**
- Create: `demo/Dockerfile`

**Interfaces:**
- Consumes: `demo/main.go`, `demo/go.mod`
- Produces: Docker image `demo-app:dev-latest`

- [ ] **Step 1: 创建 demo/Dockerfile**

`demo/Dockerfile`:
```dockerfile
# Stage 1: build
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -o /demo-app .

# Stage 2: run
FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=builder /demo-app /demo-app
EXPOSE 8080
ENTRYPOINT ["/demo-app"]
```

- [ ] **Step 2: 构建镜像**

```bash
docker build -t demo-app:dev-latest ./demo
```

- [ ] **Step 3: 验证镜像运行**

```bash
docker run --rm -d -p 8080:8080 --name demo-test demo-app:dev-latest
sleep 1
curl -s localhost:8080/health
# 预期: {"started_at":"...","status":"ok"}
docker stop demo-test
```

- [ ] **Step 4: Commit**

```bash
git add demo/Dockerfile
git commit -m "feat: 添加 demo 应用多阶段 Dockerfile"
```

---

### Task 3: K8s 部署 YAML

**Files:**
- Create: `demo/k8s/deployment.yaml`

**Interfaces:**
- Consumes: Docker image `demo-app:dev-latest`
- Produces: K8s Deployment + Service in namespace `demo-dev`

- [ ] **Step 1: 创建 deployment.yaml**

`demo/k8s/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: demo-dev
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
    spec:
      containers:
        - name: demo-app
          image: demo-app:dev-latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: demo-app
  namespace: demo-dev
spec:
  type: ClusterIP
  selector:
    app: demo-app
  ports:
    - port: 8080
      targetPort: 8080
```

- [ ] **Step 2: Commit**

```bash
git add demo/k8s/deployment.yaml
git commit -m "feat: 添加 K8s Deployment + Service 配置"
```

---

### Task 4: Runner — Dockerfile

**Files:**
- Create: `runner/Dockerfile`

**Interfaces:**
- Consumes: none
- Produces: Docker image with docker-ce-cli, kubectl, GitHub Actions runner

- [ ] **Step 1: 创建 runner/Dockerfile**

`runner/Dockerfile`:
```dockerfile
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base packages
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    git \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update && apt-get install -y docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm kubectl

# Create runner user
RUN useradd -m -s /bin/bash runner

# Install GitHub Actions runner
ENV RUNNER_VERSION=2.323.0
RUN cd /home/runner \
    && curl -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && tar xzf actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && rm actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && ./bin/installdependencies.sh \
    && chown -R runner:runner /home/runner

COPY entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

USER runner
WORKDIR /home/runner
ENTRYPOINT ["/home/runner/entrypoint.sh"]
```

- [ ] **Step 2: Commit**

```bash
git add runner/Dockerfile
git commit -m "feat: 添加 Runner Dockerfile"
```

---

### Task 5: Runner — entrypoint.sh

**Files:**
- Create: `runner/entrypoint.sh`

**Interfaces:**
- Consumes: env `GITHUB_PAT`, `GITHUB_REPO`
- Produces: Registered GitHub Actions runner, cleanup on exit

- [ ] **Step 1: 创建 entrypoint.sh**

`runner/entrypoint.sh`:
```bash
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
```

- [ ] **Step 2: Commit**

```bash
git add runner/entrypoint.sh
git commit -m "feat: 添加 Runner entrypoint 脚本"
```

---

### Task 6: Runner — start-runner.sh

**Files:**
- Create: `runner/start-runner.sh`

**Interfaces:**
- Consumes: env `GITHUB_PAT`, `GITHUB_REPO`, host `docker.sock`, host `kubeconfig`
- Produces: Running runner container

- [ ] **Step 1: 创建 start-runner.sh**

`runner/start-runner.sh`:
```bash
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
```

- [ ] **Step 2: 给启动脚本添加可执行权限**

```bash
chmod +x runner/start-runner.sh
```

- [ ] **Step 3: Commit**

```bash
git add runner/start-runner.sh
git commit -m "feat: 添加 Runner 宿主机启动脚本"
```

---

### Task 7: GitHub Actions Workflow

**Files:**
- Create: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: Docker CLI + kubectl (via runner), demo/ source, demo/k8s/deployment.yaml
- Produces: Deployed demo-app in K8s, health check verification

- [ ] **Step 1: 创建 deploy.yml**

`.github/workflows/deploy.yml`:
```yaml
name: Local K8s Deploy

on:
  push:
    branches:
      - dev

jobs:
  build-and-deploy:
    runs-on: self-hosted
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Build Docker Image
        run: docker build -t demo-app:dev-latest ./demo

      - name: Ensure Namespace
        run: |
          kubectl create namespace demo-dev --dry-run=client -o yaml | kubectl apply -f -

      - name: Deploy to K8s
        run: kubectl apply -f demo/k8s/deployment.yaml -n demo-dev

      - name: Wait for Rollout
        run: kubectl rollout status deployment/demo-app -n demo-dev --timeout=60s

      - name: Health Check
        run: |
          kubectl port-forward -n demo-dev svc/demo-app 8080:8080 &
          PF_PID=$!
          sleep 2
          curl -s --retry 5 --retry-connrefused http://localhost:8080/health
          kill $PF_PID 2>/dev/null || true
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat: 添加 GitHub Actions 自举部署 workflow"
```

---

### Task 8: README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: All project files
- Produces: 使用说明文档

- [ ] **Step 1: 创建 README.md**

`README.md`:
````markdown
# SRE — 本地 K8s 自举 CI/CD

在 Docker Desktop 上使用 GitHub Actions self-hosted runner，实现 push → build → deploy → verify 的本地开发闭环。

## 项目结构

```
.
├── runner/
│   ├── Dockerfile          # Runner 镜像：ubuntu + docker-cli + kubectl + actions runner
│   ├── entrypoint.sh       # 容器入口：自动注册/注销 runner
│   └── start-runner.sh     # 宿主机启动脚本
├── demo/
│   ├── main.go             # Go HTTP 服务，/health 返回启动时间
│   ├── Dockerfile          # 多阶段构建
│   ├── go.mod
│   └── k8s/
│       └── deployment.yaml # K8s Deployment + Service
├── .github/
│   └── workflows/
│       └── deploy.yml      # CI/CD workflow
└── README.md
```

## 前置条件

- Docker Desktop（已启用 Kubernetes）
- Go 1.22+（仅本地开发验证需要）
- 一个 GitHub 仓库，且你的账号对其有 admin 权限
- GitHub Personal Access Token（需要 `repo` 权限）

## 快速开始

### 1. 配置 GitHub 仓库

将本仓库推送到你的 GitHub：
```bash
git remote add origin https://github.com/YOUR_USER/YOUR_REPO.git
git push -u origin master
```

### 2. 启动 Runner

```bash
export GITHUB_PAT="ghp_xxxxxxxxxxxxxxxxxxxx"
export GITHUB_REPO="YOUR_USER/YOUR_REPO"
./runner/start-runner.sh
```

Runner 启动后，在 GitHub 仓库 Settings → Actions → Runners 中可以看到 `local-runner-*` 上线。

### 3. 触发部署

```bash
git checkout -b dev
git push origin dev
```

### 4. 验证

在 GitHub 仓库的 Actions 页面查看 workflow 执行。成功后，`kubectl port-forward -n demo-dev svc/demo-app 8080:8080` 并访问 `localhost:8080/health`。

## 本地验证 Demo（不依赖 Runner）

```bash
cd demo
go run main.go &
curl localhost:8080/health
# {"status":"ok","started_at":"2026-07-15T..."}
```

## 清理

```bash
# 停止 runner
docker stop local-github-runner

# 清理 K8s 资源
kubectl delete namespace demo-dev
```

## 架构

```
Git push → GitHub Actions → Self-hosted Runner (DooD)
                                ├── docker.sock → 宿主机 Docker
                                └── kubeconfig  → Docker Desktop K8s
```
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: 添加 README 使用说明"
```
