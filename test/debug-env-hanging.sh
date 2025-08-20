#!/usr/bin/env bash
set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }

log "=== Debugging Environment Details Hanging ==="

# Step 1: Check what processes are currently running
log "1. Checking current processes..."
echo "Setup-node related processes:"
ps aux | grep -E "(setup-node|node|npm)" | grep -v grep | sed 's/^/  /' || echo "  No setup-node processes found"

echo ""
echo "Runner processes that might be stuck:"
ps aux | grep -E "(Runner\.|hostral-3)" | grep -v grep | sed 's/^/  /' || echo "  No runner processes found"

# Step 2: Check the Node.js installation that was found in cache
log "2. Checking the cached Node.js installation..."
tool_cache="/var/lib/github-runner/hostral-3/_tool/node/22.18.0/x64"
if [[ -d "$tool_cache" ]]; then
    echo "Node.js cache directory exists:"
    echo "  Path: $tool_cache"
    echo "  Contents:"
    ls -la "$tool_cache" | sed 's/^/    /' || echo "    Cannot list contents"
    
    echo "  Node binary:"
    if [[ -f "$tool_cache/bin/node" ]]; then
        echo "    ✅ Node binary exists"
        echo "    Permissions: $(ls -l "$tool_cache/bin/node")"
        
        # Test if we can execute it
        if sudo -u github-runner "$tool_cache/bin/node" --version 2>/dev/null; then
            echo "    ✅ Node binary is executable and working"
        else
            echo "    ❌ Node binary cannot be executed"
        fi
    else
        echo "    ❌ Node binary missing"
    fi
    
    echo "  NPM binary:"
    if [[ -f "$tool_cache/bin/npm" ]]; then
        echo "    ✅ NPM binary exists"
        echo "    Permissions: $(ls -l "$tool_cache/bin/npm")"
        
        # Test if npm works (this is often where it hangs)
        echo "    Testing npm --version (timeout 10s)..."
        if timeout 10s sudo -u github-runner env HOME="/var/lib/github-runner/hostral-3" "$tool_cache/bin/npm" --version 2>/dev/null; then
            echo "    ✅ NPM is working"
        else
            echo "    ❌ NPM hangs or fails"
        fi
    else
        echo "    ❌ NPM binary missing"
    fi
else
    echo "❌ Node.js cache directory does not exist: $tool_cache"
fi

# Step 3: Check environment file setup
log "3. Checking environment file setup..."
home_dir="/var/lib/github-runner/hostral-3"
echo "Checking for GitHub Actions environment files:"

# Check for environment files that setup-node might be trying to write
env_files=(
    "$home_dir/_temp/_runner_file_commands/add_path_*"
    "$home_dir/_temp/_runner_file_commands/set_env_*"
    "$GITHUB_ENV"
    "$GITHUB_PATH"
)

for pattern in "${env_files[@]}"; do
    if [[ "$pattern" == *"*"* ]]; then
        # Handle glob patterns
        found_files=($(ls $pattern 2>/dev/null || true))
        if [[ ${#found_files[@]} -gt 0 ]]; then
            for file in "${found_files[@]}"; do
                echo "  Found: $file"
                echo "    Permissions: $(ls -l "$file" 2>/dev/null || echo "Cannot stat")"
                echo "    Content: $(head -5 "$file" 2>/dev/null | sed 's/^/      /' || echo "Cannot read")"
            done
        fi
    else
        if [[ -n "$pattern" && -f "$pattern" ]]; then
            echo "  Found: $pattern"
            echo "    Permissions: $(ls -l "$pattern")"
            echo "    Content: $(head -5 "$pattern" | sed 's/^/      /')"
        fi
    fi
done

# Step 4: Check temp directory for stuck files
log "4. Checking temp directory for issues..."
temp_dir="/var/lib/github-runner/hostral-3/_temp"
if [[ -d "$temp_dir" ]]; then
    echo "Temp directory contents:"
    find "$temp_dir" -type f -mmin -30 | head -20 | sed 's/^/  /' || echo "  No recent files"
    
    echo ""
    echo "Files that might be causing hangs:"
    find "$temp_dir" -name "*runner_file_commands*" -o -name "*env*" -o -name "*path*" | sed 's/^/  /' || echo "  No environment command files"
    
    echo ""
    echo "Disk usage of temp directory:"
    du -sh "$temp_dir" | sed 's/^/  /'
else
    echo "❌ Temp directory does not exist: $temp_dir"
fi

# Step 5: Check if there are any file locks or permissions issues
log "5. Checking for file locks and permissions..."
echo "Open files by github-runner user:"
lsof -u github-runner 2>/dev/null | grep -E "(node|npm|_temp|_tool)" | head -10 | sed 's/^/  /' || echo "  No relevant open files found"

echo ""
echo "Files in temp that might be locked:"
find "/var/lib/github-runner/hostral-3/_temp" -name "*.lock" -o -name "*.tmp" 2>/dev/null | sed 's/^/  /' || echo "  No lock files found"

# Step 6: Test environment variable setting manually
log "6. Testing environment variable operations..."
echo "Testing if we can write to environment files:"

# Simulate what setup-node does
test_env_setup() {
    local home_dir="/var/lib/github-runner/hostral-3"
    local temp_dir="$home_dir/_temp"
    
    # Create a test environment command file
    local test_env_file="$temp_dir/test_env_$$"
    
    if sudo -u github-runner bash -c "echo 'TEST_VAR=test_value' > '$test_env_file'" 2>/dev/null; then
        echo "  ✅ Can write environment files"
        sudo -u github-runner rm -f "$test_env_file"
    else
        echo "  ❌ Cannot write environment files"
    fi
    
    # Test PATH modification
    local test_path_file="$temp_dir/test_path_$$"
    if sudo -u github-runner bash -c "echo '/test/path' > '$test_path_file'" 2>/dev/null; then
        echo "  ✅ Can write PATH files"
        sudo -u github-runner rm -f "$test_path_file"
    else
        echo "  ❌ Cannot write PATH files"
    fi
}

test_env_setup

# Step 7: Look for recent GitHub Actions logs
log "7. Checking for GitHub Actions logs..."
log_locations=(
    "/var/lib/github-runner/hostral-3/_diag"
    "/var/lib/github-runner/hostral-3/_diag/Runner_*"
    "/opt/actions-runner/hostral-3/_diag"
)

for log_loc in "${log_locations[@]}"; do
    if [[ -d "$log_loc" ]] || [[ "$log_loc" == *"*"* && $(ls $log_loc 2>/dev/null) ]]; then
        echo "Found log location: $log_loc"
        if [[ "$log_loc" == *"*"* ]]; then
            # Handle wildcards
            ls -la $log_loc 2>/dev/null | tail -5 | sed 's/^/  /' || true
        else
            ls -la "$log_loc" | tail -5 | sed 's/^/  /' || true
        fi
    fi
done

# Step 8: Check system resource usage during hang
log "8. Checking system resources..."
echo "Memory usage:"
free -h | sed 's/^/  /'

echo ""
echo "Top CPU consumers:"
ps aux --sort=-%cpu | head -10 | sed 's/^/  /'

echo ""
echo "I/O wait and load:"
uptime | sed 's/^/  /'
vmstat 1 1 | tail -1 | sed 's/^/  /' || echo "  vmstat not available"

log "=== Debug complete ==="
log ""
log "🔍 Most likely causes of hanging at 'Environment details':"
log "  • NPM command hanging (common issue)"
log "  • Unable to write to environment files"
log "  • PATH modification failing"
log "  • Node.js binary corrupted in cache"
log "  • File permission issues in temp directory"
log ""
log "Try these fixes:"
log "  • Clear the Node.js cache and force re-download"
log "  • Add timeout to npm operations"
log "  • Check if npm config is causing issues"