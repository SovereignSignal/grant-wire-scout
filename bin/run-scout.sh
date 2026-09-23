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
  # rc=124 is GNU timeout — classify BEFORE reading raw.json, which is often empty or
  # truncated and would otherwise land as OTHER/FAILED.
  if [ "$rc" -eq 124 ]; then
    cls=TIMEOUT
  else
    cls="$(python3 "$ROOT/lib/classify_failure.py" "$run_dir/raw.json" 2>/dev/null || echo OTHER)"
  fi
  case "$cls" in
    AUTH)    subj="⚠️ Grant Wire Scout AUTH — ${LANE} credentials rejected ($WIRE/$VARIANT); $AUTH_HINT"
             hint="The CLI rejected its credentials. $AUTH_HINT. The hydrate_grok_auth lines below (Grok) say whether the on-disk token was live or expired." ;;
    QUOTA)   subj="⚠️ Grant Wire Scout QUOTA — ${LANE} usage cap hit ($WIRE/$VARIANT)"
             hint="The subscription's usage cap was hit. Nothing to rotate; the lane tries again on its next cron. Look only if it repeats across ticks." ;;
    EMPTY)   subj="⚠️ Grant Wire Scout EMPTY — ${LANE} produced no usable output ($WIRE/$VARIANT)"
             hint="The model finished but returned no usable JSON (on Grok, usually the per-response output cap on the final turn; the producer already retried once at low reasoning effort). raw.json / raw.attempt1.json in the run dir hold what came back." ;;
    TIMEOUT) subj="⚠️ Grant Wire Scout TIMEOUT — ${LANE} hit the wall-clock cap ($WIRE/$VARIANT)"
             hint="The hunt ran past SCOUT_PRODUCER_TIMEOUT (${SCOUT_PRODUCER_TIMEOUT:-2400}s). Both CLIs write their JSON only when they finish, so raw.json is empty after a kill; the wrapper resumed the killed session and asked it to flush what it had verified — the [producer] TIMEOUT lines below say what came back. If this repeats on the same wire, that wire's hunt does not fit the cap: it is usually a thin wire primed at the SCOUT_KNOWN_LIMIT cap (see the 'primed with' line). Lower SCOUT_KNOWN_LIMIT for that lane, or raise SCOUT_PRODUCER_TIMEOUT." ;;
    *)       subj="⚠️ Grant Wire Scout FAILED ($LANE $WIRE/$VARIANT, rc=$rc)"
             hint="Unclassified failure — read the run log tail below. raw.json and producer.stderr in the run dir hold the CLI's output." ;;
  esac
  {
    echo "$LANE · $WIRE/$VARIANT · model=$MODEL · $cls (rc=$rc) · $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "run_dir: ${run_dir:-?}"
    echo
    echo "$hint"
    echo
    echo "--- last 40 lines of the run log ---"
    printf '%s\n' "$out" | tail -40
  } | alert "$subj"
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
