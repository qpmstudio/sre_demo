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
export GITHUB_ORG="YOUR_ORG_NAME"
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
