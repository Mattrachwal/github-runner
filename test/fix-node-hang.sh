#!/usr/bin/env bash
set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }

log "=== Fixing Node.js Setup Hanging Issue ==="

# Step 1: Stop all runners and clean up any hanging processes
log "1. Stopping all runners and cleaning up processes..."
systemctl stop 'github-runner@*' 2>/dev/null || true
sleep 2

# Kill any hanging tar processes
pkill -f "tar.*node.*tar.gz" || true
pkill -f "setup-node" || true
pkill -f "_temp.*tar" || true

# Kill any Node.js download processes
pkill -f "curl.*nodejs.org" || true
pkill -f "wget.*nodejs.org" || true

sleep 3

# Step 2: Clean up temp directories
log "2. Cleaning up temp directories..."
for i in {1..5}; do
    temp_dir="/var/lib/github-runner/hostral-$i/_temp"
    if [[ -d "$temp_dir" ]]; then
        echo "Cleaning $temp_dir..."
        # Remove any partial downloads or extractions
        find "$temp_dir" -name "*node*" -type f -delete 2>/dev/null || true
        find "$temp_dir" -name "*node*" -type d -exec rm -rf {} + 2>/dev/null || true
        
        # Clean up any temp files older than 1 hour
        find "$temp_dir" -type f -mmin +60 -delete 2>/dev/null || true
        
        # Fix permissions
        chown -R github-runner:github-runner "$temp_dir" 2>/dev/null || true
        chmod -R 755 "$temp_dir" 2>/dev/null || true
    fi
done

# Step 3: Fix the systemd override to add proper timeouts and environment
log "3. Updating systemd configuration with timeouts..."
cat > /etc/systemd/system/github-runner@.service.d/override.conf <<'EOF'
[Service]
User=github-runner
Group=github-runner

# Set per-instance HOME - this overrides systemd's default /home/github-runner
Environment=HOME=/var/lib/github-runner/%i
Environment=USER=github-runner
Environment=LOGNAME=github-runner

# Set working directory to the runner installation, not the HOME
WorkingDirectory=/opt/actions-runner/%i

# Actions tool cache and temp directories
Environment=RUNNER_TOOL_CACHE=/opt/actions/_tool
Environment=RUNNER_TEMP=/opt/actions/_temp

# Git configuration to prevent conflicts
Environment=GIT_CONFIG_GLOBAL=/dev/null
Environment=GIT_CONFIG_SYSTEM=/dev/null

# Timeout settings to prevent hanging
TimeoutStartSec=300
TimeoutStopSec=60

# Baseline protections
ProtectHome=yes

# CRITICAL: Clear the base ExecStart and replace without -l flag
# The -l flag causes login shell behavior which can override our environment
ExecStart=
ExecStart=/bin/bash -c 'cd /opt/actions-runner/%i && exec ./run.sh --startuptype service'

# Resource limits to prevent exhaustion
MemoryMax=4G
TasksMax=1000
EOF

# Step 4: Ensure proper tool cache directories with correct permissions
log "4. Setting up tool cache directories..."
install -d -m 0775 -o github-runner -g github-runner /opt/actions/_tool
install -d -m 0775 -o github-runner -g github-runner /opt/actions/_temp

# Make sure they're not on a noexec mount
mount_opts=$(mount | grep "$(df /opt/actions | tail -1 | awk '{print $1}')" | head -1 || echo "")
if echo "$mount_opts" | grep -q noexec; then
    log "WARNING: /opt/actions is mounted with noexec. This will cause Node.js setup to fail."
    log "You need to remount without noexec or move the tool cache to a different location."
fi

# Step 5: Create individual temp directories for each runner
log "5. Creating individual temp and work directories..."
for i in {1..5}; do
    home_dir="/var/lib/github-runner/hostral-$i"
    temp_dir="$home_dir/_temp"
    work_dir="$home_dir/_work"
    
    # Create directories with proper permissions
    install -d -m 0755 -o github-runner -g github-runner "$temp_dir"
    install -d -m 0755 -o github-runner -g github-runner "$work_dir"
    
    # Create a .gitconfig in each home directory
    gitconfig="$home_dir/.gitconfig"
    cat > "$gitconfig" <<'GITCONFIG'
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
    chown github-runner:github-runner "$gitconfig"
    chmod 0644 "$gitconfig"
    
    # Test write permissions
    if ! sudo -u github-runner test -w "$temp_dir"; then
        log "ERROR: github-runner cannot write to $temp_dir"
        ls -ld "$temp_dir"
    fi
done

# Step 6: Add additional environment variables to help with debugging
log "6. Adding debug environment..."
cat >> /etc/systemd/system/github-runner@.service.d/override.conf <<'EOF'

# Debug settings to help troubleshoot
Environment=NODE_OPTIONS="--max-old-space-size=4096"
Environment=ACTIONS_RUNNER_DEBUG=true
Environment=ACTIONS_STEP_DEBUG=false
EOF

# Step 7: Reload and restart services
log "7. Reloading systemd and restarting services..."
systemctl daemon-reload

# Start services one at a time with delays
for i in {1..5}; do
    service="github-runner@hostral-$i.service"
    log "Starting $service..."
    systemctl start "$service"
    
    # Wait and check if it started successfully
    sleep 5
    if systemctl is-active --quiet "$service"; then
        log "✅ $service started successfully"
    else
        log "❌ $service failed to start"
        systemctl status "$service" --no-pager -l | head -15
    fi
done

# Step 8: Verify the environment
log "8. Verifying environment..."
for i in {1..5}; do
    service="github-runner@hostral-$i.service"
    if systemctl is-active --quiet "$service"; then
        echo ""
        echo "Environment for $service:"
        systemctl show "$service" -p Environment --value | tr ' ' '\n' | grep -E '^(HOME|RUNNER_|USER)' | sed 's/^/  /'
    fi
done

# Step 9: Test Node.js download manually
log "9. Testing Node.js download manually..."
test_node_download() {
    local home_dir="/var/lib/github-runner/hostral-1"
    local temp_dir="$home_dir/_temp"
    local test_file="$temp_dir/node-download-test.tar.gz"
    
    echo "Testing Node.js download as github-runner user..."
    if sudo -u github-runner env HOME="$home_dir" curl -fsSL \
        "https://nodejs.org/dist/v22.18.0/node-v22.18.0-linux-x64.tar.gz" \
        -o "$test_file" --max-time 30; then
        echo "✅ Download test successful"
        
        # Test extraction
        local extract_dir="$temp_dir/node-extract-test"
        sudo -u github-runner mkdir -p "$extract_dir"
        
        if timeout 30s sudo -u github-runner tar -xzf "$test_file" -C "$extract_dir" --strip-components=1; then
            echo "✅ Extraction test successful"
        else
            echo "❌ Extraction test failed or timed out"
        fi
        
        # Cleanup
        sudo -u github-runner rm -rf "$test_file" "$extract_dir" 2>/dev/null || true
    else
        echo "❌ Download test failed"
    fi
}

timeout 60s bash -c "$(declare -f test_node_download); test_node_download" || echo "Node.js test timed out"

log "=== Fix complete ==="
log ""
log "🎯 Changes made:"
log "  • Added proper timeouts to prevent hanging"
log "  • Fixed environment variables and permissions"
log "  • Cleaned up any hanging processes and temp files"
log "  • Added resource limits to prevent exhaustion"
log "  • Created proper temp directories for each runner"
log ""
log "If Node.js setup still hangs, check:"
log "  • Disk space: df -h"
log "  • Mount options: mount | grep actions"
log "  • Network connectivity to nodejs.org"
log "  • System resources: free -h && top"