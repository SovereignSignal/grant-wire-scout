#!/usr/bin/env bash
# test-prompt.sh — pin the rendered producer prompt against the operator's verdict record.
#
# The prompt is the only lever on what the producers hunt, and until now nothing tested it.
# The 30-day record (2026-08-04 .. 2026-09-03) said the ai wire was pointed at exactly what
# the operator declines: Claude's ai wire returned 55 finds for 4 approvals, and the declines
# were NSF, EuroHPC, EU Chips, DOE SBIR, DARPA STTR, ARIA, MATS, CYD — while the approvals
# were FAS, UKRI EPSRC, GitLab Foundation. The old WIRE_DEF named "gov AI RFPs
# (NSF/NIH/ARPA-E/DARPA)" as the TARGET and trusted nsf.gov + grants.gov.
#
# Three standing reject classes came from the same record:
#   employment/study  — programme-director roles, PhD/postdoc posts, residencies,
#                       study-abroad and travel grants (Open Science NL, ARIA PD, CYD)
#   fellowship cap    — fellowships score <= 55 unless the round is genuinely new
#   single-protocol bug bounties — Immunefi/Sherlock/HackenProof/Code4rena (Zest, Lombard,
#                       Ethena, Citrea, Aave all declined on the same rationale)
#
# Both lanes render this same file through run-producer.sh, so these rules bind Claude AND Grok.
#
# Hermetic: --render-only stops before any model is invoked. No network, no auth, no cost.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAILN=0
ok(){ echo "  ok: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1" >&2; FAILN=$((FAILN+1)); }
has(){ grep -qiF -- "$2" "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; rm -rf "$ROOT"/runs/*/A/*-rendertest-* 2>/dev/null' EXIT

render(){  # render <wire> [engine] -> prints the prompt path
  local wire="$1" engine="${2:-claude}" out
  out="$(cd "$ROOT" && SCOUT_PRIME_KNOWN=0 SCOUT_ENGINE="$engine" \
        ./run-producer.sh --wire "$wire" --variant A --render-only 2>"$TMP/err.$wire")" || {
    echo "RENDER FAILED ($wire/$engine): $(tail -3 "$TMP/err.$wire")" >&2; return 1; }
  local dir
  dir="$(sed -n 's/^RUN_DIR=//p' <<<"$out" | tail -1)"
  [ -f "$dir/prompt.txt" ] || { echo "no prompt.txt in $dir" >&2; return 1; }
  echo "$dir/prompt.txt"
}

echo "== A. render-only stops before the model =="
P="$(render crypto)" || bad "render crypto"
if [ -n "${P:-}" ]; then
  ok "renders a prompt without invoking a model"
  [ ! -f "$(dirname "$P")/raw.json" ] && ok "no model envelope written" || bad "render-only still called the model"
  grep -q '{{' "$P" && bad "unsubstituted placeholder left in prompt: $(grep -o '{{[A-Z_]*}}' "$P" | sort -u | tr '\n' ' ')" \
                    || ok "every placeholder substituted"
fi

echo "== B. ai wire points at what the operator approves, not what he declines =="
# Grounded in the 90-day scout record for wire=ai (claude-code + grok-scout, decided rows):
#   government 6/40 approved (15%)   everything else 24/111 (22%)
# So government is a WEAKER prior, not a reject: NSF Expeditions, DARPA IPTO Office-Wide BAA
# and a DARPA SBIR were all approved. An earlier draft of this rule banned "routine SBIR
# rounds" and "generic agency-wide BAAs" — that contradicted three of the operator's own
# approvals, so it is a score cap instead.
# The genuine zero is Europe: ec.europa.eu + erc.europa.eu went 0 for 11 (ERC ADG/PoC/Plus
# archived as general academic research; Horizon / Digital Europe / EU Chips / EuroHPC
# Gigafactories declined as procurement). EuroHPC AI for Science, a compute-ACCESS call, was
# approved — so the exclusion must cut tenders, not the whole funder.
AI="$(render ai)" || bad "render ai"
if [ -n "${AI:-}" ]; then
  for f in "AI-safety" "alignment" "compute" "open-model" "Coefficient Giving" "UKRI"; do
    has "$AI" "$f" && ok "ai wire names $f" || bad "ai wire missing $f"
  done
  has "$AI" "count when the program or track is genuinely new" \
    && ok "US federal calls are conditional, not the headline target" \
    || bad "ai wire still targets government solicitations unconditionally"
  has "$AI" "score them 60 or below otherwise" \
    && ok "routine federal rounds are capped, not banned" \
    || bad "no score cap on routine federal rounds"
  for f in "Horizon Europe" "ERC" "EU Chips" "procurement tender"; do
    has "$AI" "$f" && ok "ai wire rejects $f" || bad "ai wire does not reject $f"
  done
  has "$AI" "Compute-ACCESS calls" && ok "compute-access carve-out survives the EU exclusion" \
                                   || bad "EU exclusion swallows approved compute-access calls"
  SRC="$(grep -i 'Trust domains for verification' "$AI" | head -1)"
  grep -qi "coefficient\|manifund\|governance.ai\|apartresearch" <<<"$SRC" \
    && ok "ai lead sources name the funders behind the approvals" \
    || bad "ai lead sources do not name approved funders"
fi

echo "== C. standing reject classes (every wire) =="
for wire in crypto ai oss; do
  W="$(render "$wire")" || { bad "render $wire"; continue; }
  has "$W" "job post" && ok "$wire: employment is a reject class" || bad "$wire: employment not rejected"
  for f in "PhD" "postdoc" "residenc" "study-abroad"; do
    has "$W" "$f" && ok "$wire: $f rejected" || bad "$wire: $f not rejected"
  done
  has "$W" "single-protocol bug bount" && ok "$wire: single-protocol bug bounties rejected" \
                                       || bad "$wire: single-protocol bug bounties not rejected"
  for f in "Immunefi" "Sherlock" "Code4rena"; do
    has "$W" "$f" && ok "$wire: $f named" || bad "$wire: $f not named"
  done
  # Multi-project security funds still count (OpenSats Code RED and the EF audit subsidy
  # were both approved), so the exclusion must not swallow them.
  has "$W" "Multi-project security funds still count" \
    && ok "$wire: multi-project security funds stay in scope" \
    || bad "$wire: bug-bounty exclusion has no carve-out"
  has "$W" "Fellowships count only if they pay the fellow directly" \
    && ok "$wire: fellowship rule present" || bad "$wire: no fellowship rule"
done

echo "== D. the other two wires keep their own definitions =="
C="$(render crypto)"; O="$(render oss)"
[ -n "$C" ] && { has "$C" "DAO treasury" && ok "crypto wire definition intact" || bad "crypto wire definition lost"; }
[ -n "$O" ] && { has "$O" "NLnet" && ok "oss wire definition intact" || bad "oss wire definition lost"; }
[ -n "$C" ] && { grep -qi "AI-safety & alignment grants" "$C" && bad "ai definition leaked into crypto" \
                                                              || ok "wire definitions stay separate"; }

echo "== E. both engines get the same rules =="
G="$(render ai grok)" || bad "render ai/grok"
if [ -n "${G:-}" ] && [ -n "${AI:-}" ]; then
  has "$G" "single-protocol bug bount" && ok "grok lane gets the reject classes" || bad "grok lane missing reject classes"
  has "$G" "count when the program or track is genuinely new" && ok "grok lane gets the ai scope rule" \
                                                             || bad "grok lane missing ai scope rule"
  has "$G" "fellowship & bounty" || has "$G" "AI-safety & alignment" \
    && ok "grok lane renders ampersands literally (no sed & expansion)" \
    || bad "grok lane still has the sed ampersand bug"
fi

echo
echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ] && echo "ALL PASS"
exit $(( FAILN>0 ? 1 : 0 ))
