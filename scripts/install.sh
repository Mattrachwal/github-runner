#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../_lib.sh"

# Flags:
#   WITH_DOCKER=1 -> install Docker Engine too

need_root
copy_config_if_present
log "Installing base packages and hardening baseline..."
ensure_base
ensure_docker_if_requested
ensure_user_dirs
install_unit_and_override
write_home_override_isolated
ensure_instance_home_envs

log "Install complete. Next: register runner instances with ./scripts/register-from-json.sh"
