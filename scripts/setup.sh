#!/usr/bin/env bash
set -Eeuo pipefail

# All-in-one: install + register + (optional) harden
# Uses config files from config/systemd/ directory
# Flags:
#   WITH_DOCKER=1      -> install Docker Engine
#   FORCE_REREG=1      -> force re-registration of runners
#   SKIP_HARDEN=1      -> skip harden step

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# Install base system and unit files using config files
sudo -E bash "$HERE/install.sh"

# Copy systemd config files from our config directory
sudo install -d -m 0755 /etc/systemd/system/github-runner@.service.d

# Install base service from config
if [[ -f "$REPO_ROOT/config/systemd/github-runner@.service" ]]; then
    sudo install -m 0644 "$REPO_ROOT/config/systemd/github-runner@.service" /etc/systemd/system/
    echo "[setup] Installed base service from config/systemd/github-runner@.service"
fi

# Install override from config
if [[ -f "$REPO_ROOT/config/systemd/override.conf" ]]; then
    sudo install -m 0644 "$REPO_ROOT/config/systemd/override.conf" /etc/systemd/system/github-runner@.service.d/
    echo "[setup] Installed override from config/systemd/override.conf"
fi

# Reload systemd to pick up changes
sudo systemctl daemon-reload

# Register runners
sudo -E bash "$HERE/register-from-json.sh"

# Optional hardening
if [[ "${SKIP_HARDEN:-0}" != "1" && -x "$HERE/harden-systemd.sh" ]]; then
  sudo -E bash "$HERE/harden-systemd.sh"
fi

# Show status and verify environment
echo ""
echo "=== Service Status ==="
systemctl list-units --type=service | grep github-runner@ || true

echo ""
echo "=== Environment Check ==="
for service in $(systemctl list-units 'github-runner@*' --no-legend 2>/dev/null | awk '{print $1}'); do
  echo "Service: $service"
  systemctl show "$service" -p Environment --value 2>/dev/null | tr ' ' '\n' | grep -E '^(HOME|USER)' | sed 's/^/  /' || echo "  No HOME/USER found in systemd environment"
done

echo ""
echo "[OK] Setup complete. Runners should be online in GitHub → Settings → Actions → Runners."
echo "If HOME is still wrong, restart services with: sudo systemctl restart 'github-runner@*'"