# Repository Guidelines

## Project Structure

```
.
├── runner/                 # Self-hosted GitHub Actions runner (Dockerfile, entrypoint, launcher)
├── demo/                   # Go demo application
│   ├── main.go             # HTTP service with /health endpoint
│   ├── Dockerfile          # Multi-stage build
│   └── k8s/                # Kubernetes Deployment + Service manifests
├── .github/workflows/      # CI/CD pipeline definition
└── docs/                   # Design docs, plans, and specs
```

Source code lives in `demo/`. Infrastructure scripts live in `runner/`. K8s manifests live alongside the service they deploy.

## Build, Test, and Development Commands

| Command | Purpose |
|---|---|
| `cd demo && go run main.go` | Run the demo HTTP service locally on :8080 |
| `cd demo && CGO_ENABLED=0 GOOS=linux go build -o /demo-app .` | Build a static Linux binary |
| `docker build -t demo-app:dev-latest ./demo` | Build the demo Docker image |
| `./runner/start-runner.sh` | Build and launch the self-hosted runner container |

There is no dedicated test suite. Verification is done through the CI/CD pipeline: push to the `dev` branch triggers the workflow, which builds the image, deploys to the local K8s cluster, and runs a health check against the service.

## Coding Style & Naming Conventions

- **Go**: standard formatting (`gofmt`). Identifiers use camelCase. Package name matches directory.
- **Shell**: bash with `set -e`. Scripts are named in kebab-case. Start scripts with `#!/bin/bash` and a brief header comment.
- **Docker**: multi-stage builds when applicable. Pin base image tags (e.g., `alpine:3.20`, not `alpine:latest`).
- **Kubernetes**: resources use kebab-case names. Group related Service and Deployment in a single YAML file separated by `---`. Use `imagePullPolicy: IfNotPresent` for local images.
- **YAML**: 2-space indentation.

No linter or formatter configs are committed — keep code readable by following existing patterns in the repo.

## Commit & Pull Request Guidelines

The project follows [Conventional Commits](https://www.conventionalcommits.org/) with Chinese descriptions:

```
feat: 简短描述
docs: 文档变更说明
```

- Keep commits focused — one logical change per commit.
- PRs should include a clear description of what changed and a test plan (e.g., "pushed to dev and verified the workflow completed").
- For infrastructure changes, include the output of any manual verification steps.
