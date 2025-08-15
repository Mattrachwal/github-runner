#!/usr/bin/env bash
set -Eeuo pipefail

USER="github-runner"
GROUP="github-runner"

log() { printf "[%(%F %T)T] %s\n" -1 "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

# 1) Ensure group
if ! getent group "$GROUP" >/dev/null; then
  log "Creating system group $GROUP"
  groupadd --system "$GROUP"
fi

# 2) Ensure user (system, no login)
if ! id -u "$USER" >/dev/null 2>&1; then
  log "Creating system user $USER"
  useradd --system --create-home --shell /usr/sbin/nologin --gid "$GROUP" "$USER"
else
  # Normalize shell & primary group
  chsh -s /usr/sbin/nologin "$USER" || true
  usermod -g "$GROUP" "$USER" || true
fi

# 3) Ensure runner dirs
install -d -o "$USER" -g "$GROUP" -m 0750 /opt/actions-runner
install -d -o "$USER" -g "$GROUP" -m 0750 /var/lib/github-runner

# 4) Optional: add to docker group if present AND requested
if [[ "${WITH_DOCKER:-0}" == "1" ]] && getent group docker >/dev/null; then
  log "Adding $USER to docker group (grants root-equivalent via /var/run/docker.sock)"
  usermod -aG docker "$USER" || true
fi

# 5) Show result
log "User: $(id $USER)"
log "Dirs:"
ls -ld /opt/actions-runner /var/lib/github-runner
