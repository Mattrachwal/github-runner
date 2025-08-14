#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/_lib.sh"

need_root
log "Re-applying unit template and drop-in..."
install_unit_and_override

log "Restarting all GitHub runner instances (if any)..."
systemctl list-units --type=service \
  | awk '/github-runner@.*\.service/ {print $1}' \
  | xargs -r -n1 systemctl restart

log "Done."
