#!/usr/bin/env bash
# run-all.sh — one scout cron tick. Runs each wire (variant A by default) via run-scout.sh,
# which self-alerts on failure. Continues past a failing wire so one bad wire can't block the
# others. Configurable: SCOUT_WIRES (default "crypto ai oss"), SCOUT_VARIANT (default A).
# Start conservative by setting SCOUT_WIRES="crypto" until you trust it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="${SCOUT_VARIANT:-A}"
WIRES="${SCOUT_WIRES:-crypto ai oss}"

rc=0
for w in $WIRES; do
  "$ROOT/bin/run-scout.sh" "$w" "$VARIANT" || rc=1
done
exit "$rc"
