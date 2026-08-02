FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl git jq ca-certificates gnupg apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# kubectl v1.36.3 via pkgs.k8s.io (same source as the cluster)
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL --tls-max 1.2 https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
      | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update && apt-get install -y kubectl=1.36.3-* \
    && rm -rf /var/lib/apt/lists/*

# GitHub Actions runner v2.336.0 (downloaded at build time; github.com reachable)
# v2.336.0 is the current latest release; older 2.323.0 is deprecated server-side
# and cannot receive jobs ("Runner version ... is deprecated"). Keep this pinned
# to a current release because --disableupdate (see entrypoint.sh) prevents the
# self-update from fixing it in place.
# --tls-max 1.2: local DNS proxy rejects TLS 1.3 to github.com (error:0A000126)
RUN curl -fsSL --tls-max 1.2 -o /tmp/actions-runner.tar.gz \
      https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-linux-x64-2.336.0.tar.gz \
    && mkdir -p /home/runner \
    && tar xzf /tmp/actions-runner.tar.gz -C /home/runner \
    && /home/runner/bin/installdependencies.sh \
    && rm /tmp/actions-runner.tar.gz

# kaniko executor (no-Docker image build inside runner pods)
# Installed at /usr/local/bin/kaniko-executor, NOT /kaniko/executor: kaniko
# re-executes its own binary at /kaniko/executor inside the chrooted build
# rootfs, so writing that path in the output image triggers ETXTBSY
# ("text file busy") when this image is itself built with kaniko.
COPY --from=gcr.io/kaniko-project/executor:v1.24.0 /kaniko/executor /usr/local/bin/kaniko-executor

COPY entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh /usr/local/bin/kaniko-executor

WORKDIR /home/runner
ENTRYPOINT ["/home/runner/entrypoint.sh"]
