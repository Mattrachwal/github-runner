#!/usr/bin/env bash
set -Eeuo pipefail

# One-shot convenience: install + register + harden
# Flags:
#   WITH_DOCKER=1 to install Docker Engine
#
# Usage:
#   sudo WITH_DOCKER=1 ./scripts/setup.sh
#   sudo ./scripts/setup.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
sudo -E bash "$HERE/install.sh"
sudo -E bash "$HERE/register-from-json.sh"
sudo -E bash "$HERE/harden-systemd.sh"

echo "[OK] Setup complete. Your runners should appear online in GitHub."
