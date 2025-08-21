#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
fi

# Check for config file
CONFIG_FILE="${SCRIPT_DIR}/config.yml"
if [[ ! -f "$CONFIG_FILE" ]]; then
    error "config.yml not found! Please copy config.yml.example to config.yml and configure it."
fi

# Install required packages
log "Installing required packages..."
apt-get update
apt-get install -y \
    curl \
    wget \
    git \
    jq \
    python3-pip \
    python3-yaml \
    sudo \
    ca-certificates \
    gnupg \
    lsb-release \
    iptables \
    ufw \
    fail2ban

# Install yq for YAML parsing
log "Installing yq for YAML parsing..."
wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
chmod +x /usr/local/bin/yq

# Parse configuration
log "Reading configuration..."
export GITHUB_ORG=$(yq eval '.github.org' "$CONFIG_FILE")
export GITHUB_TOKEN=$(yq eval '.github.token' "$CONFIG_FILE")
export RUNNER_USER=$(yq eval '.system.runner_user' "$CONFIG_FILE")
export RUNNER_COUNT=$(yq eval '.system.runner_count' "$CONFIG_FILE")
export RUNNER_PREFIX=$(yq eval '.system.runner_prefix' "$CONFIG_FILE")

# Validate configuration
if [[ -z "$GITHUB_TOKEN" ]] || [[ "$GITHUB_TOKEN" == "null" ]]; then
    error "GitHub token not configured in config.yml"
fi

# Execute setup scripts
log "Setting up system..."
bash "${SCRIPT_DIR}/scripts/setup-system.sh"

log "Setting up Docker..."
bash "${SCRIPT_DIR}/scripts/setup-docker.sh"

log "Setting up users and permissions..."
bash "${SCRIPT_DIR}/scripts/setup-users.sh"

log "Setting up GitHub runners..."
bash "${SCRIPT_DIR}/scripts/setup-runners.sh"

log "Installation complete!"
log "GitHub Runners are now running as Docker containers."
log "Use 'docker ps' to see running runners"
log "Use 'systemctl status github-runner-manager' to check the service status"