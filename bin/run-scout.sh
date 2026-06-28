#!/usr/bin/env bash
# run-scout.sh — cron entrypoint. Run the scout for one wire+variant, deliver finds straight
# to the Wire Room queue, and email an ops alert ONLY on failure (silence = healthy).
#
# Usage: run-scout.sh <crypto|ai|oss> <A|B>
# Env: MODEL (default claude-sonnet-4-6); WIRE_ROOM_API + INTERNAL_API_KEY (delivery);
#      RESEND_API_KEY + NOTIFICATION_EMAIL + ALERT_FROM (alerts).
set -uo pipefail

WIRE="${1:?usage: run-scout.sh <wire> <variant>}"
VARIANT="${2:?usage: run-scout.sh <wire> <variant>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export MODEL="${MODEL:-claude-sonnet-4-6}"
TODAY="$(date -u +%Y-%m-%d)"

# email an alert; body comes on stdin. A failed alert must not crash the run.
alert() { python3 "$ROOT/lib/notify.py" "$1" || echo "[run-scout] ALERT SEND FAILED: $1" >&2; }

# 1. discover -> verify -> report
out="$("$ROOT/run-producer.sh" --wire "$WIRE" --variant "$VARIANT" --model "$MODEL" 2>&1)"; rc=$?
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
    AUTH)  subj="⚠️ Grant Wire Scout AUTH — claude token rejected ($WIRE/$VARIANT); run: claude setup-token" ;;
    QUOTA) subj="⚠️ Grant Wire Scout QUOTA — Max usage cap hit ($WIRE/$VARIANT)" ;;
    EMPTY) subj="⚠️ Grant Wire Scout EMPTY — run produced no usable output ($WIRE/$VARIANT)" ;;
    *)     subj="⚠️ Grant Wire Scout FAILED ($WIRE/$VARIANT, rc=$rc)" ;;
  esac
  printf '%s\n' "$out" | tail -25 | alert "$subj"
  exit "$rc"
fi

# 2. deliver to the Wire Room queue
sub_out="$(python3 "$ROOT/lib/submit.py" "$run_dir/opportunities.json" "$WIRE" "$VARIANT" "$TODAY" 2>&1)"; src=$?
printf '%s\n' "$sub_out"
if [ "$src" -ne 0 ]; then
  printf '%s\n' "$sub_out" | alert "⚠️ Grant Wire Scout DELIVERY failed — couldn't post to the Wire Room queue ($WIRE/$VARIANT)"
  exit "$src"
fi

echo "[run-scout] ok ($WIRE/$VARIANT)"
