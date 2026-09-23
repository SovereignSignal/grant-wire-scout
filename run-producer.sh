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

# --- portable wall-clock cap on the producer. This is a SAFETY NET for a genuinely hung
#     claude/grok -p, NOT the normal work limiter: real work is bounded by --max-turns and cost is
#     turn/token-driven, not wall-clock-driven, so a higher cap costs nothing extra — it just
#     lets the paid-for turn budget finish.
#     History: 600s was under-provisioned once known-catalog priming landed (2026-06-30,
#     rc=124, work discarded). 1200s held until OSS primed with the full 400-name cap
#     (2026-09-05 Claude oss/A). 2400s is the new default; override with SCOUT_PRODUCER_TIMEOUT.
#     Defined up here because the rendered prompt tells the model its budget ({{TIME_BUDGET}}).
#     Both CLIs print their JSON envelope ONLY when they finish (`--output-format json` is one
#     object at the end), so a run killed at the cap leaves raw.json EMPTY — there is nothing
#     on disk to salvage. 2026-09-23 Grok oss/A: 2400s, raw.json empty, work discarded. The
#     recovery below therefore RESUMES the killed session and asks it to write the JSON now.
#     -k gives the CLI a grace period after SIGTERM, then SIGKILLs it so a signal-ignoring
#     process cannot hold the cron open forever. ---
PRODUCER_TIMEOUT="${SCOUT_PRODUCER_TIMEOUT:-2400}"
TIMEOUT_GRACE="${SCOUT_TIMEOUT_GRACE:-30}"
if command -v timeout >/dev/null 2>&1; then TIMEOUT=(timeout -k "$TIMEOUT_GRACE")
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT=(gtimeout -k "$TIMEOUT_GRACE")
else TIMEOUT=(); echo "[producer] note: no timeout binary — running uncapped" >&2; fi
capped() {  # capped <seconds> <cmd...>: run under the wall-clock cap when a timeout binary exists
  local dur="$1"; shift
  if [[ ${#TIMEOUT[@]} -gt 0 ]]; then "${TIMEOUT[@]}" "$dur" "$@"; else "$@"; fi
}
# Minutes the model is told it has; leave it headroom to write the JSON before the kill.
TIME_BUDGET_MIN="$(( PRODUCER_TIMEOUT / 60 ))"
TIME_BUDGET_DISCOVER_MIN="$(( PRODUCER_TIMEOUT * 6 / 10 / 60 ))"
TIME_BUDGET="You have a HARD wall-clock budget of about ${TIME_BUDGET_MIN} minutes for this entire run (searching, fetching, and writing the JSON). A run that overruns is killed and every find in it is lost. Pace yourself: stop discovering new candidates after roughly ${TIME_BUDGET_DISCOVER_MIN} minutes, spend the rest verifying what you have, and write the final JSON with time to spare. A complete JSON with fewer finds delivered in time beats a larger set that never gets written."

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
SUB_TIME_BUDGET="$TIME_BUDGET" \
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
if grep -qF "(+ more not shown)" "$KNOWN_FILE" 2>/dev/null; then
  # The list hit SCOUT_KNOWN_LIMIT: the wire's recent catalogue is LARGER than what the model
  # was told. Both wall-clock kills so far (2026-09-05 Claude oss, 2026-09-23 Grok oss) were
  # runs primed at the cap on a thin wire — the model hunts a long time for something new.
  echo "[producer] note: known-programs list is capped at ${KNOWN_N} (SCOUT_KNOWN_LIMIT) — the ${WIRE} catalogue is larger; long hunts are likely on this wire"
fi

echo "[producer] engine=${ENGINE} wire=${WIRE} variant=${VARIANT} model=${MODEL} run=${RUN_ID}"
echo "[producer] -> $RUN_DIR"

if [[ "$RENDER_ONLY" == "1" ]]; then
  echo "[producer] --render-only: prompt written, no model invoked"
  exit 0
fi

RAW_JSON="$RUN_DIR/raw.json"
STDERR_FILE="$RUN_DIR/producer.stderr"
RUN_T0="$(date +%s)"

# --- session pinning. Each invocation gets a UUID we choose, passed as --session-id to both
#     CLIs. On SIGTERM both persist the session up to the last completed tool call, so after a
#     wall-clock kill we can `--resume` it and ask for the JSON — the finds the model had
#     already verified live in that session, not on disk. SCOUT_SESSION_RESUME=0 turns the
#     pinning and the resume-flush off. ---
SESSION_PIN="${SCOUT_SESSION_RESUME:-1}"
SESSION_ID=""
SESSION_ARGS=()
new_session() {
  SESSION_ID=""; SESSION_ARGS=()
  if [[ "$SESSION_PIN" != "0" ]]; then
    SESSION_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    SESSION_ARGS=(--session-id "$SESSION_ID")
  fi
}
# A flag this CLI build does not know makes it exit non-zero at once with a usage error on
# stderr and nothing on stdout. Detect that so an untested flag can never kill every run.
flag_rejected() {  # <stderr-file> <flag-name> <rc> <stdout-file>
  [[ "$3" -ne 0 && "$3" -ne 124 && ! -s "$4" ]] && grep -qi -- "$2" "$1" 2>/dev/null
}
# stderr streams live to the log (Railway shows a hung CLI's complaints as they happen) AND
# lands in a file for flag_rejected; wait for the tee so the file is complete before grep.
capture_stderr() { tee "$STDERR_FILE" >&2; }
settle_stderr() { wait "$!" 2>/dev/null || true; }

# Isolate the model invoke so a 124 does not trip `set -e` and skip extract/salvage.
producer_rc=0
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
  # Grok CLI 1.0.5 can hit its per-response output cap on the FINAL turn: reasoning tokens
  # eat the budget before the JSON is written, and the CLI returns an internal-error blob
  # ("error_kind": "max_tokens_truncation") with no payload — nothing for extract to salvage.
  # Seen on oss 2026-09-11 and 2026-09-16 (2 of 5 ticks). The CLI has no output-token flag,
  # so the lever is one retry at --reasoning-effort low. Bounded to a single retry.
  grok_attempt=1
  while :; do
    new_session
    producer_rc=0
    capped "$PRODUCER_TIMEOUT" "$GROK_BIN" "${GROK_ARGS[@]}" ${SESSION_ARGS[@]+"${SESSION_ARGS[@]}"} \
      > "$RAW_JSON" 2> >(capture_stderr) || producer_rc=$?
    settle_stderr
    if [[ -n "$SESSION_ID" ]] && flag_rejected "$STDERR_FILE" "session-id" "$producer_rc" "$RAW_JSON"; then
      echo "[producer] grok rejected --session-id — retrying without session pinning (resume-flush unavailable)" >&2
      SESSION_PIN=0
      continue
    fi
    if [[ "$producer_rc" -ne 0 && "$producer_rc" -ne 124 && "$grok_attempt" -eq 1 ]] \
       && grep -q "max_tokens_truncation" "$RAW_JSON" 2>/dev/null; then
      echo "[producer] grok output truncated by max_tokens on attempt 1 — retrying once at --reasoning-effort low" >&2
      mv "$RAW_JSON" "$RUN_DIR/raw.attempt1.json"
      GROK_ARGS+=(--reasoning-effort low)
      grok_attempt=2
      continue
    fi
    break
  done
else
  CLAUDE="${CLAUDE:-claude}"
  while :; do
    new_session
    producer_rc=0
    capped "$PRODUCER_TIMEOUT" "$CLAUDE" -p "$(cat "$PROMPT_FILE")" \
      --model "$MODEL" \
      --output-format json \
      --permission-mode acceptEdits \
      --allowedTools "WebSearch" "WebFetch" \
      --max-turns "${SCOUT_MAX_TURNS:-100}" \
      ${SESSION_ARGS[@]+"${SESSION_ARGS[@]}"} \
      > "$RAW_JSON" 2> >(capture_stderr) || producer_rc=$?
    settle_stderr
    if [[ -n "$SESSION_ID" ]] && flag_rejected "$STDERR_FILE" "session-id" "$producer_rc" "$RAW_JSON"; then
      echo "[producer] claude rejected --session-id — retrying without session pinning (resume-flush unavailable)" >&2
      SESSION_PIN=0
      continue
    fi
    break
  done
fi
RUN_ELAPSED="$(( $(date +%s) - RUN_T0 ))"

# --- resume-flush: the only salvage that can work after a kill. raw.json is empty by
#     construction (json output is one object at exit), but the session on disk still holds
#     every page the model fetched and verified. Resume it, forbid further searching, and
#     give it a short cap to write the JSON it was about to write. ---
SALVAGED_VIA_RESUME=0
resume_flush() {
  [[ -n "$SESSION_ID" ]] || { echo "[producer] TIMEOUT: no pinned session to resume — nothing to flush" >&2; return 1; }
  local cap="${SCOUT_SALVAGE_TIMEOUT:-300}" turns="${SCOUT_SALVAGE_MAX_TURNS:-3}"
  local out="$RUN_DIR/raw.salvage.json" err="$RUN_DIR/salvage.stderr" rc=0
  local prompt="TIME IS UP. Do NOT run any more searches or fetches — your tool budget is gone. Return NOW the single JSON object described in your instructions (same shape, no prose, no markdown fences), containing ONLY the ${WIRE} opportunities you have ALREADY fetched and verified at their canonical source during this session. Put every candidate you did not finish verifying under rejected with classification NOISE and reason \"unverified at timeout\". If you verified nothing, return the object with an empty opportunities array."
  echo "[producer] TIMEOUT: resuming session ${SESSION_ID} for up to ${cap}s to flush what was already verified" >&2
  if [[ "$ENGINE" == "grok" ]]; then
    local extra=(--disable-web-search)
    while :; do
      rc=0
      capped "$cap" "$GROK_BIN" --no-auto-update -p "$prompt" --resume "$SESSION_ID" \
        --model "$MODEL" --output-format json --always-approve --max-turns "$turns" \
        ${extra[@]+"${extra[@]}"} > "$out" 2> "$err" || rc=$?
      if [[ ${#extra[@]} -gt 0 ]] && flag_rejected "$err" "disable-web-search" "$rc" "$out"; then
        extra=(); continue
      fi
      break
    done
  else
    capped "$cap" "$CLAUDE" -p "$prompt" --resume "$SESSION_ID" \
      --model "$MODEL" --output-format json --permission-mode acceptEdits \
      --disallowedTools "WebSearch" "WebFetch" --max-turns "$turns" \
      > "$out" 2> "$err" || rc=$?
  fi
  [[ -s "$err" ]] && cat "$err" >&2
  if [[ -s "$out" ]] && grep -q opportunities "$out"; then
    mv "$RAW_JSON" "$RUN_DIR/raw.killed.json"
    mv "$out" "$RAW_JSON"
    SALVAGED_VIA_RESUME=1
    echo "[producer] TIMEOUT: resume flush returned a payload (rc=${rc}) — extracting from it" >&2
    return 0
  fi
  echo "[producer] TIMEOUT: resume flush returned no payload (rc=${rc}, $(wc -c < "$out" 2>/dev/null || echo 0) bytes)" >&2
  return 1
}

if [[ "$producer_rc" -eq 124 ]]; then
  echo "[producer] TIMEOUT after ${PRODUCER_TIMEOUT}s (elapsed ${RUN_ELAPSED}s, model=${MODEL}, primed=${KNOWN_N})" >&2
  if grep -q opportunities "$RAW_JSON" 2>/dev/null; then
    echo "[producer] TIMEOUT: raw.json holds a payload — salvaging it" >&2
  else
    echo "[producer] TIMEOUT: raw.json is empty ($(wc -c < "$RAW_JSON") bytes) — the CLI only writes its JSON when it finishes" >&2
    resume_flush || true
  fi
elif [[ "$producer_rc" -ne 0 ]]; then
  echo "[producer] model exited rc=${producer_rc} after ${RUN_ELAPSED}s" >&2
fi

# --- extract the producer payload (the model's `result` text holds our JSON object) ---
# extract.py already salvages truncated / mid-array JSON. Run it even after a timeout so a
# killed claude that flushed a partial envelope does not discard paid-for finds.
# Attribution is a wrapper concern. Grok (2026-09-10 Fri 06:00) emitted a complete
# opportunities array, omitted top-level `producer`, and extract aborted the run
# (`payload missing required key 'producer'`). Stamp what we already know.
export SCOUT_PRODUCER="$PRODUCER"
export SCOUT_VARIANT="$VARIANT"
export SCOUT_WIRE="$WIRE"
export SCOUT_RUN_ID="$RUN_ID"
extract_rc=0
python3 "${PRODUCER_ROOT}/lib/extract.py" "$RAW_JSON" "$RUN_DIR/opportunities.json" \
  || extract_rc=$?
if [[ "$extract_rc" -ne 0 ]]; then
  if [[ "$producer_rc" -eq 124 ]]; then
    echo "[producer] TIMEOUT: nothing recoverable (raw.json empty, resume flush $([[ "$SALVAGED_VIA_RESUME" == 1 ]] && echo "returned an unusable payload" || echo "returned nothing")) — giving up" >&2
    exit 124
  fi
  exit "$extract_rc"
fi

if [[ "$producer_rc" -eq 124 ]]; then
  salvaged_n="$(python3 - "$RUN_DIR/opportunities.json" <<'PY'
import json, sys
try:
    print(len(json.load(open(sys.argv[1])).get("opportunities") or []))
except Exception:
    print(0)
PY
)"
  if [[ "${salvaged_n:-0}" -gt 0 ]]; then
    echo "[producer] TIMEOUT: salvaged ${salvaged_n} opportunities$([[ "$SALVAGED_VIA_RESUME" == 1 ]] && echo " via resume flush") — continuing the pipeline" >&2
    producer_rc=0
    export SCOUT_TIMED_OUT=1
  else
    echo "[producer] TIMEOUT: extract ran but recovered 0 opportunities$([[ "$SALVAGED_VIA_RESUME" == 1 ]] && echo " (the resumed session had verified nothing yet)") — giving up" >&2
    exit 124
  fi
elif [[ "$producer_rc" -ne 0 ]]; then
  # Model failed (AUTH/QUOTA/crash) but extract still produced a payload — keep going so a
  # partial envelope is not thrown away. The scout wrapper classifies from raw.json.
  echo "[producer] model rc=${producer_rc} but extract recovered a payload — continuing" >&2
  producer_rc=0
fi
python3 "${PRODUCER_ROOT}/lib/validate.py" "$RUN_DIR/opportunities.json" \
  || echo "[producer] validate failed (non-fatal) — continuing"

# --- URL gate: reject front-door URLs the Wire Room would archive unread (Gate 1 there).
#     Runs BEFORE verify so we never spend a fetch on a URL that cannot survive intake.
#     Non-fatal like every other filter: a gate bug must not cost a run its finds. ---
python3 "${PRODUCER_ROOT}/lib/url_gate.py" "$RUN_DIR/opportunities.json" \
  || echo "[producer] url gate failed (non-fatal) — continuing"

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

# --- name dedup: the same program at a different URL slips past seen-urls. Drops only names
#     the operator has already DECIDED on; undecided queue rows are left alone. Best-effort:
#     no DATABASE_URL means it keeps everything. ---
python3 "${PRODUCER_ROOT}/lib/name_dedup.py" "$RUN_DIR/opportunities.json" "${WIRE}" \
  || echo "[producer] name dedup skipped (error) — full set retained"

# --- render the report LAST (M7) so it reflects the DELIVERED set: post-verify stamps AND
#     post-dedup rejections (it was rendered before dedup, so it showed items that get dropped). ---
python3 "${PRODUCER_ROOT}/lib/report.py" "$RUN_DIR/opportunities.json" "$RUN_DIR/report.md" "$RAW_JSON" \
  || echo "[producer] report failed (non-fatal) — continuing"

# --- meta + summary ---
WALL_CLOCK_S="$(( $(date +%s) - RUN_T0 ))"
SCOUT_WALL_CLOCK_S="$WALL_CLOCK_S" SCOUT_SESSION_ID="$SESSION_ID" SCOUT_SALVAGED_VIA_RESUME="$SALVAGED_VIA_RESUME" \
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
if not isinstance(raw, dict): raw = {}
try: wall_s = int(os.environ.get("SCOUT_WALL_CLOCK_S") or 0)
except ValueError: wall_s = 0
wall_ms = wall_s * 1000 or None
print(json.dumps({
  "run_id": run_id, "wire": wire, "variant": variant, "model": model,
  "engine": engine, "producer": producer,
  "generated_at": datetime.datetime.utcnow().isoformat()+"Z",
  "opportunity_count": n, "avg_fit_score": score_avg,
  "found_count": funnel.get("found", n),
  "dedup_dropped": funnel.get("dedup_dropped", 0),
  "cost_usd": raw.get("total_cost_usd"),
  # Grok's json envelope carries no duration, and after a timeout raw.json is the short
  # resume-flush envelope, not the hunt. The wrapper's own wall clock is the honest number
  # in both cases so the ledger and the digest can say how long the hunt really took.
  "duration_ms": (wall_ms if os.environ.get("SCOUT_TIMED_OUT") == "1" else None)
                 or raw.get("duration_ms") or raw.get("durationMs") or wall_ms,
  "wall_clock_s": wall_s,
  "timed_out": os.environ.get("SCOUT_TIMED_OUT") == "1",
  "salvaged_via_resume": os.environ.get("SCOUT_SALVAGED_VIA_RESUME") == "1",
  "session_id": os.environ.get("SCOUT_SESSION_ID") or None,
}, indent=2))
PY

cat "$RUN_DIR/meta.json"
echo "[producer] done → $RUN_DIR"
