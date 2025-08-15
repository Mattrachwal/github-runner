#!/usr/bin/env bash
# Debug script to check runner HOME setup step by step

set -euo pipefail

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }

echo "=== GitHub Runner HOME Directory Debug ==="

# 1. Check what services actually exist
echo "1. Checking for GitHub Runner services..."
echo "Unit files:"
systemctl list-unit-files 'github-runner@*' --no-legend 2>/dev/null || echo "  None found"

echo "Active/loaded units:"
systemctl list-units 'github-runner@*' --no-legend 2>/dev/null || echo "  None found"

# 2. Check systemd drop-in configuration
echo ""
echo "2. Checking systemd drop-in configuration..."
if [[ -f "/etc/systemd/system/github-runner@.service.d/override.conf" ]]; then
    echo "Override file exists:"
    cat /etc/systemd/system/github-runner@.service.d/override.conf | sed 's/^/  /'
else
    echo "  No override file found at /etc/systemd/system/github-runner@.service.d/override.conf"
fi

# 3. Check home directories
echo ""
echo "3. Checking home directories..."
if [[ -d "/var/lib/github-runner" ]]; then
    echo "Home directories:"
    ls -la /var/lib/github-runner/ | sed 's/^/  /'
else
    echo "  /var/lib/github-runner does not exist"
fi

# 4. Check specific service instances if they exist
echo ""
echo "4. Checking specific service instances..."
for service_file in /etc/systemd/system/github-runner@*.service; do
    if [[ -f "$service_file" ]]; then
        service_name=$(basename "$service_file")
        echo "Found service file: $service_name"
    fi
done

# Find actual running instances
for pid_file in /opt/actions-runner/*/; do
    if [[ -d "$pid_file" ]]; then
        instance=$(basename "$pid_file")
        service="github-runner@${instance}.service"
        echo ""
        echo "Checking instance: $instance"
        echo "  Service: $service"
        
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo "  Status: Running"
            echo "  Environment from systemd:"
            systemctl show "$service" -p Environment --value 2>/dev/null | tr ' ' '\n' | grep -E '^(HOME|USER|LOGNAME)' | sed 's/^/    /' || echo "    No HOME/USER/LOGNAME found"
            
            # Try to get actual environment from the process
            if pgrep -f "actions-runner.*$instance" >/dev/null; then
                pid=$(pgrep -f "actions-runner.*$instance" | head -1)
                echo "  Process environment (PID $pid):"
                sudo cat "/proc/$pid/environ" 2>/dev/null | tr '\0' '\n' | grep -E '^(HOME|USER|LOGNAME|PWD)' | sed 's/^/    /' || echo "    Could not read process environment"
            fi
        else
            echo "  Status: Not running"
            systemctl status "$service" --no-pager -l | head -10 | sed 's/^/    /'
        fi
    fi
done

# 5. Manual test
echo ""
echo "5. Manual environment test..."
if id -u github-runner >/dev/null 2>&1; then
    echo "Testing as github-runner user:"
    sudo -u github-runner bash -c 'echo "  HOME=$HOME"; echo "  USER=$USER"; echo "  PWD=$PWD"' 2>/dev/null || echo "  Failed to test as github-runner user"
else
    echo "  github-runner user does not exist"
fi

echo ""
echo "=== Debug complete ==="