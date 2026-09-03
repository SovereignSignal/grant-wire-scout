#!/usr/bin/env bash
# test-gates.sh — the two pre-submit gates that stop the producers wasting the operator's day.
#
# Both come from the 30-day record (2026-08-04 .. 2026-09-03):
#
#   URL GATE. The Wire Room archives any entry whose source_url has no meaningful path
#   (services/intake.ts isUsefulUrl), unscored and unread, BEFORE dedup — so a URL-less
#   entry never reaches seen_urls and the producer re-finds it forever. Claude lost 39 finds
#   this way in 30 days (Prototype Fund, FLOSS/fund, Stellar SCF, Scroll, dYdX, XRPL Commons,
#   Snorkel ×3), Grok 11. All 37 of Claude's approved finds had a deep URL. Catching this in
#   the producer turns a silent archive into a retry the model can act on.
#
#   NAME GATE. dedup.py matched on URL only, so the same program under a new URL sailed
#   through to the operator's queue: Avalanche Team1 seen 7×, NSF CISE Future CoRe 8×,
#   Snorkel 3×. Name-level dedup against decided entries closes it.
#
# Hermetic: no network, no DB, no model. The DB-backed paths are exercised through a stub
# psycopg2 on PYTHONPATH, the same trick bin/test-digest.sh uses.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAILN=0
ok(){ echo "  ok: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1" >&2; FAILN=$((FAILN+1)); }

TMP="$(mktemp -d)"; mkdir -p "$TMP/stub"
trap 'rm -rf "$TMP"' EXIT

# ---- stub psycopg2: serves rows from $STUB_DB_FIXTURE, dispatched by /* marker */ ----
cat > "$TMP/stub/psycopg2.py" <<'PY'
import json, os
class _Cur:
    def __init__(self, fx): self.fx = fx; self.rows = []
    def execute(self, sql, params=None):
        key = next((k for k in ("known", "seen_names") if f"/* {k} */" in sql), None)
        assert key, f"unrecognized query (missing /* marker */):\n{sql}"
        self.rows = [tuple(r) if isinstance(r, list) else (r,) for r in self.fx.get(key, [])]
    def fetchall(self): return self.rows
    def __enter__(self): return self
    def __exit__(self, *a): return False
class _Conn:
    def __init__(self, fx): self.fx = fx
    def cursor(self): return _Cur(self.fx)
    def close(self): pass
    def __enter__(self): return self
    def __exit__(self, *a): return False
def connect(dsn, *a, **k):
    if os.environ.get("STUB_DB_FAIL") == "1":
        raise RuntimeError("could not connect to server")
    return _Conn(json.load(open(os.environ["STUB_DB_FIXTURE"])))
PY

echo "== A. URL gate — mirrors the Wire Room's isUsefulUrl, in the producer =="
cat > "$TMP/opps.json" <<'JSON'
{
  "producer": "claude-code", "wire": "oss", "variant": "A",
  "opportunities": [
    {"name": "Deep path is fine", "source_url": "https://geckofund.org/apply.html"},
    {"name": "Nested path is fine", "source_url": "https://grants.scroll.io/programs/community-grants/"},
    {"name": "Bare root", "source_url": "https://floss.fund/"},
    {"name": "Root no slash", "source_url": "https://iliad.ac"},
    {"name": "Locale-only path", "source_url": "https://www.prototypefund.de/en"},
    {"name": "About-only path", "source_url": "https://example.net/about/"},
    {"name": "Hyphenated about-us", "source_url": "https://arbitrumgamingventures.com/about-us"},
    {"name": "Blog-only path", "source_url": "https://example.org/blog/"},
    {"name": "Missing url", "source_url": ""},
    {"name": "Placeholder", "source_url": "https://example.com/TODO"},
    {"name": "No TLD", "source_url": "https://www"},
    {"name": "Real tweet", "source_url": "https://x.com/i/status/1234567890123456789"},
    {"name": "Truncated tweet", "source_url": "https://x.com/i/statu"},
    {"name": "X profile", "source_url": "https://x.com/someprogram"},
    {"name": "t.co shortlink", "source_url": "https://t.co/abc123"}
  ],
  "rejected": [{"name": "pre-existing", "classification": "NEWS", "reason": "not funding"}]
}
JSON
cp "$TMP/opps.json" "$TMP/a.json"
out="$(python3 "$ROOT/lib/url_gate.py" "$TMP/a.json" 2>&1)"; rc=$?
[ "$rc" = "0" ] && ok "url_gate exits 0" || bad "url_gate rc=$rc: $out"
if [ -f "$TMP/a.json" ]; then
python3 - "$TMP/a.json" <<'PY' || bad "url gate contract"
import json, sys
d = json.load(open(sys.argv[1]))
kept = {o["name"] for o in d["opportunities"]}
rej = {r["name"]: r for r in d["rejected"]}
fails = 0
def check(label, cond):
    global fails
    if cond: print(f"  ok: {label}")
    else: print(f"  FAIL: {label}", file=sys.stderr); fails += 1
check("deep path kept", "Deep path is fine" in kept)
check("nested path kept", "Nested path is fine" in kept)
check("bare root dropped", "Bare root" in rej)
check("root without trailing slash dropped", "Root no slash" in rej)
check("locale-only path dropped", "Locale-only path" in rej)
check("about-only path dropped", "About-only path" in rej)
# isUsefulUrl matches generic segments EXACTLY, so /about-us is a real page to the Wire Room.
# A gate stricter than intake would drop finds intake would have accepted.
check("hyphenated about-us kept (intake accepts it)", "Hyphenated about-us" in kept)
check("blog-only path dropped", "Blog-only path" in rej)
check("empty url dropped", "Missing url" in rej)
check("placeholder dropped", "Placeholder" in rej)
check("host without a TLD dropped", "No TLD" in rej)
check("full-length tweet id kept", "Real tweet" in kept)
check("truncated tweet id dropped", "Truncated tweet" in rej)
check("x profile kept", "X profile" in kept)
check("t.co shortlink kept", "t.co shortlink" in kept)
check("pre-existing rejections preserved", "pre-existing" in rej)
# The reason must tell the model what to do, since this is the fix that reclaims the find.
r = rej.get("Bare root", {})
check("rejection is classified NOISE", r.get("classification") == "NOISE")
check("reason names the rule", "canonical" in (r.get("reason") or "").lower()
                               or "path" in (r.get("reason") or "").lower())
check("rejection keeps the url for triage", r.get("source_url") == "https://floss.fund/")
check("gate records a funnel count", d.get("url_gate", {}).get("dropped") == 9)
sys.exit(1 if fails else 0)
PY
fi

echo "== B. URL gate is safe on the edges =="
echo '{"opportunities": [], "rejected": []}' > "$TMP/empty.json"
python3 "$ROOT/lib/url_gate.py" "$TMP/empty.json" >/dev/null 2>&1 \
  && ok "empty opportunity list is a no-op" || bad "empty list errored"
echo '{"wire": "oss"}' > "$TMP/nokey.json"
python3 "$ROOT/lib/url_gate.py" "$TMP/nokey.json" >/dev/null 2>&1 \
  && ok "payload without an opportunities key survives" || bad "missing key errored"
python3 "$ROOT/lib/url_gate.py" "$TMP/does-not-exist.json" >/dev/null 2>&1 \
  && bad "missing file should not exit 0" || ok "missing file exits non-zero"

echo "== C. the prompt tells the producer the rule (so it can comply, not just be filtered) =="
P="$(cd "$ROOT" && SCOUT_PRIME_KNOWN=0 ./run-producer.sh --wire oss --variant A --render-only 2>/dev/null \
     | sed -n 's/^RUN_DIR=//p' | tail -1)/prompt.txt"
if [ -f "$P" ]; then
  grep -qiF "never a bare domain root" "$P" && ok "prompt forbids bare domain roots" \
                                            || bad "prompt does not forbid domain roots"
  grep -qiF "/en" "$P" && ok "prompt names the locale-only trap" || bad "prompt misses locale-only paths"
else
  bad "could not render prompt for the URL-rule check"
fi
rm -rf "$ROOT"/runs/oss/A/*-2026-* 2>/dev/null

echo "== D. known-programs priming — the producer's OWN repeats, and decided programs =="
# The old list was "150 most recent names for this wire, any source". The ai wire has 2,807
# distinct names in 120 days, so the cap was filled by other feeds' last few days and the
# producer's own repeat offenders fell off it entirely.
cat > "$TMP/known.json" <<'JSON'
{
  "known": [
    ["Avalanche Team1 Builder Grants", "self"],
    ["NSF CISE Future Computing Research (Future CoRe)", "self"],
    ["Snorkel AI Open Benchmarks Grant", "self"],
    ["Solana Foundation Grants Program", "decided"],
    ["Some Other Feed Item", "decided"]
  ]
}
JSON
out="$(env PYTHONPATH="$TMP/stub:$ROOT/lib" STUB_DB_FIXTURE="$TMP/known.json" \
      DATABASE_URL="postgresql://stub/stub" SCOUT_SCAN_SOURCE=claude-code \
      python3 "$ROOT/lib/known_programs.py" crypto 2>&1)"
grep -qF "Avalanche Team1 Builder Grants" <<<"$out" && ok "primes with the producer's own repeat" \
                                                    || bad "own repeat missing: $out"
grep -qF "Solana Foundation Grants Program" <<<"$out" && ok "primes with decided programs" \
                                                      || bad "decided program missing"
grep -qiE "you (have )?(already )?(reported|submitted)|your own" <<<"$out" \
  && ok "list separates the producer's own finds from the rest" \
  || bad "list does not mark the producer's own finds"
grep -qiF "new round" <<<"$out" || grep -qiF "NEW round" <<<"$out" \
  && ok "keeps the new-cycle carve-out" || bad "lost the new-cycle carve-out"

# Best-effort contract: the producer must still run with no DB.
out="$(env PYTHONPATH="$TMP/stub:$ROOT/lib" DATABASE_URL= \
      python3 "$ROOT/lib/known_programs.py" crypto 2>&1)"; rc=$?
[ "$rc" = "0" ] && [ -z "$out" ] && ok "no DATABASE_URL: silent, exit 0" || bad "no-DB path rc=$rc out=$out"
out="$(env PYTHONPATH="$TMP/stub:$ROOT/lib" STUB_DB_FIXTURE="$TMP/known.json" STUB_DB_FAIL=1 \
      DATABASE_URL="postgresql://stub/stub" python3 "$ROOT/lib/known_programs.py" crypto 2>&1)"; rc=$?
[ "$rc" = "0" ] && [ -z "$out" ] && ok "DB down: silent, exit 0" || bad "DB-down path rc=$rc out=$out"

echo "== E. name dedup — same program, different URL =="
# Only NEGATIVE operator verdicts (declined / archived) drop a name. Measured over 60 days
# of both lanes: this set stops 18 wasted rows and costs 1 approval, where including
# `approved` costs 2 and including `duplicate`/`deduped` costs 4. A returning APPROVED
# program is usually its next cycle, which the prompt explicitly asks for.
# The query must therefore ask for declined/archived and nothing else.
grep -q "_REJECTED_BY_OPERATOR = (\"declined\", \"archived\")" "$ROOT/lib/name_dedup.py" \
  && ok "drop set is negative verdicts only" || bad "drop set is not declined/archived only"
grep -qE "'?(approved|duplicate|deduped)'?" <<<"$(sed -n '/_REJECTED_BY_OPERATOR = /p' "$ROOT/lib/name_dedup.py")" \
  && bad "approved/duplicate leaked into the drop set" || ok "approved and duplicate stay out of the drop set"
cat > "$TMP/names.json" <<'JSON'
{
  "seen_names": [
    ["Avalanche Team1 Builder Grants"],
    ["NSF CISE Future Computing Research (Future CoRe)"]
  ]
}
JSON
cat > "$TMP/d.json" <<'JSON'
{
  "wire": "crypto",
  "opportunities": [
    {"name": "Avalanche Team1 Builder Grants", "source_url": "https://build.avax.network/team1"},
    {"name": "  avalanche   team1 builder GRANTS  ", "source_url": "https://avax.example/other"},
    {"name": "NSF CISE Future Computing Research (Future CoRe)", "source_url": "https://nsf.gov/x"},
    {"name": "Genuinely New Fund", "source_url": "https://newfund.example/apply"}
  ],
  "rejected": []
}
JSON
out="$(env PYTHONPATH="$TMP/stub:$ROOT/lib" STUB_DB_FIXTURE="$TMP/names.json" \
      DATABASE_URL="postgresql://stub/stub" \
      python3 "$ROOT/lib/name_dedup.py" "$TMP/d.json" crypto 2>&1)"; rc=$?
[ "$rc" = "0" ] && ok "name_dedup exits 0" || bad "name_dedup rc=$rc: $out"
python3 - "$TMP/d.json" <<'PY' || bad "name dedup contract"
import json, sys
d = json.load(open(sys.argv[1]))
kept = [o["name"] for o in d["opportunities"]]
rej = {r["name"]: r for r in d["rejected"]}
fails = 0
def check(label, cond):
    global fails
    if cond: print(f"  ok: {label}")
    else: print(f"  FAIL: {label}", file=sys.stderr); fails += 1
check("exact name match dropped", "Avalanche Team1 Builder Grants" not in kept)
check("case/whitespace variant dropped", not any("avalanche" in k.lower() for k in kept))
check("second known name dropped", not any("Future CoRe" in k for k in kept))
check("genuinely new name kept", "Genuinely New Fund" in kept)
check("only the new one survives", len(kept) == 1)
r = next(iter(rej.values()))
check("dropped rows classified DUPLICATE", r.get("classification") == "DUPLICATE")
check("reason names the name match", "name" in (r.get("reason") or "").lower())
check("reason says it was the operator's own verdict",
      "declined" in (r.get("reason") or "").lower() or "archived" in (r.get("reason") or "").lower())
sys.exit(1 if fails else 0)
PY

# Kill switch, matching SCOUT_PRIME_KNOWN's convention.
cp "$TMP/d.json" "$TMP/off.json" 2>/dev/null || true
cat > "$TMP/off.json" <<'JSON'
{"wire":"crypto","opportunities":[{"name":"Avalanche Team1 Builder Grants","source_url":"https://x.example/a"}],"rejected":[]}
JSON
env PYTHONPATH="$TMP/stub:$ROOT/lib" STUB_DB_FIXTURE="$TMP/names.json"     DATABASE_URL="postgresql://stub/stub" SCOUT_NAME_DEDUP=0     python3 "$ROOT/lib/name_dedup.py" "$TMP/off.json" crypto >/dev/null 2>&1
n="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["opportunities"]))' "$TMP/off.json")"
[ "$n" = "1" ] && ok "SCOUT_NAME_DEDUP=0 keeps everything" || bad "kill switch did not disable (kept=$n)"

# No DB must not block delivery — this runs inside the cron path.
cp "$TMP/opps.json" "$TMP/nodb.json"
out="$(env PYTHONPATH="$TMP/stub:$ROOT/lib" DATABASE_URL= \
      python3 "$ROOT/lib/name_dedup.py" "$TMP/nodb.json" oss 2>&1)"; rc=$?
n="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["opportunities"]))' "$TMP/nodb.json")"
[ "$rc" = "0" ] && [ "$n" = "15" ] && ok "no DATABASE_URL: keeps everything, exit 0" \
                                  || bad "no-DB name dedup rc=$rc kept=$n"

echo "== F. both gates are wired into the producer run =="
grep -q "url_gate.py" "$ROOT/run-producer.sh" && ok "url_gate wired into run-producer.sh" \
                                              || bad "url_gate not wired in"
grep -q "name_dedup.py" "$ROOT/run-producer.sh" && ok "name_dedup wired into run-producer.sh" \
                                                || bad "name_dedup not wired in"
# The URL gate must run BEFORE verify: no point fetching a URL the Wire Room will archive.
gate_line="$(grep -n "url_gate.py" "$ROOT/run-producer.sh" | head -1 | cut -d: -f1)"
ver_line="$(grep -n "verify.py" "$ROOT/run-producer.sh" | head -1 | cut -d: -f1)"
[ -n "$gate_line" ] && [ -n "$ver_line" ] && [ "$gate_line" -lt "$ver_line" ] \
  && ok "url gate runs before verify" || bad "url gate must precede verify (gate=$gate_line verify=$ver_line)"

echo
echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ] && echo "ALL PASS"
exit $(( FAILN>0 ? 1 : 0 ))
