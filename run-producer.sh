#!/usr/bin/env bash
# run-producer.sh — invoke a grant producer (Claude Code or Grok Build) for one wire+variant.
#
# Usage:
#   ./run-producer.sh --wire crypto --variant A [--engine claude|grok] [--model MODEL]
#
# What it does:
#   1. Renders prompts/producer.md with wire/variant/engine substitutions.
#   2. Invokes `claude -p` or `grok -p` headless with search+fetch tools, JSON output.
#   3. Extracts the producer JSON from the result envelope.
#   4. (Optional) dedups against Wire Room seen-URLs if WIRE_ROOM_API + INTERNAL_API_KEY set.
#   5. Writes a run artifact: runs/<run_id>/{opportunities.json,report.md,raw.json,meta.json}
#
# Environment:
#   SCOUT_ENGINE      claude (default) | grok
#   CLAUDE / GROK     binary overrides
#   MODEL             Claude default: claude-sonnet-4-6
#   GROK_MODEL        Grok default: grok-4.6 (Grok Build flagship as of 2026-08-12;
#                     set grok-4.7 when it ships — independent of Claude's MODEL)
#   GROK_AUTH_JSON    contents of ~/.grok/auth.json from `grok login` (subscription)
#   XAI_API_KEY       console.x.ai key (API bill fallback; not the grok.com path)
#   WIRE_ROOM_API / INTERNAL_API_KEY   optional seen-url dedup

set -euo pipefail

WIRE=""
VARIANT="A"
ENGINE="${SCOUT_ENGINE:-claude}"
MODEL_FLAG=""
PRODUCER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wire) WIRE="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --model) MODEL_FLAG="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$WIRE" != "crypto" && "$WIRE" != "ai" && "$WIRE" != "oss" ]]; then
  echo "error: --wire must be crypto|ai|oss (got '$WIRE')" >&2; exit 2
fi
if [[ "$VARIANT" != "A" && "$VARIANT" != "B" ]]; then
  echo "error: --variant must be A|B (got '$VARIANT')" >&2; exit 2
fi
if [[ "$ENGINE" != "claude" && "$ENGINE" != "grok" ]]; then
  echo "error: --engine must be claude|grok (got '$ENGINE')" >&2; exit 2
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

if [[ "$ENGINE" == "grok" ]]; then
  PRODUCER="grok-build"
  PRODUCER_LABEL="Grok Build Grant Producer"
  MODEL="${MODEL_FLAG:-${GROK_MODEL:-grok-4.6}}"
  DISCOVERED_VIA="x_search"
  DISCOVERY_METHOD="1. **Discover (X-first, then the open web).** Your edge is a different search index than Claude WebSearch — start on X, then confirm at the canonical page:
   - Run many X searches (keyword + semantic) for programs announced or opened in the last ~2 weeks: \"${WIRE} grant\", \"${WIRE} RFP open\", \"applications open\", \"fellowship deadline\". Prefer official/first-party posts over recaps.
   - Treat X posts as LEADS only. For every candidate, fetch the canonical application/program URL — never emit a t.co, aggregator, or social-only URL as source_url.
   - Also search the open web for official pages the X firehose missed (gov RFPs, foundation blogs, DAO forums, hackathon boards). Same recency bias.
   - Hard-drop: jobs, VC raises, token launches, applicant \"I applied\" recaps, medical/clinical fellowships, standing rolling programs with no new 2026 cycle.
   Trust domains for verification: ${WIRE_SOURCES[$WIRE]}"
else
  PRODUCER="claude-code"
  PRODUCER_LABEL="Claude Code Grant Producer"
  MODEL="${MODEL_FLAG:-${MODEL:-claude-sonnet-4-6}}"
  DISCOVERED_VIA="web_search"
  DISCOVERY_METHOD="1. **Discover (hunt fresh + niche; dig past the obvious).** Run MANY targeted WebSearches — do NOT stop at the first prominent results, which are the famous standing programs everyone already knows. Tilt hard toward RECENCY and NOVELTY:
   - Recency queries: \"${WIRE} grant announced 2026\", \"new ${WIRE} RFP open\", \"${WIRE} funding just launched\", \"${WIRE} grant deadline 2026\" — and bias every search toward results dated within ~2 weeks of ${TODAY}.
   - Surfaces where NEW and NICHE grants actually break (favor these over standing /grants landing pages): DAO governance (Snapshot, Tally, Commonwealth, ecosystem forums), hackathon & bounty boards (DoraHacks, Devpost, Gitcoin), foundation announcement BLOGS and X/Twitter posts, and grant-news feeds — use these as LEADS, then verify at the canonical source.
   - Actively chase the under-covered: smaller ecosystems, new protocols, just-launched programs — not the handful of big foundations everyone already tracks.
   Trust domains for verification: ${WIRE_SOURCES[$WIRE]}"
fi

RUN_ID="${PRODUCER}-${TODAY_TS}"
RUN_DIR="${PRODUCER_ROOT}/runs/${WIRE}/${VARIANT}/${RUN_ID}"
mkdir -p "$RUN_DIR"
echo "RUN_DIR=$RUN_DIR"

# --- render prompt ---
PROMPT_FILE="$RUN_DIR/prompt.txt"
# DISCOVERY_METHOD contains slashes/quotes; splice it via python after the rest.
sed \
  -e "s|{{PRODUCER_LABEL}}|${PRODUCER_LABEL}|g" \
  -e "s|{{PRODUCER}}|${PRODUCER}|g" \
  -e "s|{{WIRE}}|${WIRE}|g" \
  -e "s|{{WIRE_DEFINITION}}|${WIRE_DEF[$WIRE]}|" \
  -e "s|{{VARIANT}}|${VARIANT}|g" \
  -e "s|{{VARIANT_RULES}}|${VARIANT_RULES}|" \
  -e "s|{{SOURCE_DOMAINS}}|${WIRE_SOURCES[$WIRE]}|g" \
  -e "s|{{TARGET_COUNT}}|${TARGET_COUNT}|g" \
  -e "s|{{TODAY}}|${TODAY}|g" \
  -e "s|{{TODAY_TS}}|${TODAY_TS}|" \
  -e "s|{{RUN_ID}}|${RUN_ID}|g" \
  -e "s|{{DISCOVERED_VIA}}|${DISCOVERED_VIA}|g" \
  "${PRODUCER_ROOT}/prompts/producer.md" > "$PROMPT_FILE"

python3 - "$PROMPT_FILE" "$DISCOVERY_METHOD" <<'PY'
import sys
path, method = sys.argv[1], sys.argv[2]
text = open(path).read().replace("{{DISCOVERY_METHOD}}", method)
open(path, "w").write(text)
PY

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

echo "[producer] engine=${ENGINE} wire=${WIRE} variant=${VARIANT} model=${MODEL} run=${RUN_ID}"
echo "[producer] -> $RUN_DIR"

# --- portable wall-clock cap on the producer. This is a SAFETY NET for a genuinely hung
#     claude/grok -p, NOT the normal work limiter: real work is bounded by --max-turns and cost is
#     turn/token-driven, not wall-clock-driven, so a higher cap costs nothing extra — it just
#     lets the paid-for turn budget finish. The old 600s cap was under-provisioned: runs had
#     already crept to ~535s pre-priming, and the 2026-06-29 known-catalog priming (which makes
#     the producer hunt for NEW programs beyond the known set) pushed the first cron run past
#     600s, so `timeout` killed it mid-flight (rc=124), discarding all work and firing an alert.
#     1200s gives the turn budget room to complete; override with SCOUT_PRODUCER_TIMEOUT. ---
PRODUCER_TIMEOUT="${SCOUT_PRODUCER_TIMEOUT:-1200}"
if command -v timeout >/dev/null 2>&1; then TIMEOUT=(timeout "$PRODUCER_TIMEOUT")
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT=(gtimeout "$PRODUCER_TIMEOUT")
else TIMEOUT=(); echo "[producer] note: no timeout binary — running uncapped" >&2; fi

RAW_JSON="$RUN_DIR/raw.json"

if [[ "$ENGINE" == "grok" ]]; then
  python3 "${PRODUCER_ROOT}/lib/hydrate_grok_auth.py"
  GROK_BIN="${GROK:-grok}"
  # Headless: --always-approve is required (without it, tool calls are auto-cancelled).
  # --no-auto-update keeps stdout clean. Do NOT pass --sandbox workspace on Railway:
  # Grok CLI 1.0.5 shells out to bubblewrap and REFUSES to start if bwrap is missing
  # (`bwrap exec failed: No such file or directory`). The container is already isolated;
  # optional GROK_SANDBOX=workspace|strict for hosts that have bubblewrap.
  # Tools stay at Grok defaults so X Search + web_fetch remain available (the index edge).
  GROK_ARGS=(--no-auto-update -p "$(cat "$PROMPT_FILE")"
    --model "$MODEL"
    --output-format json
    --always-approve
    --max-turns "${SCOUT_MAX_TURNS:-100}")
  if [[ -n "${GROK_SANDBOX:-}" && "${GROK_SANDBOX}" != "off" ]]; then
    GROK_ARGS+=(--sandbox "$GROK_SANDBOX")
  fi
  "${TIMEOUT[@]}" "$GROK_BIN" "${GROK_ARGS[@]}" \
    > "$RAW_JSON"
else
  CLAUDE="${CLAUDE:-claude}"
  "${TIMEOUT[@]}" "$CLAUDE" -p "$(cat "$PROMPT_FILE")" \
    --model "$MODEL" \
    --output-format json \
    --permission-mode acceptEdits \
    --allowedTools "WebSearch" "WebFetch" \
    --max-turns "${SCOUT_MAX_TURNS:-100}" \
    > "$RAW_JSON"
fi

# --- extract the producer payload (the model's `result` text holds our JSON object) ---
python3 "${PRODUCER_ROOT}/lib/extract.py" "$RAW_JSON" "$RUN_DIR/opportunities.json"

# --- self-prove: re-fetch each source_url and confirm the claimed facts are on the page ---
# NON-FATAL: verification is a diagnostic; it must never block delivery of finds (C2).
echo "[producer] verifying sources…"
env -u INTERNAL_API_KEY -u RESEND_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u ALERT_FROM \
    -u NOTIFICATION_EMAIL -u GROK_AUTH_JSON -u XAI_API_KEY \
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
python3 - "$RUN_DIR" "$WIRE" "$VARIANT" "$RUN_ID" "$MODEL" "$ENGINE" "$PRODUCER" <<'PY' > "$RUN_DIR/meta.json"
import sys, json, os, datetime
run_dir, wire, variant, run_id, model, engine, producer = sys.argv[1:8]
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
  "engine": engine, "producer": producer,
  "generated_at": datetime.datetime.utcnow().isoformat()+"Z",
  "opportunity_count": n, "avg_fit_score": score_avg,
  "cost_usd": raw.get("total_cost_usd"),
  "duration_ms": raw.get("duration_ms") or raw.get("durationMs"),
}, indent=2))
PY

cat "$RUN_DIR/meta.json"
echo "[producer] done → $RUN_DIR"
