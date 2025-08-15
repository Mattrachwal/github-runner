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
  # Base unit (no ExecStart here; we force it via drop-in)
  if [[ ! -f /etc/systemd/system/github-runner@.service ]]; then
    tee /etc/systemd/system/github-runner@.service >/dev/null <<'UNIT'
[Unit]
Description=GitHub Actions Runner %i
Wants=network-online.target
After=network-online.target

[Service]
User=github-runner
Group=github-runner
WorkingDirectory=/opt/actions-runner/%i
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
  fi

  # Drop-in override: noexec-safe ExecStart that runs run.sh via bash
  install -d -m 0755 /etc/systemd/system/github-runner@.service.d
  tee /etc/systemd/system/github-runner@.service.d/override.conf >/dev/null <<'OVERRIDE'
[Service]
WorkingDirectory=/opt/actions-runner/%i
ExecStart=
ExecStart=/bin/bash -lc 'cd /opt/actions-runner/%i && exec /bin/bash run.sh --startuptype service'
OVERRIDE

  systemctl daemon-reload
}

write_home_override_isolated() {
  # Create a drop-in that ensures the per-instance HOME exists, loads it,
  # and then *exports HOME* in ExecStart before launching run.sh.
  install -d -m 0755 /etc/systemd/system/github-runner@.service.d
  cat > /etc/systemd/system/github-runner@.service.d/override.conf <<'EOF'
[Service]
PermissionsStartOnly=true

# Ensure per-instance HOME dir exists (runs as root even though User=github-runner)
ExecStartPre=/usr/bin/install -d -o github-runner -g github-runner -m 0750 /var/lib/github-runner/%i

# Load HOME from /etc/default/github-runner/home-%i (written by installer)
EnvironmentFile=-/etc/default/github-runner/home-%i

# Optional: block reading any global git config
Environment=GIT_CONFIG_GLOBAL=/dev/null

# Clear base ExecStart and replace with one that exports HOME explicitly
ExecStart=
ExecStart=/bin/bash -lc 'export HOME="${HOME:-/var/lib/github-runner/%i}"; cd /opt/actions-runner/%i && exec ./run.sh --startuptype service'
EOF
  systemctl daemon-reload
  log "Installed per-instance HOME drop-in (override.conf)."
}

ensure_instance_home_envs() {
  # Create /etc/default/github-runner/home-<instance> files and ensure dirs exist
  have_cmd jq || apt-get update -y >/dev/null 2>&1 || true
  have_cmd jq || apt-get install -y jq >/dev/null 2>&1 || true
  [[ -f "$CFG_PATH_ETC" ]] || die "config.json not found at $CFG_PATH_ETC"

  install -d -m 0755 /etc/default/github-runner

  jq -r '.runners[] | "\(.name)\t\(.instances)"' "$CFG_PATH_ETC" | \
  while IFS=$'\t' read -r name count; do
    [[ -n "$name" && "$count" =~ ^[0-9]+$ ]] || continue
    for n in $(seq 1 "$count"); do
      inst="${name}-${n}"
      homedir="/var/lib/github-runner/${inst}"
      envfile="/etc/default/github-runner/home-${inst}"
      install -d -o github-runner -g github-runner -m 0750 "$homedir"
      printf 'HOME=%s\n' "$homedir" > "$envfile"
      chmod 0644 "$envfile"
    done
  done

  log "Ensured HOME dirs and env files for all instances."
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
