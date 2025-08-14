#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/_lib.sh"
need_root

log "Stopping & disabling all runner instances..."
systemctl list-units --type=service \
  | awk '/github-runner@.*\.service/ {print $1}' \
  | while read -r svc; do
      systemctl stop "$svc" || true
      systemctl disable "$svc" || true
    done

log "Removing systemd units..."
rm -f /etc/systemd/system/github-runner@.service
rm -rf /etc/systemd/system/github-runner@.service.d
systemctl daemon-reload

log "Removing runner data and user..."
rm -rf /opt/actions-runner /var/lib/github-runner
userdel github-runner 2>/dev/null || true

log "Uninstall complete."
