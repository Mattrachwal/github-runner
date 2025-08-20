#!/usr/bin/env bash
set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }

log "=== Node.js Setup Debugging ==="

# Function to check directory permissions and ownership
check_dir() {
    local dir="$1"
    local name="$2"
    echo ""
    echo "$name directory analysis:"
    if [[ -d "$dir" ]]; then
        echo "  Path: $dir"
        echo "  Permissions: $(ls -ld "$dir")"
        echo "  Disk usage: $(du -sh "$dir" 2>/dev/null || echo "Cannot read")"
        echo "  Free space: $(df -h "$dir" | tail -1)"
        echo "  Mount options: $(mount | grep "$(df "$dir" | tail -1 | awk '{print $1}')" | head -1)"
        
        # Test write access as github-runner
        if sudo -u github-runner test -w "$dir"; then
            echo "  ✅ github-runner can write to $dir"
        else
            echo "  ❌ github-runner CANNOT write to $dir"
        fi
        
        # Test creating a temp file
        local testfile="$dir/.test-$$"
        if sudo -u github-runner touch "$testfile" 2>/dev/null; then
            echo "  ✅ Can create files in $dir"
            sudo -u github-runner rm -f "$testfile"
        else
            echo "  ❌ Cannot create files in $dir"
        fi
    else
        echo "  ❌ Directory $dir does not exist"
    fi
}

# 1. Check critical directories for Node.js setup
log "1. Checking critical directories..."

for i in {1..5}; do
    echo "=== Runner hostral-$i ==="
    
    # Home directory
    check_dir "/var/lib/github-runner/hostral-$i" "HOME"
    
    # Temp directory
    check_dir "/var/lib/github-runner/hostral-$i/_temp" "_temp"
    
    # Work directory  
    check_dir "/var/lib/github-runner/hostral-$i/_work" "_work"
    
    # Tool cache
    check_dir "/opt/actions/_tool" "Tool cache"
    
    # Runner temp
    check_dir "/opt/actions/_temp" "Runner temp"
done

# 2. Check for process conflicts
echo ""
echo ""
log "2. Checking for conflicting processes..."
echo "Node processes:"
ps aux | grep node | grep -v grep | sed 's/^/  /' || echo "  No node processes found"

echo ""
echo "Tar processes:"
ps aux | grep tar | grep -v grep | sed 's/^/  /' || echo "  No tar processes found"

echo ""
echo "Any setup-node processes:"
ps aux | grep setup-node | grep -v grep | sed 's/^/  /' || echo "  No setup-node processes found"

# 3. Check environment variables for each service
echo ""
echo ""
log "3. Checking service environments..."
for i in {1..5}; do
    service="github-runner@hostral-$i.service"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo ""
        echo "Service $service environment:"
        systemctl show "$service" -p Environment --value | tr ' ' '\n' | sed 's/^/  /'
        
        # Get the actual runner process environment
        if pgrep -f "hostral-$i.*run.sh" >/dev/null; then
            pid=$(pgrep -f "hostral-$i.*run.sh" | head -1)
            echo "  Actual process environment (PID $pid):"
            sudo cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n' | grep -E '^(HOME|USER|RUNNER_TOOL_CACHE|RUNNER_TEMP|PATH)' | sed 's/^/    /' || echo "    Could not read process environment"
        fi
    fi
done

# 4. Test tar extraction manually
echo ""
echo ""
log "4. Testing tar extraction manually..."
test_tar() {
    local runner_num="$1"
    local home_dir="/var/lib/github-runner/hostral-$runner_num"
    local temp_dir="$home_dir/_temp"
    
    echo ""
    echo "Testing tar for hostral-$runner_num:"
    
    # Create temp directory if it doesn't exist
    sudo -u github-runner mkdir -p "$temp_dir"
    
    # Test creating a simple tar and extracting it
    local test_dir="$temp_dir/tar-test-$$"
    local test_tar="$temp_dir/test.tar.gz"
    
    if sudo -u github-runner mkdir -p "$test_dir/source" && \
       sudo -u github-runner echo "test content" > "$test_dir/source/test.txt" && \
       sudo -u github-runner tar -czf "$test_tar" -C "$test_dir/source" . && \
       sudo -u github-runner mkdir -p "$test_dir/extract" && \
       sudo -u github-runner tar -xzf "$test_tar" -C "$test_dir/extract"; then
        echo "  ✅ Tar extraction test passed"
        sudo -u github-runner rm -rf "$test_dir" "$test_tar"
    else
        echo "  ❌ Tar extraction test failed"
        # Don't clean up on failure so we can investigate
    fi
}

# Test on the runner that's having issues
test_tar 3

# 5. Check system resources
echo ""
echo ""
log "5. Checking system resources..."
echo "Memory usage:"
free -h | sed 's/^/  /'

echo ""
echo "CPU load:"
uptime | sed 's/^/  /'

echo ""
echo "Disk I/O:"
iostat 1 1 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  iostat not available"

# 6. Check for file system issues
echo ""
echo ""
log "6. Checking file system..."
echo "Recent dmesg errors:"
dmesg | tail -20 | grep -iE "(error|fail|denied)" | sed 's/^/  /' || echo "  No recent errors in dmesg"

echo ""
echo "File system errors:"
journalctl -n 50 --no-pager | grep -iE "(ext4|xfs|fs).*error" | sed 's/^/  /' || echo "  No recent file system errors"

# 7. Manual setup-node test
echo ""
echo ""
log "7. Manual setup-node test..."
echo "This will attempt to manually trigger the same Node.js download that's hanging..."
echo "Press Ctrl+C within 30 seconds to abort, or let it run to test..."
sleep 5

# Create a minimal test environment
test_manual_setup() {
    local home_dir="/var/lib/github-runner/hostral-3"
    local temp_dir="$home_dir/_temp"
    local tool_cache="/opt/actions/_tool"
    
    echo "Setting up test environment..."
    sudo -u github-runner mkdir -p "$temp_dir"
    
    echo "Testing Node.js download as github-runner user..."
    echo "Environment will be:"
    echo "  HOME=$home_dir"
    echo "  RUNNER_TEMP=$temp_dir" 
    echo "  RUNNER_TOOL_CACHE=$tool_cache"
    
    # Try a simple curl download test first
    echo ""
    echo "Testing curl download..."
    if sudo -u github-runner curl -fsSL "https://nodejs.org/dist/v22.18.0/node-v22.18.0-linux-x64.tar.gz" -o "$temp_dir/node-test.tar.gz" --max-time 30; then
        echo "✅ Curl download successful"
        
        echo "Testing tar extraction..."
        if sudo -u github-runner mkdir -p "$temp_dir/node-test" && \
           sudo -u github-runner tar -xzf "$temp_dir/node-test.tar.gz" -C "$temp_dir/node-test" --strip-components=1 --max-time=30; then
            echo "✅ Tar extraction successful"
        else
            echo "❌ Tar extraction failed or hung"
        fi
        
        # Cleanup
        sudo -u github-runner rm -rf "$temp_dir/node-test"* 2>/dev/null || true
    else
        echo "❌ Curl download failed"
    fi
}

# Run the manual test with a timeout
timeout 60s bash -c "$(declare -f test_manual_setup); test_manual_setup" || echo "Manual test timed out or failed"

echo ""
echo ""
log "=== Debug complete ==="
log ""
log "🔍 What to look for:"
log "  • Permission issues with _temp directories"
log "  • noexec mount options preventing tar execution"
log "  • Insufficient disk space"
log "  • Process conflicts or resource exhaustion"
log "  • Network issues downloading Node.js"
log ""
log "If tar extraction is hanging, try:"
log "  • sudo systemctl restart 'github-runner@*'"
log "  • Check if /tmp or /var is full"
log "  • Verify no noexec mount options on working directories"