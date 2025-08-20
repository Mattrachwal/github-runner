#!/usr/bin/env bash
set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }

echo "=== Docker and App Diagnostics ==="

# Check Docker access for github-runner user
echo "1. Testing Docker access as github-runner user:"
sudo -u github-runner docker version 2>/dev/null || echo "  ❌ Docker access failed"
sudo -u github-runner docker ps 2>/dev/null || echo "  ❌ Docker ps failed"

# Check if github-runner user is in docker group
echo ""
echo "2. Checking docker group membership:"
if groups github-runner | grep -q docker; then
    echo "  ✅ github-runner is in docker group"
else
    echo "  ❌ github-runner is NOT in docker group"
    echo "  Fix with: sudo usermod -aG docker github-runner"
fi

# Check Docker daemon status
echo ""
echo "3. Docker daemon status:"
systemctl is-active docker || echo "  ❌ Docker daemon not running"

# Test port availability
echo ""
echo "4. Testing port availability:"
for port in 3033 4010; do
    if netstat -tuln 2>/dev/null | grep -q ":$port "; then
        echo "  ⚠️  Port $port is already in use:"
        netstat -tuln | grep ":$port " | sed 's/^/    /'
    else
        echo "  ✅ Port $port is available"
    fi
done

# Check if any node processes are running
echo ""
echo "5. Existing node processes:"
ps aux | grep node | grep -v grep | sed 's/^/  /' || echo "  No node processes found"

echo ""
echo "=== Diagnostic complete ==="