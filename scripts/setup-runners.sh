#!/bin/bash
set -euo pipefail

CONFIG_FILE="${SCRIPT_DIR}/config.yml"
RUNNER_USER=$(yq eval '.system.runner_user' "$CONFIG_FILE")
RUNNER_HOME="/home/$RUNNER_USER"
GITHUB_ORG=$(yq eval '.github.org' "$CONFIG_FILE")
GITHUB_TOKEN=$(yq eval '.github.token' "$CONFIG_FILE")
DOCKER_NETWORK=$(yq eval '.system.docker_network' "$CONFIG_FILE")

log "Building enhanced runner Docker image..."

# Create enhanced Dockerfile for runner
cat > "${SCRIPT_DIR}/docker/Dockerfile.runner" <<'DOCKERFILE'
FROM ubuntu:22.04

ARG RUNNER_VERSION="2.319.1"
ARG TARGETARCH=amd64

ENV DEBIAN_FRONTEND=noninteractive
ENV RUNNER_ALLOW_RUNASROOT=1

# Install base dependencies
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
    software-properties-common \
    apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI for Docker-in-Docker
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update \
    && apt-get install -y docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (default version)
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash - \
    && apt-get install -y nodejs

# Install Python and pip
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install common development tools
RUN apt-get update && apt-get install -y \
    zip \
    unzip \
    tar \
    gzip \
    rsync \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Create runner user
RUN useradd -m -s /bin/bash runner && \
    usermod -aG sudo runner && \
    echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Install GitHub Runner
WORKDIR /home/runner
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then \
        ARCH="x64"; \
    elif [ "$ARCH" = "arm64" ]; then \
        ARCH="arm64"; \
    elif [ "$ARCH" = "armhf" ]; then \
        ARCH="arm"; \
    fi && \
    curl -o actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz -L \
        https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz \
    && tar xzf ./actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz \
    && rm actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz \
    && chown -R runner:runner /home/runner

# Install additional dependencies
RUN ./bin/installdependencies.sh

USER runner

# Create entrypoint script
COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD pgrep -f "Runner.Worker" || exit 1

ENTRYPOINT ["/home/runner/entrypoint.sh"]
DOCKERFILE

# Create enhanced entrypoint script
cat > "${SCRIPT_DIR}/docker/entrypoint.sh" <<'ENTRYPOINT'
#!/bin/bash
set -e

# Wait for Docker socket to be available
while ! docker version >/dev/null 2>&1; do
    echo "Waiting for Docker socket..."
    sleep 2
done

echo "🚀 Starting GitHub Actions Runner: ${RUNNER_NAME}"
echo "   Organization: ${GITHUB_ORG}"
echo "   Labels: ${RUNNER_LABELS}"
echo "   Scope: ${SCOPE_URL}"

# Function to get registration token
get_registration_token() {
    local scope_type="$1"
    local scope_url="$2"
    local api_url=""
    
    case "$scope_type" in
        "org")
            api_url="https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/registration-token"
            ;;
        "repo")
            local repo_path=$(echo "$scope_url" | sed 's|https://github.com/||')
            api_url="https://api.github.com/repos/${repo_path}/actions/runners/registration-token"
            ;;
        "enterprise")
            api_url="https://api.github.com/enterprises/${GITHUB_ORG}/actions/runners/registration-token"
            ;;
        *)
            echo "❌ Unknown scope type: $scope_type"
            exit 1
            ;;
    esac
    
    curl -s -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "$api_url" | jq -r .token
}

# Get registration token
REGISTRATION_TOKEN=$(get_registration_token "$SCOPE_TYPE" "$SCOPE_URL")
if [[ -z "$REGISTRATION_TOKEN" ]] || [[ "$REGISTRATION_TOKEN" == "null" ]]; then
    echo "❌ Failed to get registration token"
    exit 1
fi

# Configure runner
echo "🔧 Configuring runner..."
RUNNER_ARGS=(
    --url "$SCOPE_URL"
    --token "$REGISTRATION_TOKEN"
    --name "$RUNNER_NAME"
    --labels "$RUNNER_LABELS"
    --work "_work"
    --disableupdate
    --unattended
    --replace
)

# Add ephemeral flag if configured
if [[ "$EPHEMERAL" == "true" ]]; then
    RUNNER_ARGS+=(--ephemeral)
    echo "   Mode: Ephemeral"
else
    echo "   Mode: Persistent"
fi

./config.sh "${RUNNER_ARGS[@]}"

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up runner..."
    if [[ "$EPHEMERAL" == "false" ]]; then
        ./config.sh remove --token "$REGISTRATION_TOKEN" || true
    fi
    exit 0
}

# Setup signal handlers
trap cleanup SIGTERM SIGINT

# Setup timeout if configured
if [[ -n "$TIMEOUT_MINUTES" ]] && [[ "$TIMEOUT_MINUTES" -gt 0 ]]; then
    echo "⏰ Runner will timeout after ${TIMEOUT_MINUTES} minutes"
    (
        sleep $((TIMEOUT_MINUTES * 60))
        echo "⏰ Runner timeout reached, shutting down..."
        kill -TERM $$
    ) &
    TIMEOUT_PID=$!
fi

echo "✅ Runner configured successfully"
echo "🏃 Starting runner..."

# Run the runner
./run.sh &
RUNNER_PID=$!

# Wait for runner to finish
wait $RUNNER_PID

# Kill timeout process if it exists
if [[ -n "${TIMEOUT_PID:-}" ]]; then
    kill $TIMEOUT_PID 2>/dev/null || true
fi

cleanup
ENTRYPOINT

# Make entrypoint executable
chmod +x "${SCRIPT_DIR}/docker/entrypoint.sh"

# Create docker-compose.yml header
cat > "${SCRIPT_DIR}/docker/docker-compose.yml" <<COMPOSE_HEADER
version: '3.8'

services:
COMPOSE_HEADER

# Generate runner services from configuration
RUNNER_COUNT=$(yq eval '.runners | length' "$CONFIG_FILE")
TOTAL_INSTANCES=0

for ((i=0; i<RUNNER_COUNT; i++)); do
    RUNNER_TYPE=$(yq eval ".runners[$i].name" "$CONFIG_FILE")
    INSTANCES=$(yq eval ".runners[$i].instances" "$CONFIG_FILE")
    SCOPE_TYPE=$(yq eval ".runners[$i].scope_type" "$CONFIG_FILE")
    SCOPE_URL=$(yq eval ".runners[$i].scope_url" "$CONFIG_FILE")
    LABELS=$(yq eval ".runners[$i].labels | join(\",\")" "$CONFIG_FILE")
    MEMORY_LIMIT=$(yq eval ".runners[$i].resources.memory_limit" "$CONFIG_FILE")
    CPU_LIMIT=$(yq eval ".runners[$i].resources.cpu_limit" "$CONFIG_FILE")
    EPHEMERAL=$(yq eval ".runners[$i].ephemeral // true" "$CONFIG_FILE")
    TIMEOUT_MINUTES=$(yq eval ".runners[$i].timeout_minutes // 60" "$CONFIG_FILE")
    WORK_DIR=$(yq eval ".runners[$i].work_dir" "$CONFIG_FILE")
    
    # Create work directory
    sudo -u "$RUNNER_USER" mkdir -p "$WORK_DIR"
    
    log "Configuring $INSTANCES instances of runner type: $RUNNER_TYPE"
    
    for ((j=1; j<=INSTANCES; j++)); do
        RUNNER_NAME="${RUNNER_TYPE}-${j}"
        TOTAL_INSTANCES=$((TOTAL_INSTANCES + 1))
        
        cat >> "${SCRIPT_DIR}/docker/docker-compose.yml" <<COMPOSE_SERVICE
  ${RUNNER_TYPE}-${j}:
    build:
      context: .
      dockerfile: Dockerfile.runner
    container_name: ${RUNNER_NAME}
    hostname: ${RUNNER_NAME}
    restart: unless-stopped
    environment:
      - GITHUB_ORG=${GITHUB_ORG}
      - GITHUB_TOKEN=${GITHUB_TOKEN}
      - RUNNER_NAME=${RUNNER_NAME}
      - RUNNER_LABELS=${LABELS}
      - SCOPE_TYPE=${SCOPE_TYPE}
      - SCOPE_URL=${SCOPE_URL}
      - EPHEMERAL=${EPHEMERAL}
      - TIMEOUT_MINUTES=${TIMEOUT_MINUTES}
COMPOSE_SERVICE

        # Add custom environment variables if defined
        ENV_COUNT=$(yq eval ".runners[$i].environment | length" "$CONFIG_FILE")
        if [[ "$ENV_COUNT" -gt 0 ]]; then
            ENV_KEYS=$(yq eval ".runners[$i].environment | keys | .[]" "$CONFIG_FILE")
            while IFS= read -r key; do
                ENV_VALUE=$(yq eval ".runners[$i].environment.${key}" "$CONFIG_FILE")
                echo "      - ${key}=${ENV_VALUE}" >> "${SCRIPT_DIR}/docker/docker-compose.yml"
            done <<< "$ENV_KEYS"
        fi

        cat >> "${SCRIPT_DIR}/docker/docker-compose.yml" <<COMPOSE_SERVICE_END
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${WORK_DIR}:/home/runner/_work
      - runner-${RUNNER_TYPE}-${j}-tmp:/tmp
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
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
      - DAC_OVERRIDE
      - FOWNER
      - NET_RAW
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

COMPOSE_SERVICE_END
    done
done

# Add volumes and networks section
cat >> "${SCRIPT_DIR}/docker/docker-compose.yml" <<COMPOSE_FOOTER

volumes:
COMPOSE_FOOTER

# Add volume definitions
for ((i=0; i<RUNNER_COUNT; i++)); do
    RUNNER_TYPE=$(yq eval ".runners[$i].name" "$CONFIG_FILE")
    INSTANCES=$(yq eval ".runners[$i].instances" "$CONFIG_FILE")
    
    for ((j=1; j<=INSTANCES; j++)); do
        echo "  runner-${RUNNER_TYPE}-${j}-tmp:" >> "${SCRIPT_DIR}/docker/docker-compose.yml"
    done
done

cat >> "${SCRIPT_DIR}/docker/docker-compose.yml" <<COMPOSE_NETWORKS

networks:
  ${DOCKER_NETWORK}:
    external: true
COMPOSE_NETWORKS

# Copy files to runner home and set permissions
cp -r "${SCRIPT_DIR}/docker" "$RUNNER_HOME/"
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME/docker"

# Create systemd service
log "Creating systemd service for $TOTAL_INSTANCES total runner instances..."
cat > /etc/systemd/system/github-runner-manager.service <<SYSTEMD
[Unit]
Description=GitHub Actions Runner Manager
Documentation=https://github.com/actions/runner
After=network.target docker.service
Requires=docker.service
StartLimitBurst=5
StartLimitInterval=300

[Service]
Type=simple
User=${RUNNER_USER}
Group=${RUNNER_USER}
WorkingDirectory=${RUNNER_HOME}/docker
ExecStartPre=/bin/bash -c 'docker network create ${DOCKER_NETWORK} || true'
ExecStart=/usr/local/bin/docker-compose up --build --remove-orphans
ExecStop=/usr/local/bin/docker-compose down --remove-orphans
ExecReload=/usr/local/bin/docker-compose restart
TimeoutStartSec=300
TimeoutStopSec=120
Restart=always
RestartSec=10
KillMode=mixed
KillSignal=SIGTERM

# Security settings
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${RUNNER_HOME}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD

# Reload systemd and start service
systemctl daemon-reload
systemctl enable github-runner-manager

log "Starting GitHub runner manager service..."
systemctl start github-runner-manager

# Wait a bit for containers to start
sleep 10

# Check service status
if systemctl is-active --quiet github-runner-manager; then
    log "✅ GitHub runner manager service is running"
    
    # Show running containers
    log "Running runner containers:"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(CONTAINER|runner-|${RUNNER_TYPE})" || true
else
    error "❌ GitHub runner manager service failed to start. Check logs with: journalctl -u github-runner-manager -f"
fi

log "GitHub runners setup complete! Total instances: $TOTAL_INSTANCES"