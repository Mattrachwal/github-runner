#!/bin/bash
set -euo pipefail

# Setup monitoring and management tools
CONFIG_FILE="${SCRIPT_DIR}/config.yml"
RUNNER_USER=$(yq eval '.system.runner_user' "$CONFIG_FILE")
RUNNER_HOME="/home/$RUNNER_USER"

log "Setting up monitoring and management tools..."

# Create management script
cat > /usr/local/bin/github-runner-manager <<'MANAGER_SCRIPT'
#!/bin/bash

CONFIG_FILE="/opt/github-runner-setup/config.yml"
RUNNER_USER=$(yq eval '.system.runner_user' "$CONFIG_FILE" 2>/dev/null || echo "github-runner")
GITHUB_ORG=$(yq eval '.github.org' "$CONFIG_FILE" 2>/dev/null)
GITHUB_TOKEN=$(yq eval '.github.token' "$CONFIG_FILE" 2>/dev/null)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_usage() {
    echo "GitHub Actions Runner Manager"
    echo ""
    echo "Usage: github-runner-manager [command]"
    echo ""
    echo "Commands:"
    echo "  status      Show runner status and health"
    echo "  list        List all configured runners"
    echo "  logs        Show service logs"
    echo "  restart     Restart all runners"
    echo "  stop        Stop all runners"
    echo "  start       Start all runners"
    echo "  clean       Clean up stopped containers"
    echo "  health      Check runner health"
    echo "  scale       Scale runner instances"
    echo "  github      Check GitHub API connectivity"
    echo ""
}

show_status() {
    echo -e "${BLUE}GitHub Actions Runner Status${NC}"
    echo "=================================="
    
    # Service status
    echo -e "\n${YELLOW}Service Status:${NC}"
    systemctl status github-runner-manager --no-pager -l || true
    
    # Container status
    echo -e "\n${YELLOW}Container Status:${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}\t{{.Size}}" | grep -E "(CONTAINER|runner-|ephemeral-)" || echo "No runners found"
    
    # Resource usage
    echo -e "\n${YELLOW}Resource Usage:${NC}"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" | grep -E "(CONTAINER|runner-|ephemeral-)" || true
}

list_runners() {
    echo -e "${BLUE}Configured Runners${NC}"
    echo "==================="
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Config file not found!${NC}"
        return 1
    fi
    
    RUNNER_COUNT=$(yq eval '.runners | length' "$CONFIG_FILE")
    echo -e "Total runner types: ${GREEN}$RUNNER_COUNT${NC}\n"
    
    for ((i=0; i<RUNNER_COUNT; i++)); do
        RUNNER_NAME=$(yq eval ".runners[$i].name" "$CONFIG_FILE")
        INSTANCES=$(yq eval ".runners[$i].instances" "$CONFIG_FILE")
        LABELS=$(yq eval ".runners[$i].labels | join(\", \")" "$CONFIG_FILE")
        MEMORY=$(yq eval ".runners[$i].resources.memory_limit" "$CONFIG_FILE")
        CPU=$(yq eval ".runners[$i].resources.cpu_limit" "$CONFIG_FILE")
        SCOPE=$(yq eval ".runners[$i].scope_url" "$CONFIG_FILE")
        
        echo -e "${YELLOW}$RUNNER_NAME${NC} (${INSTANCES} instances)"
        echo "  Labels: $LABELS"
        echo "  Resources: ${MEMORY} RAM, ${CPU} CPU"
        echo "  Scope: $SCOPE"
        echo ""
    done
}

show_logs() {
    echo -e "${BLUE}Service Logs${NC}"
    echo "============"
    journalctl -u github-runner-manager -f --no-pager
}

restart_runners() {
    echo -e "${YELLOW}Restarting all runners...${NC}"
    systemctl restart github-runner-manager
    echo -e "${GREEN}Restart initiated${NC}"
}

stop_runners() {
    echo -e "${YELLOW}Stopping all runners...${NC}"
    systemctl stop github-runner-manager
    echo -e "${GREEN}Runners stopped${NC}"
}

start_runners() {
    echo -e "${YELLOW}Starting all runners...${NC}"
    systemctl start github-runner-manager
    echo -e "${GREEN}Runners started${NC}"
}

clean_containers() {
    echo -e "${YELLOW}Cleaning up stopped containers...${NC}"
    docker container prune -f
    docker volume prune -f
    echo -e "${GREEN}Cleanup complete${NC}"
}

check_health() {
    echo -e "${BLUE}Runner Health Check${NC}"
    echo "==================="
    
    # Check service
    if systemctl is-active --quiet github-runner-manager; then
        echo -e "Service: ${GREEN}✓ Running${NC}"
    else
        echo -e "Service: ${RED}✗ Stopped${NC}"
    fi
    
    # Check containers
    RUNNING_CONTAINERS=$(docker ps -q | wc -l)
    echo -e "Running containers: ${GREEN}$RUNNING_CONTAINERS${NC}"
    
    # Check Docker daemon
    if docker version >/dev/null 2>&1; then
        echo -e "Docker: ${GREEN}✓ Available${NC}"
    else
        echo -e "Docker: ${RED}✗ Unavailable${NC}"
    fi
    
    # Check disk space
    DISK_USAGE=$(df /home/$RUNNER_USER | awk 'NR==2 {print $5}' | sed 's/%//')
    if [[ $DISK_USAGE -lt 80 ]]; then
        echo -e "Disk usage: ${GREEN}$DISK_USAGE%${NC}"
    elif [[ $DISK_USAGE -lt 90 ]]; then
        echo -e "Disk usage: ${YELLOW}$DISK_USAGE%${NC}"
    else
        echo -e "Disk usage: ${RED}$DISK_USAGE%${NC}"
    fi
}

scale_runners() {
    echo -e "${BLUE}Scale Runner Instances${NC}"
    echo "======================"
    echo "This feature requires manual configuration file editing."
    echo "Edit $CONFIG_FILE and modify the 'instances' value for each runner type."
    echo "Then run: github-runner-manager restart"
}

check_github_api() {
    echo -e "${BLUE}GitHub API Connectivity${NC}"
    echo "======================="
    
    if [[ -z "$GITHUB_TOKEN" ]] || [[ "$GITHUB_TOKEN" == "null" ]]; then
        echo -e "${RED}✗ GitHub token not configured${NC}"
        return 1
    fi
    
    # Test API connectivity
    RESPONSE=$(curl -s -w "%{http_code}" -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/orgs/$GITHUB_ORG" -o /dev/null)
    
    if [[ "$RESPONSE" == "200" ]]; then
        echo -e "${GREEN}✓ GitHub API accessible${NC}"
        
        # Get runner count from GitHub
        GITHUB_RUNNERS=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/orgs/$GITHUB_ORG/actions/runners" | \
            jq '.runners | length' 2>/dev/null || echo "0")
        echo -e "Registered runners: ${GREEN}$GITHUB_RUNNERS${NC}"
    else
        echo -e "${RED}✗ GitHub API error (HTTP $RESPONSE)${NC}"
    fi
}

# Main command handling
case "${1:-}" in
    "status")
        show_status
        ;;
    "list")
        list_runners
        ;;
    "logs")
        show_logs
        ;;
    "restart")
        restart_runners
        ;;
    "stop")
        stop_runners
        ;;
    "start")
        start_runners
        ;;
    "clean")
        clean_containers
        ;;
    "health")
        check_health
        ;;
    "scale")
        scale_runners
        ;;
    "github")
        check_github_api
        ;;
    *)
        print_usage
        ;;
esac
MANAGER_SCRIPT

# Make management script executable
chmod +x /usr/local/bin/github-runner-manager

# Create directory for setup files
mkdir -p /opt/github-runner-setup
cp "$CONFIG_FILE" /opt/github-runner-setup/

# Create logrotate configuration
cat > /etc/logrotate.d/github-runners <<'LOGROTATE'
/var/log/github-runners/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    copytruncate
}
LOGROTATE

# Create log directory
mkdir -p /var/log/github-runners
chown "$RUNNER_USER:$RUNNER_USER" /var/log/github-runners

# Create systemd drop-in directory for additional configuration
mkdir -p /etc/systemd/system/github-runner-manager.service.d

# Create health check script
cat > /usr/local/bin/runner-health-check <<'HEALTH_CHECK'
#!/bin/bash

RUNNER_USER=$(yq eval '.system.runner_user' "/opt/github-runner-setup/config.yml" 2>/dev/null || echo "github-runner")
LOG_FILE="/var/log/github-runners/health-check.log"

# Function to log with timestamp
log_with_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Check if service is running
if ! systemctl is-active --quiet github-runner-manager; then
    log_with_timestamp "ERROR: github-runner-manager service is not running"
    exit 1
fi

# Check container health
UNHEALTHY_CONTAINERS=$(docker ps --filter health=unhealthy --format "{{.Names}}" | wc -l)
if [[ $UNHEALTHY_CONTAINERS -gt 0 ]]; then
    log_with_timestamp "WARNING: $UNHEALTHY_CONTAINERS unhealthy containers detected"
    docker ps --filter health=unhealthy --format "{{.Names}}" >> "$LOG_FILE"
fi

# Check disk space
DISK_USAGE=$(df "/home/$RUNNER_USER" | awk 'NR==2 {print $5}' | sed 's/%//')
if [[ $DISK_USAGE -gt 90 ]]; then
    log_with_timestamp "ERROR: Disk usage critical: ${DISK_USAGE}%"
    exit 1
elif [[ $DISK_USAGE -gt 80 ]]; then
    log_with_timestamp "WARNING: Disk usage high: ${DISK_USAGE}%"
fi

log_with_timestamp "Health check passed"
HEALTH_CHECK

chmod +x /usr/local/bin/runner-health-check

# Create cron job for health checks
cat > /etc/cron.d/github-runner-health <<'CRON'
# GitHub Runner Health Check - every 5 minutes
*/5 * * * * root /usr/local/bin/runner-health-check >/dev/null 2>&1
CRON

# Create cleanup script for old logs and containers
cat > /usr/local/bin/runner-cleanup <<'CLEANUP'
#!/bin/bash

RUNNER_USER=$(yq eval '.system.runner_user' "/opt/github-runner-setup/config.yml" 2>/dev/null || echo "github-runner")
LOG_FILE="/var/log/github-runners/cleanup.log"

log_with_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log_with_timestamp "Starting cleanup"

# Clean up old Docker images (keep last 3 versions)
OLD_IMAGES=$(docker images --filter "dangling=true" -q)
if [[ -n "$OLD_IMAGES" ]]; then
    docker rmi $OLD_IMAGES >/dev/null 2>&1 || true
    log_with_timestamp "Removed dangling Docker images"
fi

# Clean up exited containers
EXITED_CONTAINERS=$(docker ps -a --filter status=exited -q)
if [[ -n "$EXITED_CONTAINERS" ]]; then
    docker rm $EXITED_CONTAINERS >/dev/null 2>&1 || true
    log_with_timestamp "Removed exited containers"
fi

# Clean up old logs (older than 30 days)
find "/var/log/github-runners" -name "*.log" -mtime +30 -delete 2>/dev/null || true
find "/home/$RUNNER_USER" -name "*.log" -mtime +7 -delete 2>/dev/null || true

log_with_timestamp "Cleanup completed"
CLEANUP

chmod +x /usr/local/bin/runner-cleanup

# Create daily cleanup cron job
cat > /etc/cron.d/github-runner-cleanup <<'CLEANUP_CRON'
# GitHub Runner Cleanup - daily at 2 AM
0 2 * * * root /usr/local/bin/runner-cleanup >/dev/null 2>&1
CLEANUP_CRON

# Create runner statistics script
cat > /usr/local/bin/runner-stats <<'STATS'
#!/bin/bash

CONFIG_FILE="/opt/github-runner-setup/config.yml"
GITHUB_ORG=$(yq eval '.github.org' "$CONFIG_FILE" 2>/dev/null)
GITHUB_TOKEN=$(yq eval '.github.token' "$CONFIG_FILE" 2>/dev/null)

echo "GitHub Actions Runner Statistics"
echo "================================"
echo "Generated: $(date)"
echo ""

# Local container stats
echo "Local Containers:"
echo "-----------------"
docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" | grep -E "(CONTAINER|runner-|ephemeral-)" || echo "No runners found"

echo ""

# GitHub API stats (if token is available)
if [[ -n "$GITHUB_TOKEN" ]] && [[ "$GITHUB_TOKEN" != "null" ]]; then
    echo "GitHub Registered Runners:"
    echo "-------------------------"
    
    RUNNERS_JSON=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/orgs/$GITHUB_ORG/actions/runners" 2>/dev/null)
    
    if [[ $? -eq 0 ]] && [[ -n "$RUNNERS_JSON" ]]; then
        echo "$RUNNERS_JSON" | jq -r '.runners[] | "\(.name)\t\(.status)\t\(.os) \(.architecture)\t\(.labels[].name)"' | \
            awk 'BEGIN{print "NAME\t\t\tSTATUS\t\tPLATFORM\t\tLABELS"} {print}' | column -t
        
        TOTAL_RUNNERS=$(echo "$RUNNERS_JSON" | jq '.total_count')
        ONLINE_RUNNERS=$(echo "$RUNNERS_JSON" | jq '.runners | map(select(.status == "online")) | length')
        
        echo ""
        echo "Summary: $ONLINE_RUNNERS/$TOTAL_RUNNERS runners online"
    else
        echo "Unable to fetch GitHub runner data"
    fi
fi
STATS

chmod +x /usr/local/bin/runner-stats

# Create bash completion for the management script
cat > /etc/bash_completion.d/github-runner-manager <<'COMPLETION'
_github_runner_manager() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="status list logs restart stop start clean health scale github"

    COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
    return 0
}

complete -F _github_runner_manager github-runner-manager
COMPLETION

log "✅ Monitoring and management tools installed"
log "📊 Available commands:"
log "   github-runner-manager status   - Show runner status"
log "   github-runner-manager health   - Check runner health"  
log "   runner-stats                   - Show detailed statistics"
log "   runner-health-check            - Manual health check"