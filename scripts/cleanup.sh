#!/bin/bash
set -euo pipefail

# Enhanced cleanup script for removing runners and configuration

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CONFIG_FILE="/opt/github-runner-setup/config.yml"

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/config.yml"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        warning "Config file not found, proceeding with manual cleanup"
        GITHUB_ORG=""
        GITHUB_TOKEN=""
        RUNNER_USER="github-runner"
    else
        GITHUB_ORG=$(yq eval '.github.org' "$CONFIG_FILE" 2>/dev/null || echo "")
        GITHUB_TOKEN=$(yq eval '.github.token' "$CONFIG_FILE" 2>/dev/null || echo "")
        RUNNER_USER=$(yq eval '.system.runner_user' "$CONFIG_FILE" 2>/dev/null || echo "github-runner")
    fi
else
    GITHUB_ORG=$(yq eval '.github.org' "$CONFIG_FILE")
    GITHUB_TOKEN=$(yq eval '.github.token' "$CONFIG_FILE")
    RUNNER_USER=$(yq eval '.system.runner_user' "$CONFIG_FILE")
fi

# Confirmation prompt
echo -e "${RED}⚠️  WARNING: This will completely remove all GitHub runners and related configuration!${NC}"
echo -e "${YELLOW}This includes:${NC}"
echo "  • Stopping and removing all runner containers"
echo "  • Unregistering runners from GitHub"
echo "  • Removing systemd services"
echo "  • Cleaning up user files and directories"
echo "  • Removing Docker networks and volumes"
echo ""
read -p "Are you sure you want to continue? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

log "Starting comprehensive cleanup..."

# Stop the service first
log "Stopping runner service..."
systemctl stop github-runner-manager 2>/dev/null || true
systemctl disable github-runner-manager 2>/dev/null || true

# Remove runners from GitHub if we have valid credentials
if [[ -n "$GITHUB_TOKEN" ]] && [[ -n "$GITHUB_ORG" ]] && [[ "$GITHUB_TOKEN" != "null" ]] && [[ "$GITHUB_ORG" != "null" ]]; then
    log "Removing runners from GitHub organization: $GITHUB_ORG"
    
    # Get all runners that match our naming patterns
    RUNNERS_JSON=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
        "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners" 2>/dev/null || echo '{"runners":[]}')
    
    if [[ -n "$RUNNERS_JSON" ]]; then
        # Look for runners with common prefixes
        RUNNER_IDS=$(echo "$RUNNERS_JSON" | jq -r '.runners[] | select(.name | test("(ephemeral-runner|mini1-shared|high-performance|repo-special|lightweight)")) | .id' 2>/dev/null || true)
        
        if [[ -n "$RUNNER_IDS" ]]; then
            while read -r runner_id; do
                if [[ -n "$runner_id" ]]; then
                    log "Removing runner ID: $runner_id"
                    curl -s -X DELETE -H "Authorization: token ${GITHUB_TOKEN}" \
                        "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/${runner_id}" 2>/dev/null || true
                fi
            done <<< "$RUNNER_IDS"
        else
            log "No matching runners found in GitHub"
        fi
    fi
else
    warning "GitHub credentials not available, skipping GitHub runner removal"
fi

# Stop and remove all Docker containers
log "Cleaning up Docker containers and images..."
if command -v docker &> /dev/null; then
    # Stop all runner containers
    RUNNER_CONTAINERS=$(docker ps -a --filter "name=runner-" --filter "name=ephemeral-runner" --filter "name=mini1-shared" --filter "name=high-performance" --filter "name=repo-special" --filter "name=lightweight" -q 2>/dev/null || true)
    
    if [[ -n "$RUNNER_CONTAINERS" ]]; then
        docker stop $RUNNER_CONTAINERS 2>/dev/null || true
        docker rm $RUNNER_CONTAINERS 2>/dev/null || true
    fi
    
    # Remove using docker-compose if the file exists
    if [[ -f "/home/${RUNNER_USER}/docker/docker-compose.yml" ]]; then
        log "Removing containers using docker-compose..."
        cd "/home/${RUNNER_USER}/docker" && docker-compose down -v --remove-orphans 2>/dev/null || true
    fi
    
    # Remove Docker networks
    RUNNER_NETWORKS=$(docker network ls --filter "name=runner-network" -q 2>/dev/null || true)
    if [[ -n "$RUNNER_NETWORKS" ]]; then
        docker network rm $RUNNER_NETWORKS 2>/dev/null || true
    fi
    
    # Clean up Docker volumes
    RUNNER_VOLUMES=$(docker volume ls --filter "name=runner-" -q 2>/dev/null || true)
    if [[ -n "$RUNNER_VOLUMES" ]]; then
        docker volume rm $RUNNER_VOLUMES 2>/dev/null || true
    fi
    
    # Remove runner Docker images
    RUNNER_IMAGES=$(docker images --filter "reference=*runner*" -q 2>/dev/null || true)
    if [[ -n "$RUNNER_IMAGES" ]]; then
        docker rmi $RUNNER_IMAGES 2>/dev/null || true
    fi
    
    # General cleanup
    docker system prune -af --volumes 2>/dev/null || true
fi

# Remove systemd service files
log "Removing systemd services..."
rm -f /etc/systemd/system/github-runner-manager.service
rm -rf /etc/systemd/system/github-runner-manager.service.d
systemctl daemon-reload

# Remove management scripts
log "Removing management scripts..."
rm -f /usr/local/bin/github-runner-manager
rm -f /usr/local/bin/runner-health-check
rm -f /usr/local/bin/runner-cleanup
rm -f /usr/local/bin/runner-stats

# Remove cron jobs
log "Removing cron jobs..."
rm -f /etc/cron.d/github-runner-health
rm -f /etc/cron.d/github-runner-cleanup

# Remove logrotate configuration
rm -f /etc/logrotate.d/github-runners

# Remove bash completion
rm -f /etc/bash_completion.d/github-runner-manager

# Remove user files and directories
if [[ -n "$RUNNER_USER" ]] && id "$RUNNER_USER" &>/dev/null; then
    log "Removing user files for: $RUNNER_USER"
    
    # Remove home directory contents but preserve user
    rm -rf "/home/${RUNNER_USER}/runners" 2>/dev/null || true
    rm -rf "/home/${RUNNER_USER}/work" 2>/dev/null || true
    rm -rf "/home/${RUNNER_USER}/docker" 2>/dev/null || true
    rm -rf "/home/${RUNNER_USER}/_work" 2>/dev/null || true
    rm -rf "/home/${RUNNER_USER}/.docker" 2>/dev/null || true
    
    # Remove work directories from config
    if [[ -f "$CONFIG_FILE" ]]; then
        RUNNER_COUNT=$(yq eval '.runners | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
        for ((i=0; i<RUNNER_COUNT; i++)); do
            WORK_DIR=$(yq eval ".runners[$i].work_dir" "$CONFIG_FILE" 2>/dev/null || echo "")
            if [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then
                log "Removing work directory: $WORK_DIR"
                rm -rf "$WORK_DIR" 2>/dev/null || true
            fi
        done
    fi
    
    # Ask if user should be removed
    echo ""
    read -p "Remove user '$RUNNER_USER' completely? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        userdel -r "$RUNNER_USER" 2>/dev/null || true
        log "User $RUNNER_USER removed"
    else
        log "User $RUNNER_USER preserved"
    fi
fi

# Remove sudoers configuration
rm -f "/etc/sudoers.d/github-runner"

# Remove configuration directories
log "Removing configuration files..."
rm -rf "/opt/github-runner-setup"
rm -rf "/var/log/github-runners"

# Remove sysctl configuration
rm -f "/etc/sysctl.d/99-runner-security.conf"

# Remove fail2ban jail configuration
if [[ -f "/etc/fail2ban/jail.local" ]]; then
    log "Removing fail2ban configuration..."
    rm -f "/etc/fail2ban/jail.local"
    systemctl restart fail2ban 2>/dev/null || true
fi

# Reset firewall rules (optional)
echo ""
read -p "Reset UFW firewall rules to defaults? (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "Resetting firewall rules..."
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw --force enable
fi

# Final cleanup
log "Performing final cleanup..."

# Remove any remaining Docker artifacts
if command -v docker &> /dev/null; then
    docker system prune -af --volumes 2>/dev/null || true
fi

# Clear any remaining processes
pkill -f "Runner.Worker" 2>/dev/null || true
pkill -f "actions-runner" 2>/dev/null || true

log ""
log "🧹 Cleanup completed successfully!"
log ""
log "📋 Summary of actions performed:"
log "  ✅ Stopped and disabled systemd service"
log "  ✅ Removed runners from GitHub (if credentials available)"
log "  ✅ Cleaned up Docker containers, images, and volumes"
log "  ✅ Removed systemd service files"
log "  ✅ Removed management scripts and cron jobs"
log "  ✅ Cleaned up user files and directories"
log "  ✅ Removed configuration files"
log ""
log "💡 To reinstall, run the installation script again with a new configuration."

# Show any remaining Docker resources
if command -v docker &> /dev/null; then
    REMAINING_CONTAINERS=$(docker ps -a -q 2>/dev/null | wc -l)
    REMAINING_IMAGES=$(docker images -q 2>/dev/null | wc -l)
    REMAINING_VOLUMES=$(docker volume ls -q 2>/dev/null | wc -l)
    
    if [[ $REMAINING_CONTAINERS -gt 0 ]] || [[ $REMAINING_IMAGES -gt 0 ]] || [[ $REMAINING_VOLUMES -gt 0 ]]; then
        echo ""
        log "📊 Remaining Docker resources:"
        log "   Containers: $REMAINING_CONTAINERS"
        log "   Images: $REMAINING_IMAGES" 
        log "   Volumes: $REMAINING_VOLUMES"
    fi
fi