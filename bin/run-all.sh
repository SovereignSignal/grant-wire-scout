#!/usr/bin/env bash
# run-all.sh — one scout cron tick. Runs each wire (variant A by default) via run-scout.sh,
# which self-alerts on failure. Continues past a failing wire so one bad wire can't block the
# others. Configurable: SCOUT_WIRES (default "crypto ai oss"), SCOUT_VARIANT (default A).
# Start conservative by setting SCOUT_WIRES="crypto" until you trust it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Safety guard: the scout calls `claude -p`, which needs CLAUDE_CODE_OAUTH_TOKEN. This image is
# SHARED with the heartbeat service, whose command should be `python3 lib/heartbeat.py` — not this.
# If a tokenless service is ever misrouted here (e.g. a Railway start-command override that silently
# loses to the Docker CMD), running the producer would only fail AUTH on every wire and spam ops
# alerts. Refuse cleanly instead. exit 0 because a no-op is healthy, not a failure.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "[run-all] no CLAUDE_CODE_OAUTH_TOKEN — not the scout service; skipping the producer (clean no-op)." >&2
  exit 0
fi

# A/B experiment: run BOTH variants per wire so promotion rates are comparable downstream.
# The Wire Room stores prompt_variant per entry, so A vs B is scorable (see bin/ab-score.sh).
# SCOUT_VARIANTS overrides; a legacy single SCOUT_VARIANT is still honored. NOTE: two variants
# DOUBLES the per-wire cost — each run is bounded by the producer wall-clock timeout +
# SCOUT_MAX_TURNS. Set SCOUT_VARIANTS=A to run a single arm.
VARIANTS="${SCOUT_VARIANTS:-${SCOUT_VARIANT:-A B}}"
WIRES="${SCOUT_WIRES:-crypto ai oss}"

rc=0
for w in $WIRES; do
  for v in $VARIANTS; do
    "$ROOT/bin/run-scout.sh" "$w" "$v" || rc=1
  done
done
exit "$rc"
