#!/usr/bin/env bash
set -Eeuo pipefail

# All-in-one: install + enforce override + register + (optional) harden
# Flags:
#   WITH_DOCKER=1      -> install Docker Engine
#   FORCE_REREG=1      -> force re-registration of runners
#   SKIP_HARDEN=1      -> skip harden step
#   REWRITE_OVERRIDE=1 -> forcibly rewrite systemd override even if present

HERE="$(cd "$(dirname "$0")" && pwd)"

ensure_override() {
  local dropin_dir="/etc/systemd/system/github-runner@.service.d"
  local dropin="${dropin_dir}/override.conf"
  local desired="ExecStart=/bin/bash -lc 'cd /opt/actions-runner/%i && exec /bin/bash run.sh --startuptype service'"

  sudo install -d -m 0755 "$dropin_dir"
  if [[ "${REWRITE_OVERRIDE:-0}" == "1" ]] || \
     ! systemctl cat github-runner@.service 2>/dev/null | grep -Fq "$desired"; then
    sudo tee "$dropin" >/dev/null <<'EOF'
[Service]
WorkingDirectory=/opt/actions-runner/%i
ExecStart=
ExecStart=/bin/bash -lc 'cd /opt/actions-runner/%i && exec /bin/bash run.sh --startuptype service'
EOF
    sudo systemctl daemon-reload
  fi
}

sudo -E bash "$HERE/install.sh"
ensure_override
sudo -E bash "$HERE/register-from-json.sh"

if [[ "${SKIP_HARDEN:-0}" != "1" && -x "$HERE/harden-systemd.sh" ]]; then
  sudo -E bash "$HERE/harden-systemd.sh"
fi

systemctl list-units --type=service | grep github-runner@ || true
systemctl show github-runner@*.service -p ExecStart 2>/dev/null || true

echo "[OK] Setup complete. Runners should be online in GitHub → Settings → Actions → Runners."
