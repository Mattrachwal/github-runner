#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../_lib.sh"

# Update all installed runner instances to the latest runner tarball in-place.
# Keeps registration intact and restarts services.

need_root

ARCHIVE_URL="$(latest_runner_url)"
[[ -n "$ARCHIVE_URL" ]] || die "Could not determine latest GitHub runner download URL."
log "Latest actions runner archive: $ARCHIVE_URL"

update_instance_dir() {
  local RUN_DIR="$1" name="$2" TAR="$RUN_DIR/runner.tgz"
  log "Updating $name…"
  retry_curl() {
    local url="$1" out="$2" tries="${DOWNLOAD_RETRIES:-4}" i=1
    while :; do
      if curl -fsSL "$url" -o "$out"; then return 0; fi
      (( i >= tries )) && return 1
      sleep $(( i * 2 )); i=$(( i + 1 ))
    done
  }
  install -d -o github-runner -g github-runner -m 0750 "$RUN_DIR"
  retry_curl "$ARCHIVE_URL" "$TAR" || die "Download failed for $name"
  tar -xzf "$TAR" -C "$RUN_DIR"
  rm -f "$TAR"
  chown -R github-runner:github-runner "$RUN_DIR"
}

shopt -s nullglob
dirs=(/opt/actions-runner/*)
(( ${#dirs[@]} )) || die "No runner instances found under /opt/actions-runner"

for d in "${dirs[@]}"; do
  inst="$(basename "$d")"
  [[ -x "$d/run.sh" ]] || continue
  update_instance_dir "$d" "$inst"
done

systemctl restart 'github-runner@*' || true
log "[OK] Update complete."
