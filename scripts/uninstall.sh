#!/usr/bin/env bash
set -Eeuo pipefail

# Full removal. Flags:
#   KEEP_USER=1    -> do not remove github-runner user/group
#   LEAVE_CONFIG=1 -> keep /etc/github-runner/config.json

need_root() { [[ $EUID -eq 0 ]] || { echo "Run as root (sudo)"; exit 1; }; }
log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }
need_root

log "Stopping runner services…"
systemctl stop 'github-runner@*' 2>/dev/null || true

log "Deregistering runners (best effort)…"
if ls /opt/actions-runner >/dev/null 2>&1; then
  for d in /opt/actions-runner/*; do
    [[ -d "$d" ]] || continue
    if [[ -x "$d/config.sh" ]]; then
      sudo -u github-runner bash -lc "cd '$d' && ./config.sh remove --unattended" || true
    fi
    rm -f "$d/.runner" || true
  done
fi

log "Disabling and removing unit files…"
for u in $(systemctl list-unit-files 'github-runner@*' --no-legend 2>/dev/null | awk '{print $1}'); do
  systemctl disable "$u" 2>/dev/null || true
done
rm -rf /etc/systemd/system/github-runner@.service.d
rm -f /etc/systemd/system/github-runner@.service
systemctl daemon-reload
systemctl reset-failed

log "Removing runner data…"
rm -rf /opt/actions-runner
rm -rf /var/lib/github-runner

if [[ "${LEAVE_CONFIG:-0}" != "1" ]]; then
  rm -rf /etc/github-runner
fi

if [[ "${KEEP_USER:-0}" != "1" ]]; then
  id -u github-runner >/dev/null 2>&1 && userdel -r github-runner || true
  getent group github-runner >/dev/null 2>&1 && groupdel github-runner || true
fi

log "[OK] Uninstall complete."
