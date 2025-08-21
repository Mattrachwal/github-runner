#!/bin/bash
set -euo pipefail

CONFIG_FILE="${SCRIPT_DIR}/config.yml"
RUNNER_USER=$(yq eval '.system.runner_user' "$CONFIG_FILE")

log "Creating runner user: $RUNNER_USER"

# Create runner user if doesn't exist
if ! id "$RUNNER_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$RUNNER_USER"
    usermod -aG docker "$RUNNER_USER"
fi

# Setup sudoers for runner (limited permissions)
cat > /etc/sudoers.d/github-runner <<EOF
# Allow runner to manage docker
$RUNNER_USER ALL=(ALL) NOPASSWD: /usr/bin/docker
$RUNNER_USER ALL=(ALL) NOPASSWD: /usr/local/bin/docker-compose
$RUNNER_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart github-runner-manager
$RUNNER_USER ALL=(ALL) NOPASSWD: /bin/systemctl stop github-runner-manager
$RUNNER_USER ALL=(ALL) NOPASSWD: /bin/systemctl start github-runner-manager
EOF

# Create runner directories
RUNNER_HOME="/home/$RUNNER_USER"
mkdir -p "$RUNNER_HOME/runners"
mkdir -p "$RUNNER_HOME/work"
mkdir -p "$RUNNER_HOME/.docker"

# Copy Docker config if exists
if [[ -f /root/.docker/config.json ]]; then
    cp /root/.docker/config.json "$RUNNER_HOME/.docker/"
fi

# Set proper permissions
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"
chmod 700 "$RUNNER_HOME"
chmod 700 "$RUNNER_HOME/.docker"