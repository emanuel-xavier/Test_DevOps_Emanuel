# Jenkins inbound (JNLP) agent + Docker CLI.
# The stock jenkins/inbound-agent has no docker binary; this adds the client so
# pipeline steps can run `docker build`. The daemon is the HOST's, reached via
# the bind-mounted /var/run/docker.sock (see docker-compose.yaml).
FROM jenkins/inbound-agent:latest-jdk21

USER root

# Docker CLI + Buildx plugin from Docker's official apt repo (client only).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg jq \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
         | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" \
         > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# Swarm stack deploy does NOT support `group_add`, so bake socket access in:
# create a group matching the host docker GID and add the jenkins user.
# Pass the real host GID at build time so this never drifts:
#   docker build --build-arg DOCKER_GID=$(stat -c '%g' /var/run/docker.sock) ...
# 986 is only a fallback default.
ARG DOCKER_GID=986
RUN groupadd -g ${DOCKER_GID} docker || groupmod -g ${DOCKER_GID} $(getent group ${DOCKER_GID} | cut -d: -f1) \
    && usermod -aG docker jenkins

USER jenkins
