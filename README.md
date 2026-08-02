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

- Docker Desktop（已启用 Kubernetes，开启 "Expose daemon on tcp://localhost:2375 without TLS"）
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
export DOCKER_HOST="tcp://host.docker.internal:2375"
./runner/start-runner.sh YOUR_USER/YOUR_REPO
```

Runner 启动后，在 GitHub 仓库 Settings → Actions → Runners 中可以看到 `local-*` 上线。

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
docker stop gh-runner-YOUR_USER-YOUR_REPO

# 清理 K8s 资源
kubectl delete namespace demo-dev
```

## 架构

```
Git push → GitHub Actions → Self-hosted Runner
                                ├── DOCKER_HOST=tcp://host.docker.internal:2375 → Docker Desktop
                                └── kubeconfig (base64 via env) → Docker Desktop K8s
```

## 环境变量

| 变量 | 必需 | 说明 |
|---|---|---|
| `GITHUB_PAT` | 是 | GitHub Personal Access Token（`repo` 权限） |
| `DOCKER_HOST` | 是 | Docker daemon 地址，如 `tcp://host.docker.internal:2375` |
| `KUBECONFIG` | 否 | 默认 `~/.kube/config`，自动 base64 编码传入容器 |

## qpmstudio 集群部署（K8s pod 模式）

本仓库也已适配到 qpmstudio kubeadm 集群：runner 以 K8s pod 运行（`ci` 命名空间），
用 kaniko（隔离 Job）构建镜像推本地 registry，workflow 在 push `dev` 时自动构建+部署。

### 关键文件
- `k8s/` — ci 命名空间、SA/RBAC（`ci-runner`）、runner Deployment、kaniko bootstrap
- `ci/kaniko-build-job.yaml` — workflow 使用的 kaniko 构建 Job（隔离在 runner pod 之外）
- `runner/Dockerfile` / `entrypoint.sh` — runner 镜像（kubectl + kaniko + actions-runner）

### 已知运维事项
- runner 以 root 运行（供 kaniko），SA `ci-runner` 绑 scoped ClusterRole
- `--disableupdate` 已禁用 runner 自动更新（曾导致 job 中断）
- 镜像用 `dev-<sha>` 唯一 tag；containerd 信任 `192.168.3.49:30500`（HTTP）
- 若出现 ghost runner（旧 pod 残留的 offline/busy runner），到 GitHub 仓库
  Settings → Actions → Runners 手动删除，或等其随 job 超时自动清除
