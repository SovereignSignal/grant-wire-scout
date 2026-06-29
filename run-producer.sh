#!/usr/bin/env bash
# run-producer.sh — invoke the Claude Code grant producer for one wire+variant.
#
# Usage:
#   ./run-producer.sh --wire crypto --variant A [--model claude-opus-4-8]
#
# What it does:
#   1. Renders prompts/producer.md with wire/variant/source-list substitutions.
#   2. Invokes `claude -p` headless with WebSearch+WebFetch allowed, JSON output.
#   3. Extracts the producer JSON from the result.
#   4. (Optional) dedups against Wire Room seen-URLs if WIRE_ROOM_API + INTERNAL_API_KEY set.
#   5. Writes a run artifact: runs/<run_id>/{opportunities.json,report.md,raw.json,meta.json}
#
# Environment:
#   CLAUDE          claude binary (default: claude)
#   MODEL           default model (default: claude-sonnet-4-6 — cheap+capable for
#                    scheduled discovery; override to claude-opus-4-8 for high-value runs)
#   WIRE_ROOM_API   base URL of wire-room-ops (for dedup; optional)
#   INTERNAL_API_KEY  wire-room-ops internal key (for dedup; optional)

set -euo pipefail

WIRE=""
VARIANT="A"
MODEL="${MODEL:-claude-sonnet-4-6}"
CLAUDE="${CLAUDE:-claude}"
PRODUCER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wire) WIRE="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$WIRE" != "crypto" && "$WIRE" != "ai" && "$WIRE" != "oss" ]]; then
  echo "error: --wire must be crypto|ai|oss (got '$WIRE')" >&2; exit 2
fi
if [[ "$VARIANT" != "A" && "$VARIANT" != "B" ]]; then
  echo "error: --variant must be A|B (got '$VARIANT')" >&2; exit 2
fi

# --- wire definitions + preferred source domains ---
declare -A WIRE_DEF WIRE_SOURCES WIRE_TARGET
WIRE_DEF[crypto]="crypto / web3 funding: protocol ecosystem grants (Ethereum, Solana, Cardano, Filecoin, Cosmos, etc.), DAO treasury grants, fellowship & bounty programs, crypto-native RFPs."
WIRE_DEF[ai]="AI / ML funding: AI-safety & alignment grants, compute grants, research fellowships, open-source model funding, gov AI RFPs (NSF/NIH/ARPA-E/DARPA), foundation AI programs."
WIRE_DEF[oss]="open-source funding: funder programs (Sovereign Tech Fund, NLnet, Alpha-Omega, FOSS responders), foundation grants, corporate OSS funds, maintainer fellowships."

WIRE_SOURCES[crypto]="forum.zcashcommunity.com, solana.foundation/grants, cardano.ideascale.com, ethereum.org, filecoin.io/grants, cosmos.network, gov.foundation, dao treasury pages, gitcoin.co"
WIRE_SOURCES[ai]="safety.anthropic.com, openai.com/security, nsf.gov, grants.gov, ariacc.org, longresist.org, gov.uk AI grant pages, ai-safety-focused foundations, FAR.AI, Apollo Research"
WIRE_SOURCES[oss]="nlnet.nl, sovereigntechfund.de, alpha-omega.dev, fossresponders.com, opencollective.com, github.com/funding, openssf.org, linuxfoundation.org"

WIRE_TARGET[crypto]="5-8"
WIRE_TARGET[ai]="5-8"
WIRE_TARGET[oss]="5-8"

# --- variant rules ---
if [[ "$VARIANT" == "A" ]]; then
  VARIANT_RULES="BROAD-CAST. Cast a wide net across many canonical sources. Emit every item that passes the source-verify and currency gates, even if fit_score is modest. Let downstream dedup + classify do the filtering. Target is recall — surface what's out there."
  TARGET_COUNT="${WIRE_TARGET[$WIRE]}"
else
  VARIANT_RULES="TIGHT-FILTER. Pre-score hard and only emit items with fit_score >= 75. Prefer fewer, higher-confidence items. Self-filter aggressively; downstream should see near-zero noise. Target is precision."
  TARGET_COUNT="3-5"
fi

TODAY="$(date -u +%Y-%m-%d)"
TODAY_TS="$(date -u +%Y-%m-%dT%H%M%SZ)"
RUN_ID="claude-code-${TODAY_TS}"
RUN_DIR="${PRODUCER_ROOT}/runs/${WIRE}/${VARIANT}/${RUN_ID}"
mkdir -p "$RUN_DIR"
echo "RUN_DIR=$RUN_DIR"

# --- render prompt ---
PROMPT_FILE="$RUN_DIR/prompt.txt"
sed \
  -e "s|{{WIRE}}|${WIRE}|g" \
  -e "s|{{WIRE_DEFINITION}}|${WIRE_DEF[$WIRE]}|" \
  -e "s|{{VARIANT}}|${VARIANT}|g" \
  -e "s|{{VARIANT_RULES}}|${VARIANT_RULES}|" \
  -e "s|{{SOURCE_DOMAINS}}|${WIRE_SOURCES[$WIRE]}|g" \
  -e "s|{{TARGET_COUNT}}|${TARGET_COUNT}|g" \
  -e "s|{{TODAY}}|${TODAY}|g" \
  -e "s|{{TODAY_TS}}|${TODAY_TS}|" \
  "${PRODUCER_ROOT}/prompts/producer.md" > "$PROMPT_FILE"

# --- prime with the already-catalogued set so the producer hunts NEW, not re-finds.
#     Best-effort: known_programs.py emits nothing without DATABASE_URL, so the prompt just
#     renders bare (unchanged behavior). Spliced via python (portable; the list is multi-line).
#     Toggle off with SCOUT_PRIME_KNOWN=0. known.txt is kept in the run dir for observability. ---
KNOWN_FILE="$RUN_DIR/known.txt"
: > "$KNOWN_FILE"
if [[ "${SCOUT_PRIME_KNOWN:-1}" != "0" ]]; then
  python3 "${PRODUCER_ROOT}/lib/known_programs.py" "$WIRE" > "$KNOWN_FILE" 2>/dev/null || : > "$KNOWN_FILE"
fi
python3 - "$PROMPT_FILE" "$KNOWN_FILE" <<'PY'
import sys
prompt_path, known_path = sys.argv[1], sys.argv[2]
known = open(known_path).read().strip()
text = open(prompt_path).read().replace("{{KNOWN_PROGRAMS}}", known)
open(prompt_path, "w").write(text)
PY
KNOWN_N=$(grep -c '^- ' "$KNOWN_FILE" 2>/dev/null || echo 0)
echo "[producer] primed with ${KNOWN_N} already-known ${WIRE} programs"

echo "[producer] wire=${WIRE} variant=${VARIANT} model=${MODEL} run=${RUN_ID}"
echo "[producer] -> $RUN_DIR"

# --- portable wall-clock cap on the producer (a hung claude -p must not block later wires) ---
PRODUCER_TIMEOUT="${SCOUT_PRODUCER_TIMEOUT:-600}"
if command -v timeout >/dev/null 2>&1; then TIMEOUT=(timeout "$PRODUCER_TIMEOUT")
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT=(gtimeout "$PRODUCER_TIMEOUT")
else TIMEOUT=(); echo "[producer] note: no timeout binary — running uncapped" >&2; fi

# --- invoke Claude Code headless ---
# Stream-JSON in, capture; permission-mode acceptEdits + allow web tools (non-interactive safe).
RAW_JSON="$RUN_DIR/raw.json"
"${TIMEOUT[@]}" "$CLAUDE" -p "$(cat "$PROMPT_FILE")" \
  --model "$MODEL" \
  --output-format json \
  --permission-mode acceptEdits \
  --allowedTools "WebSearch" "WebFetch" \
  --max-turns "${SCOUT_MAX_TURNS:-100}" \
  > "$RAW_JSON"

# --- extract the producer payload (the model's `result` text holds our JSON object) ---
python3 "${PRODUCER_ROOT}/lib/extract.py" "$RAW_JSON" "$RUN_DIR/opportunities.json"

# --- self-prove: re-fetch each source_url and confirm the claimed facts are on the page ---
# NON-FATAL: verification is a diagnostic; it must never block delivery of finds (C2).
echo "[producer] verifying sources…"
env -u INTERNAL_API_KEY -u RESEND_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u ALERT_FROM -u NOTIFICATION_EMAIL \
  python3 "${PRODUCER_ROOT}/lib/verify.py" "$RUN_DIR/opportunities.json" \
  || echo "[producer] verify failed (non-fatal) — continuing"

# --- optional: dedup against Wire Room seen-URLs (only if API configured) ---
if [[ -n "${WIRE_ROOM_API:-}" && -n "${INTERNAL_API_KEY:-}" ]]; then
  echo "[producer] deduping against Wire Room seen-URLs…"
  python3 "${PRODUCER_ROOT}/lib/dedup.py" "$RUN_DIR/opportunities.json" "${WIRE}" "${WIRE_ROOM_API}" \
    || echo "[producer] dedup skipped (API error) — full set retained"
fi

# --- render the report LAST (M7) so it reflects the DELIVERED set: post-verify stamps AND
#     post-dedup rejections (it was rendered before dedup, so it showed items that get dropped). ---
python3 "${PRODUCER_ROOT}/lib/report.py" "$RUN_DIR/opportunities.json" "$RUN_DIR/report.md" "$RAW_JSON" \
  || echo "[producer] report failed (non-fatal) — continuing"

# --- meta + summary ---
python3 - "$RUN_DIR" "$WIRE" "$VARIANT" "$RUN_ID" "$MODEL" <<'PY' > "$RUN_DIR/meta.json"
import sys, json, os, datetime
run_dir, wire, variant, run_id, model = sys.argv[1:6]
opps_path = os.path.join(run_dir, "opportunities.json")
n = 0; score_avg = None
if os.path.exists(opps_path):
    try:
        d = json.load(open(opps_path))
        opps = d.get("opportunities", [])
        n = len(opps)
        if opps: score_avg = round(sum(o.get("fit_score",0) for o in opps)/len(opps))
    except Exception: pass
try: raw = json.load(open(os.path.join(run_dir, "raw.json"))) if os.path.exists(os.path.join(run_dir,"raw.json")) else {}
except Exception: raw = {}
print(json.dumps({
  "run_id": run_id, "wire": wire, "variant": variant, "model": model,
  "generated_at": datetime.datetime.utcnow().isoformat()+"Z",
  "opportunity_count": n, "avg_fit_score": score_avg,
  "cost_usd": raw.get("total_cost_usd"),
  "duration_ms": raw.get("duration_ms"),
}, indent=2))
PY

cat "$RUN_DIR/meta.json"
echo "[producer] done → $RUN_DIR"
