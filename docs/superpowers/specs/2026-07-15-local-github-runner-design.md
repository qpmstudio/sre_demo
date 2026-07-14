## 概述

在本地 Docker Desktop 环境下搭建 GitHub Actions self-hosted runner，实现代码 push → 自动构建镜像 → 自动部署到本地 K8s 的开发闭环。核心采用 Docker-outside-of-Docker (DooD) 模式，Runner 容器通过挂载宿主机的 `docker.sock` 和 `~/.kube/config` 直接操控宿主机 Docker 和 K8s。

## 项目结构

```
.
├── runner/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── start-runner.sh
├── demo/
│   ├── main.go
│   ├── Dockerfile
│   ├── go.mod
│   └── k8s/
│       └── deployment.yaml
├── .github/
│   └── workflows/
│       └── deploy.yml
└── README.md
```

- `runner/` — Runner 镜像构建和启动逻辑
- `demo/` — Go demo 应用源码和 K8s 配置
- `.github/workflows/deploy.yml` — GitHub Actions workflow，触发构建部署

## Runner 镜像

- **基础镜像**：`ubuntu:22.04`
- **预装工具**：`docker-ce-cli`、`kubectl`、`jq`、`curl`、`git`、GitHub Actions Runner 二进制
- **Runner 用户**：非 root 用户 `runner`

### Entrypoint 逻辑

1. 检查环境变量：`GITHUB_PAT`、`GITHUB_REPO`（格式 `owner/repo`）
2. 调 GitHub API `POST /repos/{owner}/{repo}/actions/runners/registration-token` 获取注册 token
3. 执行 `./config.sh --url https://github.com/{owner}/{repo} --token {token}` 注册 runner
4. `trap EXIT` — 容器退出时调 `POST /repos/{owner}/{repo}/actions/runners/remove-token` 注销 runner
5. 启动 `./run.sh`

### 启动脚本 (start-runner.sh)

- 前置检查：`GITHUB_PAT` 环境变量、`/var/run/docker.sock` 存在性、`~/.kube/config` 存在性
- `docker run` 参数：
  - `-v /var/run/docker.sock:/var/run/docker.sock`
  - `-v $HOME/.kube/config:/home/runner/.kube/config`
  - `-e GITHUB_PAT`、`-e GITHUB_REPO`

## Demo 应用

- **语言**：Go 1.22+，仅使用标准库 `net/http`
- **接口**：`GET /health` → `{"status":"ok","started_at":"2026-07-15T10:30:00+08:00"}` HTTP 200
- **镜像构建**：多阶段 Dockerfile，最终基于 `alpine:3.20`，镜像约 8MB

## K8s 部署

- **Namespace**：`demo-dev`（workflow 中自动创建）
- **Service**：ClusterIP，端口 8080
- **Deployment**：单副本，`imagePullPolicy: IfNotPresent`（免推送到远端仓库）
- **镜像**：`demo-app:dev-latest`

## Workflow

`.github/workflows/deploy.yml`：

- **触发**：`push` → `branches: [dev]`
- **运行环境**：`self-hosted`
- **步骤**：
  1. Checkout（`actions/checkout@v4`）
  2. `docker build -t demo-app:dev-latest ./demo`
  3. `kubectl create namespace demo-dev --dry-run=client -o yaml | kubectl apply -f -`
  4. `kubectl apply -f demo/k8s/deployment.yaml -n demo-dev`
  5. `kubectl rollout status deployment/demo-app -n demo-dev --timeout=60s`
  6. `kubectl port-forward` + `curl localhost:8080/health` 验证

## 完整数据流

```
Git push to dev
    ↓
GitHub 触发 workflow
    ↓
本地 Runner 容器拉取 job
    ↓
Step 1: checkout 代码到容器内
    ↓
Step 2: docker build → 镜像落到宿主机 Docker Desktop
    ↓
Step 3: kubectl apply → 操作本地 K8s
    ↓
Step 4: rollout status → 等待 pod 就绪
    ↓
Step 5: port-forward + curl /health → 验证
    ↓
Job 完成
```

## 测试策略

- **Runner 镜像**：构建后通过 `docker run --rm <image> docker --version && kubectl version --client` 验证 CLI 工具可用
- **Demo 应用**：本地 `go run main.go` + `curl localhost:8080/health` 验证接口
- **Workflow**：仅端到端手动验证（依赖实际 GitHub 仓库和 Runner 环境）
