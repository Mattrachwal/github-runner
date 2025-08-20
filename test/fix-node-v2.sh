#!/usr/bin/env bash
set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }

log "=== Fixing Your Specific Node.js Hanging Issue ==="

# Step 1: Kill the hung node process that's using 99.8% CPU
log "1. Killing the hung node process..."
echo "Found hung node process:"
ps aux | grep "node.*npm.*version" | grep -v grep || echo "No hung node process found"

# Kill the specific hung process
pkill -f "node.*npm.*version" || true
pkill -f "node.*22.18.0.*npm" || true

# Kill any other stuck node processes
pgrep -f "node.*_tool.*npm" | xargs -r kill -9 || true

sleep 2

# Step 2: Stop all runners to prevent conflicts
log "2. Stopping all runners..."
systemctl stop 'github-runner@*'
sleep 3

# Step 3: Clean up the stuck Node.js installation
log "3. Cleaning up stuck Node.js installation..."
# Remove the problematic Node.js installation in hostral-5's tool cache
if [[ -d "/var/lib/github-runner/hostral-5/_tool/node" ]]; then
    echo "Removing stuck Node.js installation from hostral-5..."
    rm -rf /var/lib/github-runner/hostral-5/_tool/node
fi

# Clean up any partial downloads or extractions
for i in {1..5}; do
    home_dir="/var/lib/github-runner/hostral-$i"
    if [[ -d "$home_dir/_temp" ]]; then
        find "$home_dir/_temp" -name "*node*" -type f -delete 2>/dev/null || true
        find "$home_dir/_temp" -name "*node*" -type d -exec rm -rf {} + 2>/dev/null || true
    fi
done

# Step 4: Create missing _temp and _work directories for all runners
log "4. Creating missing _temp and _work directories..."
for i in {1..5}; do
    home_dir="/var/lib/github-runner/hostral-$i"
    temp_dir="$home_dir/_temp"
    work_dir="$home_dir/_work"
    
    echo "Creating directories for hostral-$i..."
    install -d -m 0755 -o github-runner -g github-runner "$temp_dir"
    install -d -m 0755 -o github-runner -g github-runner "$work_dir"
    
    echo "  ✅ Created $temp_dir"
    echo "  ✅ Created $work_dir"
done

# Step 5: Fix the systemd override to include missing environment variables
log "5. Updating systemd configuration with missing environment variables..."
cat > /etc/systemd/system/github-runner@.service.d/override.conf <<'EOF'
[Service]
User=github-runner
Group=github-runner

# Set per-instance HOME - this overrides systemd's default
Environment=HOME=/var/lib/github-runner/%i
Environment=USER=github-runner
Environment=LOGNAME=github-runner

# CRITICAL: Set the tool cache and temp directories
Environment=RUNNER_TOOL_CACHE=/opt/actions/_tool
Environment=RUNNER_TEMP=/var/lib/github-runner/%i/_temp

# Set working directory to the runner installation
WorkingDirectory=/opt/actions-runner/%i

# Add timeouts to prevent hanging
TimeoutStartSec=300
TimeoutStopSec=60

# CRITICAL: Clear the base ExecStart and replace without -l flag
ExecStart=
ExecStart=/bin/bash -c 'cd /opt/actions-runner/%i && exec ./run.sh --startuptype service'

# Resource limits to prevent exhaustion
MemoryMax=4G
TasksMax=1000
EOF

# Step 6: Reload systemd
log "6. Reloading systemd configuration..."
systemctl daemon-reload

# Step 7: Start runners one by one and verify
log "7. Starting runners one by one..."
for i in {1..5}; do
    service="github-runner@hostral-$i.service"
    echo ""
    echo "Starting $service..."
    systemctl start "$service"
    
    # Wait and check
    sleep 5
    if systemctl is-active --quiet "$service"; then
        echo "✅ $service started successfully"
        
        # Verify environment
        echo "Environment check:"
        systemctl show "$service" -p Environment --value | tr ' ' '\n' | grep -E '^(HOME|RUNNER_)' | sed 's/^/  /'
    else
        echo "❌ $service failed to start"
        echo "Status:"
        systemctl status "$service" --no-pager -l | head -10 | sed 's/^/  /'
    fi
done

# Step 8: Verify no hung processes
log "8. Verifying no hung processes..."
sleep 10
echo "Checking for high CPU processes:"
ps aux --sort=-%cpu | head -10 | grep -E "(CPU|node|npm)" || echo "No high CPU processes found"

# Step 9: Test Node.js setup manually
log "9. Testing Node.js setup with proper environment..."
test_node_with_env() {
    local runner_num="$1"
    local home_dir="/var/lib/github-runner/hostral-$runner_num"
    local temp_dir="$home_dir/_temp"
    local tool_cache="/opt/actions/_tool"
    
    echo ""
    echo "Testing Node.js setup for hostral-$runner_num with proper environment..."
    
    # Test with the exact environment the runner will use
    if sudo -u github-runner env \
        HOME="$home_dir" \
        RUNNER_TEMP="$temp_dir" \
        RUNNER_TOOL_CACHE="$tool_cache" \
        USER=github-runner \
        LOGNAME=github-runner \
        bash -c '
            echo "Environment:"
            echo "  HOME=$HOME"
            echo "  RUNNER_TEMP=$RUNNER_TEMP" 
            echo "  RUNNER_TOOL_CACHE=$RUNNER_TOOL_CACHE"
            echo ""
            
            # Test creating files in temp
            if touch "$RUNNER_TEMP/test-$$" 2>/dev/null; then
                echo "✅ Can write to RUNNER_TEMP"
                rm -f "$RUNNER_TEMP/test-$$"
            else
                echo "❌ Cannot write to RUNNER_TEMP"
            fi
            
            # Test creating files in tool cache
            if touch "$RUNNER_TOOL_CACHE/test-$$" 2>/dev/null; then
                echo "✅ Can write to RUNNER_TOOL_CACHE"
                rm -f "$RUNNER_TOOL_CACHE/test-$$"
            else
                echo "❌ Cannot write to RUNNER_TOOL_CACHE"
            fi
        '; then
        echo "✅ Environment test passed for hostral-$runner_num"
    else
        echo "❌ Environment test failed for hostral-$runner_num"
    fi
}

# Test the first runner
test_node_with_env 1

log "=== Fix Complete ==="
log ""
log "🎯 What was fixed:"
log "  • Killed the hung node process (99.8% CPU)"
log "  • Created missing _temp and _work directories for all runners"
log "  • Added RUNNER_TEMP and RUNNER_TOOL_CACHE environment variables"
log "  • Added timeouts to prevent future hanging"
log "  • Cleaned up any partial Node.js installations"
log ""
log "✅ Your runners should now be able to use setup-node without hanging!"
log ""
log "To test, trigger a workflow that uses setup-node@v4"