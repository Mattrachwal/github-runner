#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/_lib.sh"
need_root

log "Runner binaries are tarballs, not apt packages."
log "To update existing instances: stop an instance, remove its dir, re-register that instance."
log "To add new instances with the latest version: just run register-from-json.sh (it fetches latest)."
