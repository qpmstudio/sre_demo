FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl git jq ca-certificates gnupg apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# kubectl v1.36.3 via pkgs.k8s.io (same source as the cluster)
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
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
