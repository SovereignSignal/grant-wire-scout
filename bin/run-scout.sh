#!/usr/bin/env bash
# run-scout.sh — cron entrypoint. Run the scout for one wire+variant, deliver finds straight
# to the Wire Room queue, and email an ops alert ONLY on failure (silence = healthy).
#
# Usage: run-scout.sh <crypto|ai|oss> <A|B>
# Env: SCOUT_ENGINE (claude|grok, default claude); MODEL (Claude default claude-sonnet-4-6);
#      GROK_MODEL (Grok default grok-4.6); WIRE_ROOM_API + INTERNAL_API_KEY (delivery);
#      RESEND_API_KEY + NOTIFICATION_EMAIL + ALERT_FROM (alerts).
set -uo pipefail

WIRE="${1:?usage: run-scout.sh <wire> <variant>}"
VARIANT="${2:?usage: run-scout.sh <wire> <variant>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${SCOUT_ENGINE:-claude}"
TODAY="$(date -u +%Y-%m-%d)"

if [ "$ENGINE" = "grok" ]; then
  MODEL="${GROK_MODEL:-grok-4.6}"
  export SCOUT_SCAN_SOURCE="${SCOUT_SCAN_SOURCE:-grok-scout}"
  LANE="Grok Build"
  AUTH_HINT="refresh GROK_AUTH_JSON from \`grok login\` (~/.grok/auth.json) or set XAI_API_KEY"
else
  MODEL="${MODEL:-claude-sonnet-4-6}"
  export SCOUT_SCAN_SOURCE="${SCOUT_SCAN_SOURCE:-claude-code}"
  LANE="Claude Code"
  AUTH_HINT="run: claude setup-token"
fi
export MODEL

# email an alert; body comes on stdin. A failed alert must not crash the run.
alert() { python3 "$ROOT/lib/notify.py" "$1" || echo "[run-scout] ALERT SEND FAILED: $1" >&2; }
# record the run outcome in the durable scout_runs ledger (M8; best-effort, needs DATABASE_URL)
ledger() { python3 "$ROOT/lib/ledger.py" "$run_dir" "$1" "${2:-}" || true; }

# 1. discover -> verify -> report
out="$("$ROOT/run-producer.sh" --wire "$WIRE" --variant "$VARIANT" --engine "$ENGINE" --model "$MODEL" 2>&1)"; rc=$?
printf '%s\n' "$out"
run_dir="$(printf '%s\n' "$out" | sed -n 's/^RUN_DIR=//p' | tail -1)"
run_dir="${run_dir%/}"
if [ -z "$run_dir" ]; then
  run_dir="$(ls -dt "$ROOT/runs/$WIRE/$VARIANT"/*/ 2>/dev/null | head -1)"
  run_dir="${run_dir%/}"
fi

if [ "$rc" -ne 0 ]; then
  cls="$(python3 "$ROOT/lib/classify_failure.py" "$run_dir/raw.json" 2>/dev/null || echo OTHER)"
  case "$cls" in
    AUTH)  subj="⚠️ Grant Wire Scout AUTH — ${LANE} credentials rejected ($WIRE/$VARIANT); $AUTH_HINT" ;;
    QUOTA) subj="⚠️ Grant Wire Scout QUOTA — ${LANE} usage cap hit ($WIRE/$VARIANT)" ;;
    EMPTY) subj="⚠️ Grant Wire Scout EMPTY — ${LANE} produced no usable output ($WIRE/$VARIANT)" ;;
    *)     subj="⚠️ Grant Wire Scout FAILED ($LANE $WIRE/$VARIANT, rc=$rc)" ;;
  esac
  printf '%s\n' "$out" | tail -25 | alert "$subj"
  ledger "$(printf '%s' "$cls" | tr 'A-Z' 'a-z')" "$cls"
  exit "$rc"
fi

# 2. deliver to the Wire Room queue
sub_out="$(python3 "$ROOT/lib/submit.py" "$run_dir/opportunities.json" "$WIRE" "$VARIANT" "$TODAY" 2>&1)"; src=$?
printf '%s\n' "$sub_out"
if [ "$src" -ne 0 ]; then
  printf '%s\n' "$sub_out" | alert "⚠️ Grant Wire Scout DELIVERY failed — couldn't post to the Wire Room queue ($LANE $WIRE/$VARIANT)"
  ledger delivery
  exit "$src"
fi

ledger ok
echo "[run-scout] ok ($LANE $WIRE/$VARIANT)"
