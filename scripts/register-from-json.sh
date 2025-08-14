#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/_lib.sh"

# Behavior flags:
#   FORCE_REREG=1   -> stop/remove existing registration and re-register with current token
#   DOWNLOAD_RETRIES -> override retry count for downloads (default: 4)
FORCE_REREG="${FORCE_REREG:-0}"
DOWNLOAD_RETRIES="${DOWNLOAD_RETRIES:-4}"

need_root
have_cmd jq || apt-get install -y jq >/dev/null

[[ -f "$CFG_PATH_ETC" ]] || die "config.json missing at $CFG_PATH_ETC. Run install.sh or place it manually."

COUNT="$(jq '.runners | length' "$CFG_PATH_ETC")"
(( COUNT > 0 )) || die "No runners defined in config.json"

# ---- helpers ----

retry_curl() {
  local url="$1" out="$2" tries="$DOWNLOAD_RETRIES"
  local i=1
  while :; do
    if curl -fsSL "$url" -o "$out"; then
      return 0
    fi
    if (( i >= tries )); then
      return 1
    fi
    sleep $(( i * 2 ))
    i=$(( i + 1 ))
  done
}

ensure_extracted() {
  # args: RUN_DIR ARCHIVE_URL INST_NAME
  local RUN_DIR="$1" ARCHIVE_URL="$2" INST_NAME="$3"
  local TAR="$RUN_DIR/runner.tgz"

  # If config.sh exists, we assume extraction is already done
  if [[ -x "$RUN_DIR/config.sh" && -x "$RUN_DIR/run.sh" && -x "$RUN_DIR/bin/installdependencies.sh" ]]; then
    return 0
  fi

  log "Downloading runner tarball for $INST_NAME…"
  install -d -o github-runner -g github-runner -m 0750 "$RUN_DIR"
  if ! retry_curl "$ARCHIVE_URL" "$TAR"; then
    die "Failed to download runner tarball after $DOWNLOAD_RETRIES attempts: $ARCHIVE_URL"
  fi

  log "Extracting runner for $INST_NAME…"
  tar -xzf "$TAR" -C "$RUN_DIR"
  rm -f "$TAR"
  chown -R github-runner:github-runner "$RUN_DIR"

  # Validate expected files
  [[ -x "$RUN_DIR/config.sh" ]] || die "Extraction failed: missing $RUN_DIR/config.sh"
  [[ -x "$RUN_DIR/run.sh" ]] || die "Extraction failed: missing $RUN_DIR/run.sh"
  [[ -x "$RUN_DIR/bin/installdependencies.sh" ]] || die "Extraction failed: missing $RUN_DIR/bin/installdependencies.sh"
}

need_runtime_libs() {
  # Return 0 (true) if any required runtime libs are missing.
  # Checks are intentionally broad across Debian 12/13 names.
  local missing=0
  local have_icu=0
  if ldconfig -p | grep -qiE 'libicu(uc|i18n)'; then have_icu=1; fi

  local have_ssl=0
  if ldconfig -p | grep -qiE 'libssl\.so\.3'; then have_ssl=1; fi

  local have_zlib=0
  if ldconfig -p | grep -qiE 'libz\.so\.'; then have_zlib=1; fi

  local have_krb5=0
  if ldconfig -p | grep -qiE 'libkrb5\.so\.'; then have_krb5=1; fi

  (( have_icu && have_ssl && have_zlib && have_krb5 )) || return 0
  return 1
}

install_runner_deps_if_needed() {
  # args: RUN_DIR INST_NAME
  local RUN_DIR="$1" INST_NAME="$2" MARK="$RUN_DIR/.deps_installed"

  # If marker exists but libs are missing (e.g., partial/failed prior run), force reinstall.
  if [[ -f "$MARK" ]] && need_runtime_libs; then
    log "Deps marker exists but required libs missing for $INST_NAME — re-installing…"
    rm -f "$MARK"
  fi

  # If everything already present and marker exists, skip.
  if [[ -f "$MARK" ]] && ! need_runtime_libs; then
    return 0
  fi

  log "Installing OS deps for $INST_NAME (root)…"
  # Run GitHub’s helper (handles dotnet/icu pre-reqs for the runner)
  bash -lc "cd '$RUN_DIR' && ./bin/installdependencies.sh" || true

  # Refresh APT and install the usual suspects.
  apt-get update -y || true

  # Figure out the best libicu package available on this host (Debian 12=72, Debian 13=74, etc.)
  ICU_PKG="$(apt-cache search -n '^libicu[0-9]+$' | awk '{print $1}' | sort -V | tail -n1 || true)"
  if [[ -z "$ICU_PKG" ]]; then
    # Fallback to dev package if no versioned runtime found in cache
    ICU_PKG="libicu-dev"
  fi

  apt-get install -y "$ICU_PKG" libssl3 zlib1g libkrb5-3 curl || true

  # Final verification — only stamp the marker if libs are now present.
  if need_runtime_libs; then
    die "Required runtime libraries still missing after install for $INST_NAME. Check APT output above."
  fi

  touch "$MARK"
  chown github-runner:github-runner "$MARK"
}

remove_registration_if_present() {
  # args: RUN_DIR UNIT INST_NAME
  local RUN_DIR="$1" UNIT="$2" INST_NAME="$3"
  if [[ -f "$RUN_DIR/.runner" ]]; then
    log "Stopping unit and removing existing registration for $INST_NAME…"
    systemctl stop "$UNIT" || true
    sudo -u github-runner bash -lc "cd '$RUN_DIR' && ./config.sh remove --unattended || true"
    rm -f "$RUN_DIR/.runner"
  fi
}

register_instance() {
  # args: RUN_DIR WORK_DIR SCOPE_URL TOKEN LABELS INST_NAME
  local RUN_DIR="$1" WORK_DIR="$2" SCOPE_URL="$3" TOKEN="$4" LABELS="$5" INST_NAME="$6"
  install -d -o github-runner -g github-runner -m 0750 "$WORK_DIR"
  sudo -u github-runner bash -lc "cd '$RUN_DIR' && \
    ./config.sh --unattended \
      --url '$SCOPE_URL' \
      --token '$TOKEN' \
      --name '$INST_NAME' \
      --labels '$LABELS' \
      --work '$WORK_DIR'"
}

start_or_restart_unit() {
  local UNIT="$1"
  if systemctl is-enabled --quiet "$UNIT"; then
    systemctl restart "$UNIT"
  else
    systemctl enable --now "$UNIT"
  fi
}

# ---- main ----

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
    UNIT="github-runner@${INST_NAME}.service"

    log "Configuring instance: $INST_NAME (scope: $SCOPE_URL, labels: $LABELS)"
    install -d -o github-runner -g github-runner -m 0750 "$RUN_DIR" "$WORK_DIR"
    install -d -o github-runner -g github-runner -m 0750 "/var/lib/github-runner/${INST_NAME}"

    # Ensure runner files are present and valid
    ensure_extracted "$RUN_DIR" "$ARCHIVE_URL" "$INST_NAME"

    # Ensure OS dependencies for the runner are installed (root)
    install_runner_deps_if_needed "$RUN_DIR" "$INST_NAME"

    # Re-registration logic
    if [[ "$FORCE_REREG" == "1" ]]; then
      remove_registration_if_present "$RUN_DIR" "$UNIT" "$INST_NAME"
    fi

    # Configure if not registered
    if [[ ! -f "$RUN_DIR/.runner" ]]; then
      register_instance "$RUN_DIR" "$WORK_DIR" "$SCOPE_URL" "$TOKEN" "$LABELS" "$INST_NAME"
    fi

    # Start/restart service
    start_or_restart_unit "$UNIT"
  done
done

log "All runner instances configured and started."
