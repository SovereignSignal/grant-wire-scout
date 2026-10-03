#!/usr/bin/env bash
# ensure-grok-cli.sh — log the Grok CLI version and move it to the latest stable build.
#
# Called before each Grok wire. A failed update is logged and this script still exits 0
# so the hunt runs on whatever binary is already installed. Claude is not handled here.
#
# GROK_CLI_UPDATE_TIMEOUT  seconds for the update and for the install-script fallback (default 120)
# GROK_CLI_FORCE_UPDATE=1  pass `grok update --force-reinstall` (the one 426 retry)
# GROK_CLI_INSTALL_CMD     override the install-script fallback (tests). Unset uses
#                          https://x.ai/cli/install.sh with no version argument.
# GROK                     binary to update (default: grok on PATH)
set -uo pipefail

BIN="${GROK:-grok}"
TIMEOUT_SECS="${GROK_CLI_UPDATE_TIMEOUT:-120}"
if ! [[ "$TIMEOUT_SECS" =~ ^[0-9]+$ ]] || [ "$TIMEOUT_SECS" -lt 1 ]; then
  echo "[grok] cli update: GROK_CLI_UPDATE_TIMEOUT='${TIMEOUT_SECS}' is not a positive integer — using 120" >&2
  TIMEOUT_SECS=120
fi

if [ ! -x "$BIN" ] && ! command -v "$BIN" >/dev/null 2>&1; then
  echo "[grok] cli version unknown — grok binary not found ($BIN)" >&2
  exit 0
fi

run_timeout() {  # run_timeout <seconds> <cmd...>
  local dur="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$dur" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 5 "$dur" "$@"
  else
    echo "[grok] cli update: no timeout binary — running uncapped" >&2
    "$@"
  fi
}

semver_of() {
  printf '%s\n' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

read_version() {
  local out v
  out="$(run_timeout 15 "$BIN" version 2>/dev/null || true)"
  v="$(semver_of "$out")"
  if [ -z "$v" ]; then
    out="$(run_timeout 15 "$BIN" --version 2>/dev/null || true)"
    v="$(semver_of "$out")"
  fi
  printf '%s' "$v"
}

before="$(read_version)"
echo "[grok] cli version ${before:-unknown}"

update_args=(update)
if [ "${GROK_CLI_FORCE_UPDATE:-0}" = "1" ]; then
  update_args=(update --force-reinstall)
fi

# GROK_DISABLE_AUTOUPDATER stays set for the hunt so a background check cannot
# stall `grok -p`. The explicit update must not inherit that suppression.
update_rc=0
(
  unset GROK_DISABLE_AUTOUPDATER
  run_timeout "$TIMEOUT_SECS" "$BIN" "${update_args[@]}"
) || update_rc=$?

if [ "$update_rc" -ne 0 ]; then
  echo "[grok] cli update failed (rc=${update_rc}) — trying the install script" >&2
  install_rc=0
  (
    unset GROK_DISABLE_AUTOUPDATER
    if [ -n "${GROK_CLI_INSTALL_CMD:-}" ]; then
      run_timeout "$TIMEOUT_SECS" bash -c "$GROK_CLI_INSTALL_CMD"
    else
      # Latest stable. No version argument — a pin is what aged out on 2026-10-01.
      run_timeout "$TIMEOUT_SECS" bash -c "curl -fsSL --max-time ${TIMEOUT_SECS} https://x.ai/cli/install.sh | bash"
    fi
  ) || install_rc=$?
  if [ "$install_rc" -ne 0 ]; then
    echo "[grok] cli update failed — install script also failed (rc=${install_rc}). Continuing with the CLI already on PATH." >&2
    exit 0
  fi
fi

after="$(read_version)"
if [ -n "$after" ] && [ "$after" != "${before:-}" ]; then
  echo "[grok] cli version ${after}"
else
  echo "[grok] cli update ok (${after:-${before:-unknown}})"
fi
exit 0
