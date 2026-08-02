# SRE CI/CD — 本地 GitHub Runner 适配到 qpmstudio 集群

- 日期: 2026-08-02
- 目标环境: qpmstudio 单节点 kubeadm 集群 (Ubuntu 24.04, K8s v1.36.3, containerd 2.2.1)
- 交付方式: 在 sre_demo 仓库内改造 runner/workflow/manifest, 全部版本化

## 1. 背景与目标

将 `sre_demo` 项目原有的 "Docker Desktop + DooD" 本地 CI/CD 方案, 迁移适配到新搭建的 qpmstudio kubeadm 集群。

**目标**: 构建一个以 K8s pod 方式运行的 GitHub Actions self-hosted runner, 监听 `qpmstudio/sre_demo` 仓库, 在 `dev` 分支 push 时执行: checkout → 构建镜像 → 推本地 registry → 部署到集群 → 健康检查。

## 2. 现状分析（原 sre_demo 架构与冲突点）

原方案基于 **Docker Desktop**:
- Runner 为 Docker 容器, 通过 **DooD** (挂载 `/var/run/docker.sock`) 使用宿主机 Docker daemon 构建
- 镜像构建到本地 daemon, `imagePullPolicy: IfNotPresent` 免推送
- 依赖 `DOCKER_HOST=tcp://host.docker.internal:2375` 与 Docker Desktop 专属 DNS 处理

**与新环境冲突**: qpmstudio **没有 Docker daemon** (只装 containerd), runner 无法用 Docker 容器或 DooD。镜像只能走 **Kaniko** (无 daemon) 构建并推送到**本地 registry:2** 供集群拉取。

## 3. 目标架构

```
git push sre_demo → dev
   │ GitHub Actions 触发 (runs-on: self-hosted)
   ▼
self-hosted runner pod (qpmstudio 集群 · ci 命名空间)
   │ ① actions/checkout 拉取代码
   │ ② kaniko 构建镜像 → 推 192.168.3.49:30500/demo-app:dev-<sha>
   │ ③ kubectl apply → 部署到 demo-dev 命名空间
   │ ④ rollout 等待 + health check
   ▼
demo-app pod 在集群运行
```

## 4. 组件设计

### 4.1 runner 镜像
- 基础: `ubuntu:22.04` (沿用原设计, 与 actions-runner 兼容)
- 预装: `actions-runner` 二进制 (预下载, 避免容器内网络问题) + `kubectl` v1.36.3 + **kaniko executor 二进制** + `git curl jq ca-certificates`
- **不包含** docker CLI / DooD 相关
- 非 root 用户 `runner` 运行 actions-runner

### 4.2 runner Deployment
- 命名空间: `ci` (新建)
- SA: `ci-runner`
- 挂载:
  - `github-pat` Secret → `GITHUB_PAT` 环境变量 (repo 级注册需要)
  - SA token (自动挂载) → kubectl 权限
- 环境变量: `GITHUB_REPO=qpmstudio/sre_demo`、`KUBECONFIG` 指向 SA token 生成的 kubeconfig (集群内 in-cluster config)

### 4.3 RBAC
`ci-runner` SA 绑定 scoped ClusterRole `ci-runner`:
- 资源: `deployments`, `services`, `configmaps`, `namespaces` (+ 隐式需要 `pods` 查看用于 rollout 检查)
- 动词: `get list watch create update patch delete`
- 目的: 能管理 `demo-dev` 命名空间的部署, 不做 cluster-admin

### 4.4 workflow (`.github/workflows/deploy.yml` 改造)
保留 `dev` 分支触发 + `runs-on: self-hosted`, 构建步骤改为 Kaniko:
1. `actions/checkout@v4`
2. `kubectl create namespace demo-dev --dry-run=client -o yaml | kubectl apply -f -`
3. Kaniko 构建 + 推送:
   ```bash
   /kaniko/executor --context=./demo \
     --destination=192.168.3.49:30500/demo-app:dev-${GITHUB_SHA::7} \
     --cache=true
   ```
4. 替换 deployment.yaml 的 image 字段为带 sha 的镜像, `kubectl apply -f -`
5. `kubectl rollout status deployment/demo-app -n demo-dev --timeout=60s`
6. health check (port-forward + curl /health)

### 4.5 demo 部署清单调整
- image: `192.168.3.49:30500/demo-app:dev-<sha>` (唯一 tag 触发滚动更新)
- `imagePullPolicy: Always` (配合唯一 tag, 确保拉到最新)
- 保留 ClusterIP Service 8080

## 5. 关键实现细节

### 5.1 runner 镜像自举构建（无 Docker 环境）
由于集群无 Docker, runner 镜像用**一次性 kaniko Job** 在集群上构建:
- 以 `runner/` 目录 (Dockerfile + entrypoint.sh) 为构建 context
- kaniko Job 从 git 仓库或 ConfigMap 取 context, 输出到 `192.168.3.49:30500/actions-runner:latest`
- 构建成功后删除 Job, 再部署 runner Deployment

### 5.2 镜像 tag 策略
用 `dev-<git-sha-前7位>` 唯一 tag。workflow 内通过 `sed`/`yq` 替换 deployment 的 image 字段再 apply, 确保 K8s 感知镜像变化并滚动更新。(固定 tag + apply 不会触发 rollout, 是常见坑。)

### 5.3 PAT 存储
- 用户提供 `repo` scope PAT, 存为 `ci/github-pat` Secret, 不写入 git
- runner pod 以环境变量方式注入

### 5.4 entrypoint 简化
复用 sre_demo `runner/entrypoint.sh` 的注册/注销流程 (GitHub API registration/remove token), 但**移除**:
- `_curl` 的 Docker Desktop DNS 代理 TLS 重试 (三层 fallback) → 简化为普通 curl (或走集群网络)
- `DOCKER_HOST` / `host.docker.internal` 检查
- kubeconfig base64 解码逻辑 → 改为集群内 in-cluster 配置 (SA token)

## 6. 验证与风险

### 6.1 验证清单
- kaniko Job 成功构建并推送 runner 镜像到 registry
- runner pod 上线, GitHub 仓库 Actions → Runners 显示 `online`
- push `dev` 分支触发 workflow, 全步骤绿
- `kubectl get deploy demo-app -n demo-dev` Running; health check 通过

### 6.2 已知风险
- kaniko 构建需拉基础镜像 (ubuntu) 与 kaniko 镜像 (gcr.io), 走集群 proxy — 已验证 gcr.io/docker.io 可达性
- actions-runner 二进制下载自 github.com, 需 proxy/镜像源 (沿用 sre_demo 的 ghproxy 逻辑)
- PAT 有有效期, 需定期轮换
- 单节点集群, runner 与 workload 共享资源 (16G/8核, 够用)

## 7. 交付物清单

```
sre_demo/
├── runner/
│   ├── Dockerfile          # 改造: 去 docker, 加 kaniko/kubectl
│   ├── entrypoint.sh       # 简化: 去 DooD/Docker Desktop 逻辑, in-cluster kubeconfig
│   └── start-runner.sh     # (可选) 移除或改造为 kubectl 部署脚本
├── demo/
│   └── k8s/deployment.yaml # image → registry 唯一 tag
├── .github/workflows/deploy.yml  # kaniko 构建 + push + apply
└── k8s/ (新增)
    ├── ci-namespace.yaml          # ci 命名空间
    ├── runner-deployment.yaml     # runner pod
    ├── runner-sa.yaml             # ci-runner SA + RBAC
    └── kaniko-bootstrap-job.yaml  # 一次性 runner 镜像构建
```
