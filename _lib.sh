#!/usr/bin/env bash
set -Eeuo pipefail
umask 027

log()  { printf "[%(%F %T)T] %s\n" -1 "$*"; }
die()  { printf "ERROR: %s\n" "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }
have_cmd()  { command -v "$1" >/dev/null 2>&1; }

# Repo + config
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd 2>/dev/null || pwd)"
CFG_PATH_LOCAL="$REPO_ROOT/config.json"
CFG_PATH_ETC="/etc/github-runner/config.json"

copy_config_if_present() {
  if [[ -f "$CFG_PATH_LOCAL" ]]; then
    install -d -m 0755 /etc/github-runner
    install -m 0640 "$CFG_PATH_LOCAL" "$CFG_PATH_ETC"
    chown root:root "$CFG_PATH_ETC"
    log "Copied config.json to $CFG_PATH_ETC"
  fi
  [[ -f "$CFG_PATH_ETC" ]] || die "config.json not found. Put it in repo root or at $CFG_PATH_ETC"
}

ensure_base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y \
    curl ca-certificates jq tar xz-utils gzip coreutils \
    apt-transport-https gnupg lsb-release \
    build-essential unzip git \
    ufw fail2ban unattended-upgrades

  dpkg-reconfigure -plow unattended-upgrades || true

  # Firewall baseline: allow SSH, enable UFW (best effort)
  ufw allow OpenSSH || true
  ufw --force enable || true
}

ensure_docker_if_requested() {
  local WANT="${WITH_DOCKER:-0}"
  if [[ "$WANT" == "1" ]]; then
    log "Installing Docker Engine (requested)"
    if ! have_cmd docker; then
      apt-get install -y ca-certificates curl gnupg
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update -y
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      systemctl enable --now docker
    fi
    docker --version || die "Docker installation failed."
    log "Docker installed. Note: docker group grants root-equivalent power."
  else
    log "Skipping Docker Engine install (WITH_DOCKER=1 to enable)."
  fi
}

ensure_user_dirs() {
  # System user with no login
  if ! id -u github-runner >/dev/null 2>&1; then
    useradd --system --create-home --shell /usr/sbin/nologin --user-group github-runner
  else
    chsh -s /usr/sbin/nologin github-runner || true
  fi
  install -d -o github-runner -g github-runner -m 0750 /opt/actions-runner
  install -d -o github-runner -g github-runner -m 0750 /var/lib/github-runner
}

install_unit_and_override() {
  # Install the base unit from config file
  if [[ -f "$REPO_ROOT/config/systemd/github-runner@.service" ]]; then
    install -m 0644 "$REPO_ROOT/config/systemd/github-runner@.service" /etc/systemd/system/
    log "Installed base unit from config/systemd/github-runner@.service"
  else
    # Fallback: create base unit
    tee /etc/systemd/system/github-runner@.service >/dev/null <<'UNIT'
[Unit]
Description=GitHub Actions Runner %i
Wants=network-online.target
After=network-online.target

[Service]
User=github-runner
Group=github-runner
WorkingDirectory=/opt/actions-runner/%i
ExecStart=/bin/bash -lc 'cd /opt/actions-runner/%i && ./run.sh --startuptype service'
KillMode=process
Restart=always
RestartSec=5

# Baseline hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
LockPersonality=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
UNIT
    log "Created fallback base unit"
  fi

  systemctl daemon-reload
}

write_home_override_isolated() {
  # Install the override from config file or create one
  install -d -m 0755 /etc/systemd/system/github-runner@.service.d
  
  if [[ -f "$REPO_ROOT/config/systemd/override.conf" ]]; then
    # Use the config file but ensure it has the critical ExecStart fix
    cp "$REPO_ROOT/config/systemd/override.conf" /etc/systemd/system/github-runner@.service.d/override.conf
    
    # Check if the override.conf clears ExecStart (critical for HOME to work)
    if ! grep -q "ExecStart=$" /etc/systemd/system/github-runner@.service.d/override.conf; then
      log "WARNING: override.conf doesn't clear ExecStart. Adding fix..."
      # Add the ExecStart fix to the existing override
      cat >> /etc/systemd/system/github-runner@.service.d/override.conf <<'EOF'

# CRITICAL FIX: Clear and replace ExecStart to remove -l flag
ExecStart=
ExecStart=/bin/bash -c 'cd /opt/actions-runner/%i && exec ./run.sh --startuptype service'
EOF
    fi
    log "Installed override from config/systemd/override.conf (with fix applied)"
  else
    # Create override from scratch
    cat > /etc/systemd/system/github-runner@.service.d/override.conf <<'EOF'
[Service]
# Set per-instance HOME environment
Environment=HOME=/var/lib/github-runner/%i
Environment=USER=github-runner
Environment=LOGNAME=github-runner
Environment=GIT_CONFIG_GLOBAL=/dev/null
Environment=GIT_CONFIG_SYSTEM=/dev/null

# Clear base ExecStart and replace without -l flag
ExecStart=
ExecStart=/bin/bash -c 'cd /opt/actions-runner/%i && exec ./run.sh --startuptype service'
EOF
    log "Created override.conf from scratch"
  fi
  
  systemctl daemon-reload
  log "Installed per-instance HOME drop-in (override.conf)."
}

ensure_instance_home_envs() {
  # Create home directories and ensure they have proper setup
  have_cmd jq || apt-get update -y >/dev/null 2>&1 || true
  have_cmd jq || apt-get install -y jq >/dev/null 2>&1 || true
  [[ -f "$CFG_PATH_ETC" ]] || die "config.json not found at $CFG_PATH_ETC"

  jq -r '.runners[] | "\(.name)\t\(.instances)"' "$CFG_PATH_ETC" | \
  while IFS=$'\t' read -r name count; do
    [[ -n "$name" && "$count" =~ ^[0-9]+$ ]] || continue
    for n in $(seq 1 "$count"); do
      inst="${name}-${n}"
      homedir="/var/lib/github-runner/${inst}"
      
      # Ensure the home directory exists with correct permissions
      install -d -o github-runner -g github-runner -m 0750 "$homedir"
      
      # Create XDG directories
      install -d -o github-runner -g github-runner -m 0750 "$homedir/.config"
      install -d -o github-runner -g github-runner -m 0750 "$homedir/.local"
      install -d -o github-runner -g github-runner -m 0750 "$homedir/.local/share"
      install -d -o github-runner -g github-runner -m 0750 "$homedir/.cache"
      
      # Create a basic .gitconfig to prevent access issues
      gitconfig="$homedir/.gitconfig"
      if [[ ! -f "$gitconfig" ]]; then
        cat > "$gitconfig" <<'GITCONFIG'
[user]
	name = GitHub Runner
	email = runner@localhost
[safe]
	directory = *
[init]
	defaultBranch = main
[core]
	autocrlf = input
GITCONFIG
        chown github-runner:github-runner "$gitconfig"
        chmod 0644 "$gitconfig"
      fi
      
      # Create a .bashrc that reinforces the HOME setting
      bashrc="$homedir/.bashrc"
      if [[ ! -f "$bashrc" ]]; then
        cat > "$bashrc" <<EOF
# GitHub Runner .bashrc
export HOME="$homedir"
export USER="github-runner"
export LOGNAME="github-runner"
export XDG_CONFIG_HOME="$homedir/.config"
export XDG_DATA_HOME="$homedir/.local/share"
export XDG_CACHE_HOME="$homedir/.cache"
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

# Add common paths
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
        chown github-runner:github-runner "$bashrc"
        chmod 0644 "$bashrc"
      fi
    done
  done

  log "Ensured HOME dirs, XDG dirs, .gitconfig, and .bashrc files for all instances."
}

assert_unit_execstart_uses_runsh() {
  local unit="github-runner@.service"
  if ! systemctl cat "$unit" 2>/dev/null \
       | grep -q "ExecStart=.*/bin/bash .*run\.sh --startuptype service"; then
    die "Unit $unit isn't configured to use run.sh. Re-run install.sh to write the override."
  fi
}

latest_runner_url() {
  # Latest Linux x64 runner archive URL
  local api="https://api.github.com/repos/actions/runner/releases/latest"
  curl -fsSL "$api" \
    | jq -r '.assets[] | select(.name | test("linux-x64.*\\.tar\\.gz$")) | .browser_download_url' \
    | head -n1
}

mask_token() {
  sed -E 's/("registration_token":\s*")[^"]+/\1********/g'
}