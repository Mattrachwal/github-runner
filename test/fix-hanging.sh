#!/usr/bin/env bash
set -Eeuo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }

log "=== Applying fixes for hanging issues ==="

# Step 1: Stop all runners
log "1. Stopping all runners..."
systemctl stop 'github-runner@*' 2>/dev/null || true
sleep 3

# Kill any hanging processes
pkill -f "setup-node" || true
pkill -f "tar.*node" || true
pkill -f "_temp.*tar" || true
sleep 2

# Step 2: Update the systemd service file
log "2. Updating systemd service configuration..."

# Update base service to remove -l flag
cat > /etc/systemd/system/github-runner@.service <<'EOF'
[Unit]
Description=GitHub Actions Runner %i
Wants=network-online.target
After=network-online.target

[Service]
User=github-runner
Group=github-runner
WorkingDirectory=/opt/actions-runner/%i

# CRITICAL: Use exec without -l flag to prevent environment override
ExecStart=/bin/bash -c 'cd /opt/actions-runner/%i && exec ./run.sh --startuptype service'

KillMode=process
Restart=always
RestartSec=5

# Baseline hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
LockPersonality=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF

# Step 3: Update the override with all necessary environment variables
log "3. Updating systemd override configuration..."
install -d -m 0755 /etc/systemd/system/github-runner@.service.d

cat > /etc/systemd/system/github-runner@.service.d/override.conf <<'EOF'
[Service]
User=github-runner
Group=github-runner

# Set per-instance HOME - this overrides systemd's default
Environment=HOME=/var/lib/github-runner/%i
Environment=USER=github-runner
Environment=LOGNAME=github-runner

# CRITICAL: Actions tool cache and temp directories
# These are required for setup-* actions (node, python, etc.) to work properly
Environment=RUNNER_TOOL_CACHE=/opt/actions/_tool
Environment=RUNNER_TEMP=/var/lib/github-runner/%i/_temp
Environment=AGENT_TOOLSDIRECTORY=/opt/actions/_tool

# Set working directory to the runner installation
WorkingDirectory=/opt/actions-runner/%i

# Prevent git config conflicts
Environment=GIT_CONFIG_GLOBAL=/dev/null
Environment=GIT_CONFIG_SYSTEM=/dev/null

# CRITICAL: Clear the base ExecStart and replace without -l flag
ExecStart=
ExecStart=/bin/bash -c 'cd /opt/actions-runner/%i && exec ./run.sh --startuptype service'

# Timeouts to prevent hanging
TimeoutStartSec=300
TimeoutStopSec=60

# Optional: Resource limits (uncomment if needed)
# MemoryMax=4G
# CPUQuota=80%
# TasksMax=1000
EOF

# Step 4: Create/fix directory structure
log "4. Creating/fixing directory structure..."

# Ensure tool cache directories exist with proper permissions
install -d -m 0775 -o github-runner -g github-runner /opt/actions/_tool
install -d -m 0775 -o github-runner -g github-runner /opt/actions/_temp

# Fix permissions on existing directories
chown -R github-runner:github-runner /opt/actions/_tool 2>/dev/null || true
chown -R github-runner:github-runner /opt/actions/_temp 2>/dev/null || true

# Create _temp and _work directories for each runner instance
for dir in /opt/actions-runner/*; do
    if [[ -d "$dir" ]]; then
        inst=$(basename "$dir")
        home_dir="/var/lib/github-runner/${inst}"
        
        log "  Fixing directories for $inst..."
        
        # Create home directory
        install -d -o github-runner -g github-runner -m 0750 "$home_dir"
        
        # CRITICAL: Create _temp and _work directories
        install -d -o github-runner -g github-runner -m 0755 "$home_dir/_temp"
        install -d -o github-runner -g github-runner -m 0755 "$home_dir/_work"
        
        # Clean up any stuck files in temp
        if [[ -d "$home_dir/_temp" ]]; then
            find "$home_dir/_temp" -name "*.lock" -delete 2>/dev/null || true
            find "$home_dir/_temp" -name "*node*" -type f -mmin +60 -delete 2>/dev/null || true
            find "$home_dir/_temp" -name "*tar*" -type f -mmin +60 -delete 2>/dev/null || true
        fi
        
        # Create XDG directories
        install -d -o github-runner -g github-runner -m 0750 "$home_dir/.config"
        install -d -o github-runner -g github-runner -m 0750 "$home_dir/.local"
        install -d -o github-runner -g github-runner -m 0750 "$home_dir/.local/share"
        install -d -o github-runner -g github-runner -m 0750 "$home_dir/.cache"
        
        # Create/update .gitconfig
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

# Step 5: Check mount options
log "5. Checking mount options..."
mount_opts=$(mount | grep "$(df /opt/actions 2>/dev/null | tail -1 | awk '{print $1}')" | head -1 || echo "")
if echo "$mount_opts" | grep -q noexec; then
    log "WARNING: /opt/actions is mounted with noexec. This will cause issues!"
    log "Consider remounting without noexec or using a different location."
fi

# Step 6: Reload systemd
log "6. Reloading systemd configuration..."
systemctl daemon-reload

# Step 7: Start runners one by one
log "7. Starting runners..."
for dir in /opt/actions-runner/*; do
    if [[ -d "$dir" ]]; then
        inst=$(basename "$dir")
        service="github-runner@${inst}.service"
        
        log "  Starting $service..."
        systemctl start "$service"
        sleep 3
        
        if systemctl is-active --quiet "$service"; then
            log "  ✅ $service started successfully"
        else
            log "  ❌ $service failed to start"
            systemctl status "$service" --no-pager -l | head -10 | sed 's/^/    /'
        fi
    fi
done

# Step 8: Verify environment
log "8. Verifying environment..."
echo ""
for dir in /opt/actions-runner/*; do
    if [[ -d "$dir" ]]; then
        inst=$(basename "$dir")
        service="github-runner@${inst}.service"
        
        if systemctl is-active --quiet "$service"; then
            echo "Environment for $service:"
            systemctl show "$service" -p Environment --value | tr ' ' '\n' | grep -E '^(HOME|RUNNER_|AGENT_)' | sed 's/^/  /'
            echo ""
        fi
    fi
done

# Step 9: Test write permissions
log "9. Testing write permissions..."
test_runner=$(ls -d /opt/actions-runner/* 2>/dev/null | head -1)
if [[ -n "$test_runner" ]]; then
    inst=$(basename "$test_runner")
    home_dir="/var/lib/github-runner/${inst}"
    
    echo "Testing permissions for $inst:"
    
    # Test tool cache
    if sudo -u github-runner test -w /opt/actions/_tool; then
        echo "  ✅ Can write to /opt/actions/_tool"
    else
        echo "  ❌ Cannot write to /opt/actions/_tool"
    fi
    
    # Test runner temp
    if sudo -u github-runner test -w "$home_dir/_temp"; then
        echo "  ✅ Can write to $home_dir/_temp"
    else
        echo "  ❌ Cannot write to $home_dir/_temp"
    fi
fi

log ""
log "=== Fix complete ==="
log ""
log "🎯 Applied fixes:"
log "  • Removed -l flag from ExecStart to prevent environment override"
log "  • Added RUNNER_TEMP and RUNNER_TOOL_CACHE environment variables"
log "  • Created _temp and _work directories for all runners"
log "  • Fixed permissions on all directories"
log "  • Added timeouts to prevent hanging"
log "  • Cleaned up stuck files"
log ""
log "✅ Your runners should now work with setup-node and other setup-* actions!"
log ""
log "To verify, check: systemctl status 'github-runner@*'"
log "Then trigger a workflow that uses setup-node@v4"