# sre_demo → qpmstudio 集群 GitHub Runner 适配实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 sre_demo 的 GitHub Actions self-hosted runner 从 Docker Desktop + DooD 迁移到 qpmstudio kubeadm 集群：runner 以 K8s pod 运行，用 Kaniko 构建镜像推本地 registry，workflow 在 push dev 时完成 build → push → deploy → verify。

**Architecture:** runner 作为 `ci` 命名空间的 Deployment，镜像为自举构建（集群无 Docker，用一次性 kaniko Job 从 runner/Dockerfile 构建）。runner 镜像内含 actions-runner + kubectl + kaniko executor；pod 挂 SA token（in-cluster kubeconfig）与 PAT（Secret）。workflow 在 runner pod 内以 shell 步骤调用 `/kaniko/executor` 构建 demo 镜像并推送到 `192.168.3.49:30500`，再用 kubectl apply 部署到 `demo-dev`。

**Tech Stack:** K8s v1.36.3 / actions-runner v2.323.0 / kaniko v1.24.0 (ghcr.io) / kubectl v1.36.3 / ubuntu:22.04。

## Global Constraints

- **目标集群**: qpmstudio (kubeadm 单节点), kubectl 从本机 `~/.local/bin/kubectl` 管理, server `https://192.168.3.49:6443`。
- **本地 registry**: `192.168.3.49:30500` (HTTP 内网, containerd 已信任)。kaniko push 需 `--insecure`。
- **网络代理**: 家庭网络 ghcr.io blob 拉取超时, 走网关 Clash 代理 `http://192.168.3.155:7890`。kaniko 构建/拉 ghcr 镜像的 pod 需设 `HTTP_PROXY`/`HTTPS_PROXY`, `NO_PROXY` 含 `192.168.3.49,localhost,127.0.0.1,.svc,.cluster.local`。
- **镜像源**: kaniko 镜像 `ghcr.io/kaniko-project/executor:v1.24.0` (gcr.io 已弃用); actions-runner `github.com/actions/runner/releases/download/v2.323.0/actions-runner-linux-x64-2.323.0.tar.gz` (qpmstudio 直连可达, 已验证 200); kubectl 走 pkgs.k8s.io v1.36 apt 源。
- **GitHub**: repo 级注册 `qpmstudio/sre_demo`, PAT (`repo` scope) 以 Secret `ci/github-pat` 存储, 不写进 git。workflow 触发分支 `dev`。
- **命名空间**: runner 在 `ci`, 部署目标在 `demo-dev`。
- **无 Docker**: 集群与本机均无可用 Docker daemon; 一切镜像构建走 kaniko。
- **Runner 以 root 运行** (容器内, 非宿主 root): kaniko 需要 root; SA token 是 K8s 侧安全边界 (scoped RBAC)。个人实验室可接受。
- **语言**: 脚本/注释/YAML 英文; Markdown 正文中文。提交信息用 Conventional Commits + 中文描述 (sre_demo AGENTS.md 约定)。

---

## Task 0: 改造 runner/Dockerfile（runner 镜像定义）

**Files:**
- Modify: `runner/Dockerfile` (整体重写)

**Interfaces:**
- Produces: `runner/Dockerfile` 产出 runner 镜像: ubuntu:22.04 + curl/git/jq + kubectl 1.36.3 + actions-runner 2.323.0 + `/kaniko/executor`。Task 3 的 kaniko Job 用它构建镜像。

- [ ] **Step 1: 重写 `runner/Dockerfile`**

```dockerfile
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl git jq ca-certificates gnupg apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# kubectl v1.36.3 via pkgs.k8s.io (same source as the cluster)
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update && apt-get install -y kubectl=1.36.3-* \
    && rm -rf /var/lib/apt/lists/*

# GitHub Actions runner v2.323.0 (downloaded at build time; github.com reachable)
RUN curl -fsSL -o /tmp/actions-runner.tar.gz \
      https://github.com/actions/runner/releases/download/v2.323.0/actions-runner-linux-x64-2.323.0.tar.gz \
    && mkdir -p /home/runner \
    && tar xzf /tmp/actions-runner.tar.gz -C /home/runner \
    && /home/runner/bin/installdependencies.sh \
    && rm /tmp/actions-runner.tar.gz

# kaniko executor (no-Docker image build inside runner pods)
COPY --from=ghcr.io/kaniko-project/executor:v1.24.0 /kaniko/executor /kaniko/executor

COPY entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh /kaniko/executor

WORKDIR /home/runner
ENTRYPOINT ["/home/runner/entrypoint.sh"]
```

- [ ] **Step 2: 语法校验 (无 docker, 无法本地构建)**

Run: `bash -n runner/entrypoint.sh` (entrypoint 由 Task 1 提供, 若不存在则先以最小 stub 占位; Dockerfile 本身用 `docker build` 以外的静态检查 — 确认每一行语法与镜像名正确)
Expected: 无错误; Dockerfile 引用的资源 (pkgs.k8s.io / github.com / ghcr.io) 均可达。

- [ ] **Step 3: Commit**

```bash
git add runner/Dockerfile
git commit -m "feat: 重写 runner 镜像 — 去 docker, 加 kubectl+kaniko"
```

---

## Task 1: 改造 runner/entrypoint.sh（注册/注销 + in-cluster kubeconfig）

**Files:**
- Modify: `runner/entrypoint.sh` (整体重写, 去掉 DooD/Docker Desktop 逻辑)

**Interfaces:**
- Consumes: 容器环境变量 `GITHUB_PAT`、`GITHUB_REPO`; 挂载的 SA token (`/var/run/secrets/kubernetes.io/serviceaccount/`)。
- Produces: `runner/entrypoint.sh` 注册/注销 runner, 生成 in-cluster kubeconfig。Task 4 部署的 pod 用它作为 ENTRYPOINT。

- [ ] **Step 1: 重写 `runner/entrypoint.sh`**

```bash
#!/bin/bash
set -e
exec 2>&1

ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

: "${GITHUB_PAT:?GITHUB_PAT is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required (owner/repo)}"

API_BASE="https://api.github.com/repos/${GITHUB_REPO}/actions/runners"
RUNNER_NAME="local-$(hostname)-$$"

# ── in-cluster kubeconfig from the mounted ServiceAccount token ──
ts "=== Generating in-cluster kubeconfig ==="
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
if [ -d "$SA_DIR" ] && [ -f "$SA_DIR/token" ]; then
  kubectl config set-cluster ci --server=https://kubernetes.default.svc \
    --certificate-authority="$SA_DIR/ca.crt" >/dev/null
  kubectl config set-credentials ci --token-file="$SA_DIR/token" >/dev/null
  kubectl config set-context ci --cluster=ci --user=ci >/dev/null
  kubectl config use-context ci >/dev/null
  ts "kubeconfig ready; nodes: $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
else
  ts "WARNING: no SA token mounted — kubectl will not work"
fi

cleanup() {
  ts "=== Deregistering runner ==="
  REMOVE_TOKEN=$(curl -s -X POST \
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
REG_TOKEN=$(curl -s -X POST \
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
```

- [ ] **Step 2: 语法校验**

Run: `bash -n runner/entrypoint.sh`
Expected: 无语法错误。

- [ ] **Step 3: Commit**

```bash
git add runner/entrypoint.sh
git commit -m "feat: 简化 entrypoint — in-cluster kubeconfig, 移除 DooD 逻辑"
```

---

## Task 2: 移除 start-runner.sh + 新增 k8s/ 清单（ci-ns / SA+RBAC / deployment / bootstrap Job）

**Files:**
- Delete: `runner/start-runner.sh` (Docker 专用, 由 k8s/ 清单替代)
- Create: `k8s/ci-namespace.yaml`
- Create: `k8s/runner-sa.yaml`
- Create: `k8s/runner-deployment.yaml`
- Create: `k8s/kaniko-bootstrap-job.yaml`
- Create: `k8s/bootstrap-runner-image.sh`

**Interfaces:**
- Consumes: Task 0/1 的 runner 镜像与 entrypoint; PAT Secret `ci/github-pat` (Task 3 创建)。
- Produces: 集群部署所需全部清单。Task 3 执行 bootstrap 并部署 runner。

- [ ] **Step 1: 删除 start-runner.sh**

```bash
git rm runner/start-runner.sh
```

- [ ] **Step 2: 写 `k8s/ci-namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ci
```

- [ ] **Step 3: 写 `k8s/runner-sa.yaml`**

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-runner
  namespace: ci
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ci-runner
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods", "services", "configmaps", "secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ci-runner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ci-runner
subjects:
  - kind: ServiceAccount
    name: ci-runner
    namespace: ci
```

- [ ] **Step 4: 写 `k8s/runner-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: github-runner
  namespace: ci
spec:
  replicas: 1
  selector:
    matchLabels: { app: github-runner }
  template:
    metadata:
      labels: { app: github-runner }
    spec:
      serviceAccountName: ci-runner
      containers:
        - name: runner
          image: 192.168.3.49:30500/actions-runner:latest
          env:
            - name: GITHUB_PAT
              valueFrom:
                secretKeyRef: { name: github-pat, key: token }
            - name: GITHUB_REPO
              value: qpmstudio/sre_demo
            - name: HTTP_PROXY
              value: http://192.168.3.155:7890
            - name: HTTPS_PROXY
              value: http://192.168.3.155:7890
            - name: NO_PROXY
              value: 192.168.3.49,localhost,127.0.0.1,.svc,.cluster.local
```

- [ ] **Step 5: 写 `k8s/kaniko-bootstrap-job.yaml`**

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: build-runner-image
  namespace: ci
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: kaniko
          image: ghcr.io/kaniko-project/executor:v1.24.0
          args:
            - --context=/workspace
            - --destination=192.168.3.49:30500/actions-runner:latest
            - --insecure
          env:
            - name: HTTP_PROXY
              value: http://192.168.3.155:7890
            - name: HTTPS_PROXY
              value: http://192.168.3.155:7890
            - name: NO_PROXY
              value: 192.168.3.49,localhost,127.0.0.1,.svc,.cluster.local
          volumeMounts:
            - name: context
              mountPath: /workspace
      volumes:
        - name: context
          configMap:
            name: runner-build-context
```

- [ ] **Step 6: 写 `k8s/bootstrap-runner-image.sh`**

```bash
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
```

- [ ] **Step 7: 校验与提交**

Run: `bash -n k8s/bootstrap-runner-image.sh && for f in k8s/*.yaml; do kubectl apply --dry-run=client -f "$f" -o yaml >/dev/null && echo "valid $f"; done`
Expected: 全部校验通过。
Commit:
```bash
git add -A
git commit -m "feat: 新增 ci 命名空间/RBAC/runner deployment/kaniko bootstrap 清单"
```

---

## Task 3: 执行 bootstrap（构建 runner 镜像 + 部署 runner + GitHub online）

**Files:**
- Create (执行期): `ci/github-pat` Secret

**Interfaces:**
- Consumes: Task 2 的 bootstrap 脚本与清单; 用户提供的 PAT。
- Produces: runner 镜像在 registry; runner pod Running 且 GitHub 显示 online。

- [ ] **Step 1: 前置 — 用户提供 PAT**

向用户索取 `repo` scope PAT (对 qpmstudio/sre_demo 有 admin 权限)。拿到后:
```bash
kubectl create secret generic github-pat -n ci --from-literal=token="${GITHUB_PAT}" --dry-run=client -o yaml | kubectl apply -f -
```
PAT 只存在 Secret, 不写进 git。

- [ ] **Step 2: 运行 bootstrap 构建 runner 镜像**

Run: `k8s/bootstrap-runner-image.sh`
Expected: 输出 `registry manifest -> 200`; kaniko Job 成功。

- [ ] **Step 3: 部署 runner Deployment**

Run: `kubectl apply -f k8s/runner-deployment.yaml`
Run: `kubectl rollout status deployment/github-runner -n ci --timeout=300s`
Expected: runner pod Running; 日志显示 "Runner online. Waiting for jobs"。

- [ ] **Step 4: 验证 GitHub online**

在浏览器或 API 确认 GitHub 仓库 `Settings → Actions → Runners` 显示 `local-*` online; 或:
```bash
curl -s -H "Authorization: token ${GITHUB_PAT}" \
  "https://api.github.com/repos/qpmstudio/sre_demo/actions/runners" | jq '.runners[] | {name, status}'
```
Expected: status `online`。

- [ ] **Step 5: Commit（无代码变更则跳过; 若 Secret 或环境变量需调整则记录）**

---

## Task 4: 改造 demo/k8s/deployment.yaml（registry 镜像 + 唯一 tag 约定）

**Files:**
- Modify: `demo/k8s/deployment.yaml`

**Interfaces:**
- Consumes: Task 3 的 registry。Produces: workflow (Task 5) 通过 sed 替换 image 字段后 apply 的部署清单。

- [ ] **Step 1: 修改 image 字段**

把 `image: demo-app:dev-latest` 改为 `image: 192.168.3.49:30500/demo-app:dev` (tag 占位, workflow 会替换为 `dev-<sha>`); `imagePullPolicy` 改为 `Always`。Service 段不变。

```yaml
      containers:
        - name: demo-app
          image: 192.168.3.49:30500/demo-app:dev
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
```

- [ ] **Step 2: 校验**

Run: `kubectl apply --dry-run=client -f demo/k8s/deployment.yaml -o yaml >/dev/null && echo valid`
Expected: valid。

- [ ] **Step 3: Commit**

```bash
git add demo/k8s/deployment.yaml
git commit -m "feat: demo 镜像改为本地 registry + 唯一 tag 约定"
```

---

## Task 5: 改造 .github/workflows/deploy.yml（kaniko 构建 + push + apply）

**Files:**
- Modify: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: runner pod 内 `/kaniko/executor` 与 in-cluster kubectl (Task 1/3); Task 4 的 deployment.yaml。
- Produces: 端到端 CI workflow。

- [ ] **Step 1: 重写 `deploy.yml`**

```yaml
name: Local K8s Deploy
on:
  push:
    branches: [dev]
jobs:
  build-and-deploy:
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4

      - name: Ensure namespace
        run: kubectl create namespace demo-dev --dry-run=client -o yaml | kubectl apply -f -

      - name: Build & push image (kaniko)
        run: |
          TAG="dev-${GITHUB_SHA::7}"
          /kaniko/executor --context=./demo \
            --destination=192.168.3.49:30500/demo-app:${TAG} \
            --cache=true --insecure

      - name: Deploy to K8s
        run: |
          TAG="dev-${GITHUB_SHA::7}"
          sed -i "s|image: 192.168.3.49:30500/demo-app:.*|image: 192.168.3.49:30500/demo-app:${TAG}|" demo/k8s/deployment.yaml
          kubectl apply -f demo/k8s/deployment.yaml -n demo-dev

      - name: Wait for rollout
        run: kubectl rollout status deployment/demo-app -n demo-dev --timeout=90s

      - name: Health check
        run: |
          kubectl port-forward -n demo-dev svc/demo-app 8080:8080 & PF=$!
          sleep 3
          curl -s --retry 5 --retry-connrefused http://localhost:8080/health
          kill $PF 2>/dev/null || true
```

- [ ] **Step 2: YAML 校验**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/deploy.yml')); print('valid')"` (若无 pyyaml, 用 `kubectl` 不可校验 GitHub Actions, 手动核对缩进)
Expected: valid。

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat: workflow 改造 — kaniko 构建/推送/部署"
```

---

## Task 6: 端到端验证（push dev → workflow → demo-app 部署）

**Files:** 无新文件 (验证任务)

**Interfaces:**
- Consumes: Task 0-5 全部产物。Produces: 端到端可用性证明。

- [ ] **Step 1: 推送 dev 分支触发 workflow**

从 sre_demo 推一个 dev 分支(或空提交)到 GitHub:
```bash
git checkout -b dev
git push origin dev
```
在 GitHub Actions 页面确认 workflow 被 self-hosted runner 领取。

- [ ] **Step 2: 观察 workflow 各步骤**

Expected: checkout → kaniko build(成功) → deploy → rollout(成功) → health check 输出 `{"status":"ok",...}` 全绿。

- [ ] **Step 3: 验证集群侧**

Run: `kubectl get deploy,svc,pods -n demo-dev`
Expected: `demo-app` Deployment Ready, Pod Running, image 为 `192.168.3.49:30500/demo-app:dev-<sha>`。

- [ ] **Step 4: 复跑验证幂等**

再次 push 一个提交到 dev, 确认第二次 workflow 也全绿 (镜像 tag 变化触发滚动更新)。

---

## Self-Review（计划对照 spec）

- **spec §4.1 runner 镜像** → Task 0 ✓; **§4.2 deployment** → Task 2/3 ✓; **§4.3 RBAC** → Task 2 ✓; **§4.4 workflow** → Task 5 ✓; **§4.5 deployment.yaml** → Task 4 ✓; **§5.1 自举构建** → Task 2/3 ✓; **§5.2 tag 策略** → Task 4/5 ✓; **§5.3 PAT** → Task 3 ✓; **§5.4 entrypoint** → Task 1 ✓。
- **占位符扫描**: 无 TBD/TODO; Task 3 Step 1 的 PAT 是执行期用户输入, 明确标注。
- **类型一致性**: `/kaniko/executor` (Dockerfile 安装, workflow/kaniko Job 调用) 一致; `192.168.3.49:30500` 全篇一致; `ci/github-pat` Secret key `token` 与 deployment 引用一致; `GITHUB_SHA::7` 在两个步骤中一致。
- **已验证的外部依赖**: actions-runner 2.323.0 (qpmstudio 直连 200); kaniko 镜像在 ghcr.io (gcr.io 已弃用); pkgs.k8s.io v1.36 (集群已在用)。**执行时需确认**: ghcr.io/kaniko-project/executor:v1.24.0 精确 tag (bootstrap Job 拉取时会校验; 若 404 换 v1.23.2 或 latest)。

## Execution Handoff

计划已保存至 `docs/superpowers/plans/2026-08-02-local-github-runner-qpmstudio.md`。两种执行方式:

1. **Subagent-Driven（推荐）** — 每任务派发独立 subagent, 任务间 review, 迭代快
2. **Inline Execution** — 本会话用 executing-plans 批量执行, 带检查点

选哪种?
