#!/bin/bash
set -euo pipefail

# Cleanup script for removing runners and configuration

CONFIG_FILE="${SCRIPT_DIR}/config.yml"
RUNNER_USER=$(yq eval '.system.runner_user' "$CONFIG_FILE")
GITHUB_ORG=$(yq eval '.github.org' "$CONFIG_FILE")
GITHUB_TOKEN=$(yq eval '.github.token' "$CONFIG_FILE")

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "Stopping runner service..."
systemctl stop github-runner-manager || true
systemctl disable github-runner-manager || true

log "Removing runners from GitHub..."
# Get all runners
RUNNERS=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners" | \
    jq -r '.runners[] | select(.name | startswith("ephemeral-runner")) | .id')

for runner_id in $RUNNERS; do
    log "Removing runner ID: $runner_id"
    curl -X DELETE -H "Authorization: token ${GITHUB_TOKEN}" \
        "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/${runner_id}"
done

log "Cleaning up Docker..."
docker-compose -f /home/${RUNNER_USER}/docker/docker-compose.yml down -v || true
docker system prune -af --volumes

log "Removing user files..."
rm -rf /home/${RUNNER_USER}/runners
rm -rf /home/${RUNNER_USER}/work
rm -rf /home/${RUNNER_USER}/docker

log "Cleanup complete!"