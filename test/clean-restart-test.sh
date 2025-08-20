#!/usr/bin/env bash
set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }

log "=== Clean Restart and Test Runner Setup ==="

# Step 1: Complete uninstall
log "1. Running complete uninstall..."
if [[ -f "scripts/uninstall.sh" ]]; then
    bash scripts/uninstall.sh || true
else
    log "No uninstall script found, doing manual cleanup..."
    systemctl stop 'github-runner@*' 2>/dev/null || true
    systemctl disable 'github-runner@*' 2>/dev/null || true
    rm -rf /etc/systemd/system/github-runner@.service.d
    rm -f /etc/systemd/system/github-runner@.service
    systemctl daemon-reload
    rm -rf /opt/actions-runner
    rm -rf /var/lib/github-runner
    userdel -r github-runner 2>/dev/null || true
    groupdel github-runner 2>/dev/null || true
fi

log "2. Cleaning up any remaining processes..."
pkill -f "Runner.Listener" || true
pkill -f "Runner.Worker" || true
pkill -f "run.sh" || true
sleep 2

log "3. Verifying clean state..."
if systemctl list-units 'github-runner@*' --no-legend 2>/dev/null | grep -q github-runner; then
    log "⚠️  Some runner services still exist"
else
    log "✅ No runner services found"
fi

if id github-runner >/dev/null 2>&1; then
    log "⚠️  github-runner user still exists"
else
    log "✅ github-runner user removed"
fi

# Step 4: Fresh setup with Docker support
log "4. Running fresh setup with Docker support..."
log "Command: sudo WITH_DOCKER=1 ./scripts/setup.sh"
echo ""
echo "Press Enter to continue with fresh setup, or Ctrl+C to abort..."
read -r

WITH_DOCKER=1 bash scripts/setup.sh

# Step 5: Verify the setup
log "5. Verifying the new setup..."

echo ""
echo "=== Service Status ==="
systemctl status 'github-runner@hostral-*' --no-pager || true

echo ""
echo "=== Docker Access Test ==="
for i in {1..5}; do
    if systemctl is-active --quiet "github-runner@hostral-$i.service"; then
        echo "Testing Docker access for hostral-$i:"
        sudo -u github-runner docker ps 2>/dev/null | head -2 | sed 's/^/  /' || echo "  ❌ Docker access failed"
    fi
done

echo ""
echo "=== Git Config Test ==="
for i in {1..5}; do
    home_dir="/var/lib/github-runner/hostral-$i"
    if [[ -d "$home_dir" ]]; then
        echo "Testing git config for hostral-$i:"
        sudo -u github-runner env HOME="$home_dir" git config --get user.name 2>/dev/null | sed 's/^/  user.name: /' || echo "  No user.name set"
        
        # Test that git can create/write config (this would fail with /dev/null error)
        if sudo -u github-runner env HOME="$home_dir" git config --global test.value "test" 2>/dev/null; then
            echo "  ✅ Git config write test passed"
            sudo -u github-runner env HOME="$home_dir" git config --global --unset test.value 2>/dev/null || true
        else
            echo "  ❌ Git config write test failed"
        fi
    fi
done

echo ""
echo "=== Environment Check ==="
for i in {1..5}; do
    service="github-runner@hostral-$i.service"
    if systemctl is-active --quiet "$service"; then
        echo "Environment for $service:"
        systemctl show "$service" -p Environment --value | tr ' ' '\n' | grep -E '^HOME=' | sed 's/^/  /' || echo "  No HOME found"
    fi
done

log "=== Test complete ==="
log ""
log "🎯 What to check:"
log "  • All 5 services should be running"
log "  • Docker access should work for each runner"
log "  • Git config should work without /dev/null errors"
log "  • HOME should be set to /var/lib/github-runner/hostral-X for each service"
log ""
log "If everything looks good, try running a workflow to test!"