#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/_lib.sh"

need_root
have_cmd jq || apt-get install -y jq >/dev/null

[[ -f "$CFG_PATH_ETC" ]] || die "config.json missing at $CFG_PATH_ETC. Run install.sh or place it manually."

COUNT="$(jq '.runners | length' "$CFG_PATH_ETC")"
(( COUNT > 0 )) || die "No runners defined in config.json"

ARCHIVE_URL="$(latest_runner_url)"
[[ -n "$ARCHIVE_URL" ]] || die "Could not determine latest GitHub runner download URL."
log "Latest actions runner archive: $ARCHIVE_URL"

for i in $(seq 0 $((COUNT-1))); do
  RUNNER_JSON="$(jq -c ".runners[$i]" "$CFG_PATH_ETC")"
  echo "$RUNNER_JSON" | mask_token | sed 's/^/[runner] /'

  NAME="$(jq -r '.name' <<<"$RUNNER_JSON")"
  SCOPE_URL="$(jq -r '.scope_url' <<<"$RUNNER_JSON")"
  TOKEN="$(jq -r '.registration_token' <<<"$RUNNER_JSON")"
  LABELS="$(jq -r '.labels | join(",")' <<<"$RUNNER_JSON")"
  INSTANCES="$(jq -r '.instances' <<<"$RUNNER_JSON")"
  WORK_BASE="$(jq -r '.work_dir' <<<"$RUNNER_JSON")"

  [[ -n "$NAME" && -n "$SCOPE_URL" && -n "$TOKEN" && -n "$WORK_BASE" ]] \
    || die "Runner $i missing required fields (name/scope_url/token/work_dir)."

  [[ "$INSTANCES" =~ ^[0-9]+$ ]] || die "Runner $i 'instances' must be a number."

  for n in $(seq 1 "$INSTANCES"); do
    INST_NAME="${NAME}-${n}"
    RUN_DIR="/opt/actions-runner/${INST_NAME}"
    WORK_DIR="${WORK_BASE}-${n}"

    log "Configuring instance: $INST_NAME (scope: $SCOPE_URL, labels: $LABELS)"
    install -d -o github-runner -g github-runner -m 0750 "$RUN_DIR" "$WORK_DIR"
    install -d -o github-runner -g github-runner -m 0750 "/var/lib/github-runner/${INST_NAME}"

    # Download + extract runner if first time
    if [[ ! -x "${RUN_DIR}/run.sh" ]]; then
      TMP="/tmp/actions-runner-${INST_NAME}.tar.gz"
      curl -fsSL "$ARCHIVE_URL" -o "$TMP"
      tar -xzf "$TMP" -C "$RUN_DIR"
      chown -R github-runner:github-runner "$RUN_DIR"
      rm -f "$TMP"
      # Install dependencies script as runner user
      sudo -u github-runner bash -lc "cd '$RUN_DIR' && ./bin/installdependencies.sh"
    fi

    # Configure instance if not already done
    if [[ ! -f "${RUN_DIR}/.runner" ]]; then
      sudo -u github-runner bash -lc "cd '$RUN_DIR' && \
        ./config.sh --unattended \
          --url '$SCOPE_URL' \
          --token '$TOKEN' \
          --name '$INST_NAME' \
          --labels '$LABELS' \
          --work '$WORK_DIR'"
    fi

    # Enable + start systemd service
    systemctl enable --now "github-runner@${INST_NAME}.service"
  done
done

log "All runner instances configured and started."
