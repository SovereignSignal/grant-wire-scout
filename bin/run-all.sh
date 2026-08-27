#!/usr/bin/env bash
# run-all.sh — one scout cron tick. Runs each wire (variant A by default) via run-scout.sh,
# which self-alerts on failure. Continues past a failing wire so one bad wire can't block the
# others. Configurable: SCOUT_WIRES (default "crypto ai oss"), SCOUT_VARIANT (default A).
# Default is a SINGLE arm. Unsetting SCOUT_VARIANT used to fall through to 'A B' and
# double the Max/SuperGrok quota overnight — do not restore that fallback.
# Start conservative by setting SCOUT_WIRES="crypto" until you trust it.
#
# Engine: SCOUT_ENGINE=claude (default, existing scout service) | grok (Grok Build lane).
# The Grok lane is a THIRD Railway service (bin/run-grok-all.sh) — this file stays the
# Claude entrypoint unless SCOUT_ENGINE/SERVICE_ROLE say otherwise.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENGINE="${SCOUT_ENGINE:-claude}"
ROLE="${SERVICE_ROLE:-scout}"

grok_auth_present() {
  [ -n "${GROK_AUTH_JSON:-}" ] && return 0
  [ -n "${XAI_API_KEY:-}" ] && return 0
  local home="${GROK_HOME:-${HOME:-/tmp}/.grok}"
  [ -s "$home/auth.json" ]
}

# Safety guard: this image is SHARED with the heartbeat (and now the Grok Build cron).
# A tokenless service misrouted here would AUTH-fail every wire and spam ops alerts.
# Refuse cleanly instead. Heartbeat (SERVICE_ROLE unset / not scout|grok-scout, no token)
# stays a clean no-op (exit 0).
if [ "$ENGINE" = "grok" ] || [ "$ROLE" = "grok-scout" ]; then
  if ! grok_auth_present; then
    echo "[run-all] SERVICE_ROLE=${ROLE} engine=grok but no Grok credentials — refusing loudly (set GROK_AUTH_JSON from \`grok login\`, contents of ~/.grok/auth.json, or XAI_API_KEY)." >&2
    exit 1
  fi
  # A grok-scout service that forgot SCOUT_ENGINE would otherwise invoke Claude.
  export SCOUT_ENGINE=grok
  export SCOUT_SCAN_SOURCE="${SCOUT_SCAN_SOURCE:-grok-scout}"
elif [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  # A scout with no token is a real misconfiguration — fail LOUD so it's visible, instead of
  # silently looking healthy (M10). Any other declared role (e.g. a tokenless service misrouted
  # to this command) is a clean no-op so it can't spam AUTH alerts. SERVICE_ROLE defaults to
  # 'scout' so a missing role errs on the side of visibility.
  if [ "$ROLE" = "scout" ]; then
    echo "[run-all] SERVICE_ROLE=scout but CLAUDE_CODE_OAUTH_TOKEN is missing — refusing loudly (run 'claude setup-token' and set it on the scout service)." >&2
    exit 1
  fi
  echo "[run-all] no CLAUDE_CODE_OAUTH_TOKEN and SERVICE_ROLE='${ROLE}' (not scout) — skipping (clean no-op)." >&2
  exit 0
fi

# A/B experiment: SCOUT_VARIANTS='A B' runs both arms so promotion rates are comparable
# (see bin/ab-score.sh). Production is variant A only — two arms double the Max/SuperGrok
# quota share. SCOUT_VARIANTS overrides; a legacy single SCOUT_VARIANT is still honored.
VARIANTS="${SCOUT_VARIANTS:-${SCOUT_VARIANT:-A}}"
WIRES="${SCOUT_WIRES:-crypto ai oss}"

rc=0
for w in $WIRES; do
  for v in $VARIANTS; do
    "$ROOT/bin/run-scout.sh" "$w" "$v" || rc=1
  done
done
exit "$rc"
