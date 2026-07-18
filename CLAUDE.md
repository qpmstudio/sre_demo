# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an SRE demo that implements a local CI/CD loop using GitHub Actions self-hosted runners on Docker Desktop. The workflow: `git push dev → GitHub Actions triggers runner → docker build → kubectl apply → health check`.

## Architecture (cross-file understanding)

**DooD (Docker-outside-of-Docker) pattern**: The runner container (`runner/`) does NOT run Docker-in-Docker. Instead, `start-runner.sh` mounts the host's `/var/run/docker.sock` and `~/.kube/config` into the container. This means `docker build` inside the runner produces images directly on the host's Docker daemon, and `kubectl` commands operate on the host's Kubernetes cluster. The K8s Deployment uses `imagePullPolicy: IfNotPresent` so the locally-built image is used without a registry.

**Runner registration lifecycle**: `entrypoint.sh` registers the runner with GitHub on startup (via `POST .../registration-token`), runs `./run.sh` in the foreground, and deregisters on exit via a `trap cleanup EXIT` handler (using `POST .../remove-token`). The runner binary (`actions-runner.tar.gz`) is pre-downloaded by `start-runner.sh` and copied into the image at build time — this avoids downloading from GitHub inside the container, which is useful behind firewalls/GFW.

**Image flow**: `start-runner.sh` downloads the GitHub Actions runner binary → `runner/Dockerfile` copies it into the image → container starts and registers with GitHub. Separately, the CI workflow (`deploy.yml`) runs `docker build -t demo-app:dev-latest ./demo` inside the runner container, which hits the host Docker daemon via the mounted socket.

**Workflow trigger scope**: The deploy workflow only triggers on pushes to the `dev` branch. It runs on `self-hosted` runners, meaning it will only execute when the local runner container is online and registered.

## Key Commands

See `AGENTS.md` for the full command reference. The most common:

- `cd demo && go run main.go` — run demo app locally (no Docker/K8s needed)
- `./runner/start-runner.sh` — build and launch the runner container
- `docker logs -f local-github-runner` — tail runner logs to debug registration issues
- `docker stop local-github-runner` — stop runner (triggers deregistration via trap)

## Environment Variables

| Variable | Used By | Purpose |
|---|---|---|
| `GITHUB_PAT` | `entrypoint.sh`, `start-runner.sh` | GitHub personal access token (needs `repo` scope for runner registration) |
| `GITHUB_REPO` | `entrypoint.sh`, `start-runner.sh` | Repository in `owner/repo` format |
| `KUBECONFIG` | `entrypoint.sh` | Path to kubeconfig inside container (mounted from host) |

## Important Implementation Details

- The runner entrypoint has a sophisticated `_curl` function with 3-tier retry: TLS 1.2, direct TLS 1.3, and `--resolve` with hardcoded GitHub API IPs. This exists because Docker Desktop's DNS proxy at `198.18.0.73` rejects TLS 1.3 in certain network environments.
- `entrypoint.sh` dynamically fixes docker.sock GID mismatch: the host's docker group GID may differ from the container's, so the script creates a matching group at startup and adds the `runner` user to it.
- The demo app uses only Go standard library (`net/http`, `encoding/json`) — no third-party dependencies.
- The Go module is named `sre-demo` (`demo/go.mod`).

## Conventions

See `AGENTS.md` for coding style, naming conventions, and commit message format (Conventional Commits with Chinese descriptions). Key points:
- Shell scripts: `#!/bin/bash` with `set -e`
- Docker: multi-stage builds, pinned base image tags
- K8s: kebab-case names, Deployment + Service in single YAML separated by `---`
