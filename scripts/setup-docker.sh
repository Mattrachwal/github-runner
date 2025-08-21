#!/bin/bash
set -euo pipefail

CONFIG_FILE="${SCRIPT_DIR}/config.yml"

log "Installing Docker..."

# Remove old Docker installations
apt-get remove -y docker docker-engine docker.io containerd runc || true

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
rm get-docker.sh

# Install Docker Compose
log "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Configure Docker daemon for security
log "Configuring Docker daemon..."
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "seccomp-profile": "/etc/docker/seccomp.json",
  "icc": false
}
EOF

# Create custom seccomp profile
log "Creating Docker seccomp profile..."
curl -o /etc/docker/seccomp.json https://raw.githubusercontent.com/docker/docker/master/profiles/seccomp/default.json

# Create Docker network
DOCKER_NETWORK=$(yq eval '.system.docker_network' "$CONFIG_FILE")
docker network create --driver bridge "$DOCKER_NETWORK" || true

# Setup Docker registry credentials if provided
REGISTRY=$(yq eval '.docker.registry' "$CONFIG_FILE")
if [[ -n "$REGISTRY" ]] && [[ "$REGISTRY" != "null" ]]; then
    REGISTRY_USER=$(yq eval '.docker.registry_user' "$CONFIG_FILE")
    REGISTRY_PASS=$(yq eval '.docker.registry_password' "$CONFIG_FILE")
    
    log "Configuring Docker registry..."
    echo "$REGISTRY_PASS" | docker login "$REGISTRY" -u "$REGISTRY_USER" --password-stdin
fi

# Restart Docker
systemctl restart docker
systemctl enable docker