#!/usr/bin/env bash
set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }

log "=== Complete GitHub Runner HOME Fix ==="

# Step 1: Stop all services completely
log "1. Stopping all GitHub Runner services..."
systemctl stop 'github-runner@*' 2>/dev/null || true
sleep 2

# Step 2: Kill any remaining processes aggressively
log "2. Killing any remaining runner processes..."
pkill -f "Runner.Listener" || true
pkill -f "Runner.Worker" || true  
pkill -f "run.sh" || true
pkill -f "run-helper.sh" || true
sleep 2

# Step 3: Force kill if anything is still running
pids=$(pgrep -f "actions-runner" || true)
if [[ -n "$pids" ]]; then
    log "Force killing remaining processes: $pids"
    kill -9 $pids || true
    sleep 1
fi

# Step 4: Remove any stale lock files
log "3. Cleaning up lock files..."
find /opt/actions-runner -name "*.lock" -delete 2>/dev/null || true
find /var/lib/github-runner -name "*.lock" -delete 2>/dev/null || true

# Step 5: Verify and fix systemd configuration
log "4. Verifying systemd configuration..."

# Check if override file exists and is correct
override_file="/etc/systemd/system/github-runner@.service.d/override.conf"
if [[ ! -f "$override_file" ]]; then
    log "Creating missing override.conf..."
    install -d -m 0755 /etc/systemd/system/github-runner@.service.d
    cat > "$override_file" <<'EOF'
[Service]
User=github-runner
Group=github-runner

# Set per-instance HOME - this overrides systemd's default /home/github-runner
Environment=HOME=/var/lib/github-runner/%i
Environment=USER=github-runner
Environment=LOGNAME=github-runner

# Set working directory to the runner installation, not the HOME
WorkingDirectory=/opt/actions-runner/%i

# Baseline protections
ProtectHome=yes
Environment=GIT_CONFIG_GLOBAL=/dev/null
Environment=GIT_CONFIG_SYSTEM=/dev/null

# CRITICAL: Clear the base ExecStart and replace without -l flag
# The -l flag causes login shell behavior which can override our environment
ExecStart=
ExecStart=/bin/bash -c 'cd /opt/actions-runner/%i && exec ./run.sh --startuptype service'

# Optional: Resource limits (uncomment if needed)
# MemoryMax=4G
# CPUQuota=80%
EOF
fi

# Step 6: Ensure home directories exist with correct permissions
log "5. Ensuring home directories exist..."
for i in {1..5}; do
    home_dir="/var/lib/github-runner/hostral-$i"
    install -d -o github-runner -g github-runner -m 0750 "$home_dir"
    
    # Create .gitconfig if missing
    if [[ ! -f "$home_dir/.gitconfig" ]]; then
        cat > "$home_dir/.gitconfig" <<'GITCONFIG'
[user]
	name = GitHub Runner
	email = runner@localhost
[safe]
	directory = *
[init]
	defaultBranch = main
[core]
	autocrlf = input
GITCONFIG
        chown github-runner:github-runner "$home_dir/.gitconfig"
        chmod 0644 "$home_dir/.gitconfig"
    fi
done

# Step 7: Reload systemd and restart services
log "6. Reloading systemd configuration..."
systemctl daemon-reload

log "7. Starting services one by one..."
for i in {1..5}; do
    service="github-runner@hostral-$i.service"
    log "Starting $service..."
    systemctl start "$service"
    sleep 3  # Give each service time to start before starting the next
    
    # Check if it started successfully
    if systemctl is-active --quiet "$service"; then
        log "✓ $service started successfully"
    else
        log "✗ $service failed to start"
        systemctl status "$service" --no-pager -l | head -10
    fi
done

# Step 8: Verify environment
log "8. Verifying environment for each service..."
for i in {1..5}; do
    service="github-runner@hostral-$i.service"
    if systemctl is-active --quiet "$service"; then
        log "Checking $service environment..."
        
        # Get environment from systemd
        systemctl show "$service" -p Environment --value | tr ' ' '\n' | grep -E '^HOME=' | sed 's/^/  systemd: /'
        
        # Get main PID and check its environment
        main_pid=$(systemctl show "$service" -p MainPID --value 2>/dev/null)
        if [[ "$main_pid" != "0" && "$main_pid" != "" ]] && [[ -f "/proc/$main_pid/environ" ]]; then
            cat "/proc/$main_pid/environ" 2>/dev/null | tr '\0' '\n' | grep -E '^HOME=' | sed 's/^/  process: /' || echo "  process: No HOME found"
        fi
    fi
done

log "=== Fix complete ==="
log "Services should now be running with correct HOME directories."
log "Check status with: systemctl status 'github-runner@hostral-*'"