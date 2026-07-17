FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base packages + Docker CLI (from Ubuntu repo, avoids download.docker.com)
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    git \
    apt-transport-https \
    ca-certificates \
    gnupg \
    docker.io \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl via Aliyun Kubernetes mirror (avoids dl.k8s.io)
RUN curl -fsSL https://mirrors.aliyun.com/kubernetes/apt/doc/apt-key.gpg | gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main" | tee /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update && apt-get install -y kubectl \
    && rm -rf /var/lib/apt/lists/*

# Create runner user; add to docker + nogroup for DooD socket access
RUN useradd -m -s /bin/bash runner \
    && usermod -a -G docker,nogroup runner

# GitHub Actions runner (pre-downloaded binary, avoids github.com in China)
ARG RUNNER_ARCHIVE=actions-runner.tar.gz
COPY ${RUNNER_ARCHIVE} /tmp/runner.tar.gz
RUN cd /home/runner \
    && tar xzf /tmp/runner.tar.gz \
    && rm /tmp/runner.tar.gz \
    && ./bin/installdependencies.sh \
    && chown -R runner:runner /home/runner

COPY entrypoint.sh /home/runner/entrypoint.sh
RUN chmod 755 /home/runner/entrypoint.sh

WORKDIR /home/runner
ENTRYPOINT ["/home/runner/entrypoint.sh"]
