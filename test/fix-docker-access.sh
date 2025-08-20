#!/usr/bin/env bash
set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }

log "=== Fixing Docker Access for GitHub Runner ==="

# Check if Docker is installed
if ! command -v docker >/dev/null 2>&1; then
    log "❌ Docker is not installed. Run setup with WITH_DOCKER=1 to install Docker."
    exit 1
fi

# Check if docker group exists
if ! getent group docker >/dev/null 2>&1; then
    log "❌ Docker group doesn't exist. Docker may not be properly installed."
    exit 1
fi

# Add github-runner to docker group
log "Adding github-runner user to docker group..."
usermod -aG docker github-runner

# Verify the addition worked
if groups github-runner | grep -q docker; then
    log "✅ github-runner successfully added to docker group"
else
    log "❌ Failed to add github-runner to docker group"
    exit 1
fi

# Restart all runner services so they pick up the new group membership
log "Restarting GitHub Runner services to pick up new group membership..."
systemctl restart 'github-runner@hostral-*'

# Wait a moment for services to start
sleep 3

# Test Docker access
log "Testing Docker access..."
if sudo -u github-runner docker ps >/dev/null 2>&1; then
    log "✅ Docker access test successful!"
    
    # Show Docker info
    echo ""
    echo "Docker version accessible to github-runner:"
    sudo -u github-runner docker --version | sed 's/^/  /'
    
    echo ""
    echo "Docker containers (should show empty list if none running):"
    sudo -u github-runner docker ps | sed 's/^/  /'
else
    log "❌ Docker access test failed. You may need to:"
    log "   1. Restart the Docker service: sudo systemctl restart docker"
    log "   2. Reboot the system if group changes aren't taking effect"
    log "   3. Check Docker socket permissions: ls -la /var/run/docker.sock"
fi

log "=== Docker access fix complete ==="

# Show current group memberships
echo ""
echo "Current github-runner group memberships:"
groups github-runner | sed 's/^/  /'