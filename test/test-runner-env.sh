#!/usr/bin/env bash
# Test script to verify runner environment setup
# Usage: sudo bash test-runner-env.sh

set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }
need_root() { [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }; }

need_root

echo "=== Testing GitHub Runner Environment Setup ==="

# Check if any runner services exist
services=($(systemctl list-unit-files 'github-runner@*' --no-legend 2>/dev/null | awk '{print $1}' || true))

if [[ ${#services[@]} -eq 0 ]]; then
    echo "No GitHub runner services found."
    exit 1
fi

for service in "${services[@]}"; do
    instance="${service#github-runner@}"
    instance="${instance%.service}"
    
    echo ""
    echo "=== Testing service: $service (instance: $instance) ==="
    
    # Check if service is running
    if systemctl is-active --quiet "$service"; then
        echo "✓ Service is running"
    else
        echo "✗ Service is not running"
        systemctl status "$service" --no-pager || true
        continue
    fi
    
    # Check environment as seen by systemd
    echo "Environment variables from systemd:"
    systemctl show "$service" -p Environment --value | tr ' ' '\n' | grep -E '^(HOME|USER|LOGNAME|XDG_|GIT_)' || echo "  (none found)"
    
    # Test by running a command as the runner user
    expected_home="/var/lib/github-runner/${instance}"
    
    echo "Testing environment by running command as github-runner user..."
    result=$(sudo -u github-runner -i bash -c "
        echo HOME=\$HOME
        echo USER=\$USER  
        echo LOGNAME=\$LOGNAME
        echo PWD=\$PWD
        ls -ld \$HOME 2>/dev/null || echo 'HOME directory access failed'
        test -f \$HOME/.gitconfig && echo 'gitconfig exists' || echo 'gitconfig missing'
    " 2>&1) || true
    
    echo "$result" | sed 's/^/  /'
    
    # Check if HOME is set correctly
    if echo "$result" | grep -q "HOME=$expected_home"; then
        echo "✓ HOME directory correctly set to $expected_home"
    else
        echo "✗ HOME directory not correctly set (expected: $expected_home)"
    fi
    
    # Check directory permissions
    if [[ -d "$expected_home" ]]; then
        perm=$(stat -c "%a %U:%G" "$expected_home")
        echo "✓ Home directory exists with permissions: $perm"
    else
        echo "✗ Home directory $expected_home does not exist"
    fi
done

echo ""
echo "=== Test complete ==="