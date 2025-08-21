#!/bin/bash
set -euo pipefail

CONFIG_FILE="${SCRIPT_DIR}/config.yml"
RUNNER_USER=$(yq eval '.system.runner_user' "$CONFIG_FILE")
RUNNER_HOME="/home/$RUNNER_USER"

log "Building runner Docker image..."

# Create Dockerfile for runner
cat > "${SCRIPT_DIR}/docker/Dockerfile.runner" <<'DOCKERFILE'
FROM ubuntu:22.04

ARG RUNNER_VERSION="2.319.1"
ARG DOCKER_VERSION="24.0.7"

ENV DEBIAN_FRONTEND=noninteractive
ENV RUNNER_ALLOW_RUNASROOT=1

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    jq \
    sudo \
    ca-certificates \
    gnupg \
    lsb-release \
    libicu70 \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI for Docker-in-Docker
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update \
    && apt-get install -y docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Create runner user
RUN useradd -m -s /bin/bash runner && \
    usermod -aG sudo runner && \
    echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install GitHub Runner
WORKDIR /home/runner
RUN curl -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && tar xzf ./actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && rm actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && chown -R runner:runner /home/runner

# Install additional tools
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    nodejs \
    npm \
    zip \
    unzip \
    && rm -rf /var/lib/apt/lists/*

USER runner

# Entrypoint script
COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
DOCKERFILE

# Create entrypoint script
cat > "${SCRIPT_DIR}/docker/entrypoint.sh" <<'ENTRYPOINT'
#!/bin/bash
set -e

# Configure runner
./config.sh \
    --url "https://github.com/${GITHUB_ORG}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --work "_work" \
    --ephemeral \
    --disableupdate \
    --unattended \
    --replace

# Cleanup function
cleanup() {
    echo "Removing runner..."
    ./config.sh remove --token "${RUNNER_TOKEN}"
}

# Trap exit signal
trap cleanup EXIT

# Run the runner
./run.sh
ENTRYPOINT

# Create docker-compose.yml
cat > "${SCRIPT_DIR}/docker/docker-compose.yml" <<COMPOSE
version: '3.8'

services:
COMPOSE

# Generate runner services
RUNNER_COUNT=$(yq eval '.system.runner_count' "$CONFIG_FILE")
RUNNER_PREFIX=$(yq eval '.system.runner_prefix' "$CONFIG_FILE")
GITHUB_ORG=$(yq eval '.github.org' "$CONFIG_FILE")
GITHUB_TOKEN=$(yq eval '.github.token' "$CONFIG_FILE")
RUNNER_LABELS=$(yq eval '.github.labels' "$CONFIG_FILE")
DOCKER_NETWORK=$(yq eval '.system.docker_network' "$CONFIG_FILE")
MEMORY_LIMIT=$(yq eval '.docker.memory_limit' "$CONFIG_FILE")
CPU_LIMIT=$(yq eval '.docker.cpu_limit' "$CONFIG_FILE")

for i in $(seq 1 "$RUNNER_COUNT"); do
    cat >> "${SCRIPT_DIR}/docker/docker-compose.yml" <<COMPOSE
  runner-${i}:
    build:
      context: .
      dockerfile: Dockerfile.runner
    container_name: ${RUNNER_PREFIX}-${i}
    restart: unless-stopped
    environment:
      - GITHUB_ORG=${GITHUB_ORG}
      - RUNNER_TOKEN=\${RUNNER_TOKEN_${i}}
      - RUNNER_NAME=${RUNNER_PREFIX}-${i}
      - RUNNER_LABELS=${RUNNER_LABELS}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - runner-${i}-work:/home/runner/_work
    networks:
      - ${DOCKER_NETWORK}
    deploy:
      resources:
        limits:
          memory: ${MEMORY_LIMIT}
          cpus: '${CPU_LIMIT}'
    security_opt:
      - no-new-privileges:true
      - seccomp:unconfined
      - apparmor:unconfined
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE

COMPOSE
done

# Add volumes and networks section
cat >> "${SCRIPT_DIR}/docker/docker-compose.yml" <<COMPOSE

volumes:
COMPOSE

for i in $(seq 1 "$RUNNER_COUNT"); do
    echo "  runner-${i}-work:" >> "${SCRIPT_DIR}/docker/docker-compose.yml"
done

cat >> "${SCRIPT_DIR}/docker/docker-compose.yml" <<COMPOSE

networks:
  ${DOCKER_NETWORK}:
    external: true
COMPOSE

# Copy files to runner home
cp -r "${SCRIPT_DIR}/docker" "$RUNNER_HOME/"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME/docker"

# Create systemd service
log "Creating systemd service..."
cat > /etc/systemd/system/github-runner-manager.service <<SYSTEMD
[Unit]
Description=GitHub Runner Manager
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=${RUNNER_USER}
WorkingDirectory=${RUNNER_HOME}/docker
ExecStartPre=/bin/bash -c 'for i in \$(seq 1 ${RUNNER_COUNT}); do export RUNNER_TOKEN_\${i}=\$(curl -s -X POST -H "Authorization: token ${GITHUB_TOKEN}" https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/registration-token | jq -r .token); done && env | grep RUNNER_TOKEN > .env'
ExecStart=/usr/local/bin/docker-compose up --build
ExecStop=/usr/local/bin/docker-compose down
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD

# Reload systemd and start service
systemctl daemon-reload
systemctl enable github-runner-manager
systemctl start github-runner-manager

log "GitHub runners setup complete!"