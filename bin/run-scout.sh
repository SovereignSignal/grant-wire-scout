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

# 0. opt-in skip when the other lane just fed this wire (saves Max/SuperGrok on
#    saturated ticks). Unset/0 = always run. Exit 10 = skip; anything else runs.
python3 "$ROOT/lib/skip_if_fed.py" "$WIRE"; skip_rc=$?
if [ "$skip_rc" -eq 10 ]; then
  TODAY_TS="$(date -u +%Y-%m-%dT%H%M%SZ)"
  PRODUCER="$([ "$ENGINE" = grok ] && echo grok-build || echo claude-code)"
  run_dir="$ROOT/runs/$WIRE/$VARIANT/${PRODUCER}-${TODAY_TS}-skipped"
  mkdir -p "$run_dir"
  python3 - "$run_dir" "$WIRE" "$VARIANT" "$MODEL" "$ENGINE" "$PRODUCER" <<'PY'
import json, os, sys, datetime
run_dir, wire, variant, model, engine, producer = sys.argv[1:7]
meta = {
  "run_id": os.path.basename(run_dir),
  "wire": wire, "variant": variant, "model": model,
  "engine": engine, "producer": producer,
  "generated_at": datetime.datetime.utcnow().isoformat() + "Z",
  "opportunity_count": 0, "found_count": 0, "dedup_dropped": 0,
  "avg_fit_score": None, "cost_usd": 0, "duration_ms": 0,
}
open(f"{run_dir}/meta.json", "w").write(json.dumps(meta, indent=2))
print(json.dumps(meta, indent=2))
PY
  echo "RUN_DIR=$run_dir"
  ledger skipped skipped-fed
  echo "[run-scout] skipped ($LANE $WIRE/$VARIANT) — other lane already fed this wire"
  exit 0
fi
if [ "$skip_rc" -eq 2 ]; then
  echo "[run-scout] skip_if_fed misconfigured — running anyway" >&2
fi

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
