#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
fi

# Check for config file
CONFIG_FILE="${SCRIPT_DIR}/config.yml"
if [[ ! -f "$CONFIG_FILE" ]]; then
    error "config.yml not found! Please copy config.example.yml to config.yml and configure it."
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
    fail2ban \
    htop \
    rsync

# Install yq for YAML parsing
log "Installing yq for YAML parsing..."
if ! command -v yq &> /dev/null; then
    wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    chmod +x /usr/local/bin/yq
fi

# Validate configuration
log "Validating configuration..."
export GITHUB_ORG=$(yq eval '.github.org' "$CONFIG_FILE")
export GITHUB_TOKEN=$(yq eval '.github.token' "$CONFIG_FILE")
export RUNNER_USER=$(yq eval '.system.runner_user' "$CONFIG_FILE")

if [[ -z "$GITHUB_TOKEN" ]] || [[ "$GITHUB_TOKEN" == "null" ]] || [[ "$GITHUB_TOKEN" == "ghp_your_token_here" ]]; then
    error "GitHub token not configured in config.yml"
fi

if [[ -z "$GITHUB_ORG" ]] || [[ "$GITHUB_ORG" == "null" ]] || [[ "$GITHUB_ORG" == "your-org-name" ]]; then
    error "GitHub organization not configured in config.yml"
fi

# Validate runner configurations
RUNNER_COUNT=$(yq eval '.runners | length' "$CONFIG_FILE")
if [[ "$RUNNER_COUNT" -eq 0 ]]; then
    error "No runners configured in config.yml"
fi

info "Found $RUNNER_COUNT runner configuration(s)"
for ((i=0; i<RUNNER_COUNT; i++)); do
    RUNNER_NAME=$(yq eval ".runners[$i].name" "$CONFIG_FILE")
    RUNNER_INSTANCES=$(yq eval ".runners[$i].instances" "$CONFIG_FILE")
    info "  - $RUNNER_NAME: $RUNNER_INSTANCES instances"
done

# Execute setup scripts
log "Setting up system security..."
bash "${SCRIPT_DIR}/scripts/setup-system.sh"

log "Setting up Docker..."
bash "${SCRIPT_DIR}/scripts/setup-docker.sh"

log "Setting up users and permissions..."
bash "${SCRIPT_DIR}/scripts/setup-users.sh"

log "Setting up GitHub runners..."
bash "${SCRIPT_DIR}/scripts/setup-runners.sh"

log "Setting up monitoring and management..."
bash "${SCRIPT_DIR}/scripts/setup-monitoring.sh"

log ""
log "🎉 Installation complete!"
log ""
log "📊 Runner Summary:"
for ((i=0; i<RUNNER_COUNT; i++)); do
    RUNNER_NAME=$(yq eval ".runners[$i].name" "$CONFIG_FILE")
    RUNNER_INSTANCES=$(yq eval ".runners[$i].instances" "$CONFIG_FILE")
    RUNNER_LABELS=$(yq eval ".runners[$i].labels | join(\", \")" "$CONFIG_FILE")
    MEMORY_LIMIT=$(yq eval ".runners[$i].resources.memory_limit" "$CONFIG_FILE")
    CPU_LIMIT=$(yq eval ".runners[$i].resources.cpu_limit" "$CONFIG_FILE")
    
    echo -e "${BLUE}  📦 $RUNNER_NAME${NC} ($RUNNER_INSTANCES instances)"
    echo -e "     Labels: $RUNNER_LABELS"
    echo -e "     Resources: ${MEMORY_LIMIT} RAM, ${CPU_LIMIT} CPU"
done

log ""
log "🔧 Management Commands:"
log "  Check status:    systemctl status github-runner-manager"
log "  View logs:       journalctl -u github-runner-manager -f"
log "  List containers: docker ps"
log "  Restart service: systemctl restart github-runner-manager"
log "  Stop service:    systemctl stop github-runner-manager"