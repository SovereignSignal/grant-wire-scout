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
RENDER_ONLY=0
PRODUCER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wire) WIRE="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --model) MODEL_FLAG="$2"; shift 2 ;;
    # Render the prompt and stop, before any model is invoked. Lets bin/test-prompt.sh pin
    # what the producers are actually told, hermetically and at zero cost.
    --render-only) RENDER_ONLY=1; shift ;;
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
WIRE_DEF[crypto]="crypto / web3 funding: protocol ecosystem grants (Ethereum, Solana, Stellar, Sui, Aptos, Arbitrum, Starknet, Cardano, Filecoin, Cosmos, etc.), DAO treasury grants, fellowship & bounty programs, crypto-native RFPs. If a protocol/ecosystem fund pays people to write open-source, it is STILL crypto — not oss."
WIRE_DEF[ai]="AI / ML funding: AI-safety & alignment grants and RFPs (Coefficient Giving, FAS, Manifund, GovAI, Apart Research, Iliad, Longview), compute and open-model funds (NAIRR, Nebius, Swiss AI Initiative, EuroHPC access calls), foundation & corporate AI programs (Schmidt Sciences, GitLab Foundation, Renaissance Philanthropy, Stanford HAI, UKRI EPSRC), lab programs (Anthropic, OpenAI, DeepMind), and accelerators or research cohorts with real money attached. US federal AI research calls (NSF, DARPA, IARPA) count when the program or track is genuinely new; score them 60 or below otherwise, since routine rounds are re-found far more often than they are approved. REJECT outright: EU framework-programme calls and procurement tenders (Horizon Europe, Digital Europe, EU Chips JU, EuroHPC Gigafactories) and ERC grants (ADG / PoC / Plus / Starting) — general academic research open to any field, zero approvals in 11 attempts. Compute-ACCESS calls (e.g. EuroHPC AI for Science) still count. An AI-lab research grant is ai — not oss — even when the work is published openly."
WIRE_DEF[oss]="open-source *funder* programs for maintainers and public-goods software: NLnet, Sovereign Tech Fund, Alpha-Omega, FOSS United / FOSS responders, GitHub Secure Open Source Fund, OpenSSF, Linux Foundation, SustainOSS, Software Sustainability Institute. NOT protocol ecosystem grants (those are crypto) and NOT AI-lab/safety grants (those are ai)."

WIRE_SOURCES[crypto]="forum.zcashcommunity.com, solana.foundation/grants, cardano.ideascale.com, ethereum.org, filecoin.io/grants, cosmos.network, gov.foundation, dao treasury pages, gitcoin.co"
WIRE_SOURCES[ai]="coefficientgiving.org, manifund.org, governance.ai, apartresearch.com, fas.org, longview.org, hai.stanford.edu, renaissancephilanthropy.org, ukri.org, anthropic.com, openai.com, deepmind.google, simpler.grants.gov, nsf.gov, darpa.mil"
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
# Every substitution goes through python str.replace, never sed. In a sed replacement an
# unescaped `&` expands to the WHOLE MATCH, so `fellowship & bounty programs` rendered as
# `fellowship {{WIRE_DEFINITION}} bounty programs` — the crypto and ai wire definitions had
# been shipping corrupted to both producers. Values are passed through the environment so
# quotes, slashes, ampersands and newlines are all literal.
PROMPT_FILE="$RUN_DIR/prompt.txt"
SUB_PRODUCER_LABEL="$PRODUCER_LABEL" SUB_PRODUCER="$PRODUCER" SUB_WIRE="$WIRE" \
SUB_WIRE_DEFINITION="${WIRE_DEF[$WIRE]}" SUB_VARIANT="$VARIANT" SUB_VARIANT_RULES="$VARIANT_RULES" \
SUB_SOURCE_DOMAINS="${WIRE_SOURCES[$WIRE]}" SUB_TARGET_COUNT="$TARGET_COUNT" \
SUB_TODAY="$TODAY" SUB_TODAY_TS="$TODAY_TS" SUB_RUN_ID="$RUN_ID" \
SUB_DISCOVERED_VIA="$DISCOVERED_VIA" SUB_DISCOVERY_METHOD="$DISCOVERY_METHOD" \
python3 - "${PRODUCER_ROOT}/prompts/producer.md" "$PROMPT_FILE" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
for key, value in os.environ.items():
    if key.startswith("SUB_"):
        text = text.replace("{{%s}}" % key[4:], value)
open(dst, "w").write(text)
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
KNOWN_N="$(grep -c '^- ' "$KNOWN_FILE" 2>/dev/null || true)"
KNOWN_N="${KNOWN_N:-0}"
echo "[producer] primed with ${KNOWN_N} already-known ${WIRE} programs"

echo "[producer] engine=${ENGINE} wire=${WIRE} variant=${VARIANT} model=${MODEL} run=${RUN_ID}"
echo "[producer] -> $RUN_DIR"

if [[ "$RENDER_ONLY" == "1" ]]; then
  echo "[producer] --render-only: prompt written, no model invoked"
  exit 0
fi

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
python3 "${PRODUCER_ROOT}/lib/validate.py" "$RUN_DIR/opportunities.json" \
  || echo "[producer] validate failed (non-fatal) — continuing"

# --- self-prove: re-fetch each source_url and confirm the claimed facts are on the page ---
# NON-FATAL: verification is a diagnostic; it must never block delivery of finds (C2).
echo "[producer] verifying sources…"
env -u INTERNAL_API_KEY -u RESEND_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u ALERT_FROM \
    -u NOTIFICATION_EMAIL -u GROK_AUTH_JSON -u XAI_API_KEY \
  python3 "${PRODUCER_ROOT}/lib/verify.py" "$RUN_DIR/opportunities.json" \
  || echo "[producer] verify failed (non-fatal) — continuing"
if [[ "${SCOUT_REQUIRE_VERIFIED:-0}" == "1" ]]; then
  python3 - "${PRODUCER_ROOT}/lib" "$RUN_DIR/opportunities.json" <<'PY' \
    || echo "[producer] REQUIRE_VERIFIED filter failed (non-fatal) — continuing"
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import validate
p = Path(sys.argv[2])
p.write_text(json.dumps(validate.drop_unverified(json.loads(p.read_text())), indent=2))
PY
fi

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
n = 0; score_avg = None; funnel = {}
if os.path.exists(opps_path):
    try:
        d = json.load(open(opps_path))
        opps = d.get("opportunities", [])
        n = len(opps)
        if opps: score_avg = round(sum(o.get("fit_score",0) for o in opps)/len(opps))
        funnel = d.get("funnel") or {}
    except Exception: pass
try: raw = json.load(open(os.path.join(run_dir, "raw.json"))) if os.path.exists(os.path.join(run_dir,"raw.json")) else {}
except Exception: raw = {}
print(json.dumps({
  "run_id": run_id, "wire": wire, "variant": variant, "model": model,
  "engine": engine, "producer": producer,
  "generated_at": datetime.datetime.utcnow().isoformat()+"Z",
  "opportunity_count": n, "avg_fit_score": score_avg,
  "found_count": funnel.get("found", n),
  "dedup_dropped": funnel.get("dedup_dropped", 0),
  "cost_usd": raw.get("total_cost_usd"),
  "duration_ms": raw.get("duration_ms") or raw.get("durationMs"),
}, indent=2))
PY

cat "$RUN_DIR/meta.json"
echo "[producer] done → $RUN_DIR"
