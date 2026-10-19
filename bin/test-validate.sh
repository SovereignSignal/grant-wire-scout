#!/usr/bin/env bash
# test-validate.sh — schema gate + skip-if-fed + require-verified.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAILN=0
ok(){ echo "  ok: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1" >&2; FAILN=$((FAILN+1)); }

echo "== validate.py =="
python3 - "$ROOT" <<'PY'
import json, os, sys, tempfile
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import validate
fails = 0
def check(label, cond):
    global fails
    if cond: print(f"  ok: {label}")
    else: print(f"  FAIL: {label}", file=sys.stderr); fails += 1

good = {
    "name": "Test Grant", "source_url": "https://example.com/g",
    "wire": "crypto", "amount": "$10k", "deadline": "2099-12-31",
    "summary": "Apply now.", "area": 3, "classification": "GRANT", "fit_score": 80,
    "fit_reason": "fresh", "evidence": ["https://example.com/g"],
    "discovered_via": "web_search",
}
payload = {
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "generated_at": "2026-08-29T00:00:00Z",
    "opportunities": [good, {**good, "classification": "MAYBE", "source_url": "not-a-url"}],
    "rejected": [],
}
out = validate.validate_payload(json.loads(json.dumps(payload)))
check("keeps the valid item", len(out["opportunities"]) == 1)
check("rejects the schema-invalid item", len(out["rejected"]) == 1)
check("rejection reason names schema", "schema:" in (out["rejected"][0].get("reason") or ""))

try:
    validate.validate_payload({"opportunities": []})
    check("missing top keys must raise", False)
except ValueError:
    check("missing top keys must raise", True)

u = {**good, "verification": {"status": "unverified"}}
p = {"opportunities": [good, u], "rejected": []}
p = validate.drop_unverified(p)
check("REQUIRE_VERIFIED keeps verified/unspecified", len(p["opportunities"]) == 1)
check("REQUIRE_VERIFIED drops unverified", len(p["rejected"]) == 1)

award = {**good, "name": "Round results", "area": 2, "classification": "GRANT",
         "source_url": "https://example.com/results", "summary": "The funder named the recipients."}
aw = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [award], "rejected": [],
})))
check("award or results announcement is not submitted", len(aw["opportunities"]) == 0 and len(aw["rejected"]) == 1)
check("award rejection names the announcement", "award" in (aw["rejected"][0].get("reason") or "").lower())
check("award rejection is NEWS", aw["rejected"][0]["classification"] == "NEWS")

budget = {**good, "name": "Treasury budget", "area": 1, "classification": "NEWS",
          "summary": "The DAO passed a budget for grants."}
bg = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [budget], "rejected": [],
})))
check("budget or policy news is not submitted", len(bg["opportunities"]) == 0)
check("budget rejection names budget", "budget" in (bg["rejected"][0].get("reason") or "").lower())

closed = {**good, "name": "Closed round", "deadline": "2020-01-15", "summary": "Apply by the deadline."}
cl = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [closed], "rejected": [],
})))
check("past deadline is not submitted", len(cl["opportunities"]) == 0)
check("past deadline is EXPIRED", cl["rejected"][0]["classification"] == "EXPIRED")
check("past deadline reason names the closed call", "closed" in (cl["rejected"][0].get("reason") or "").lower())

unknown = {**good, "name": "No date", "deadline": "unknown", "summary": "Apply somehow."}
un = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [unknown], "rejected": [],
})))
check("unknown deadline is not submitted", len(un["opportunities"]) == 0)
check("unknown deadline asks for a future date or rolling intake",
      "rolling" in (un["rejected"][0].get("reason") or "").lower())

rolling = {**good, "name": "Rolling intake", "deadline": "rolling",
           "summary": "Applications are open. Submit the form on the program page."}
ro = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [rolling], "rejected": [],
})))
check("rolling intake is kept", len(ro["opportunities"]) == 1)
check("rolling intake is GRANT", ro["opportunities"][0]["classification"] == "GRANT")

no_apply = {**good, "name": "Mystery fund", "source_url": "https://example.com/notes",
            "summary": "The foundation has money for builders this year."}
na = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [no_apply], "rejected": [],
})))
check("row with no way to apply is not submitted", len(na["opportunities"]) == 0)
check("missing apply path is named", "apply" in (na["rejected"][0].get("reason") or "").lower())

mislabeled = {**good, "name": "ESP round", "area": 3,
              "summary": "The funder announced the recipients of the round."}
ml = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [mislabeled], "rejected": [],
})))
check("results copy labeled as an open call is not submitted", len(ml["opportunities"]) == 0)

shut = {**good, "name": "Shut call", "summary": "Applications are closed for this round."}
sh = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [shut], "rejected": [],
})))
check("closed-window copy is not submitted", len(sh["opportunities"]) == 0)
check("closed-window rejection is EXPIRED", sh["rejected"][0]["classification"] == "EXPIRED")

import datetime
today = datetime.date(2026, 10, 19)
still_open = dict(good)
still_open["deadline"] = "2026-10-19"
check("deadline of today is still an open call",
      validate.open_call_rejection(still_open, today=today) is None)
yesterday = dict(good)
yesterday["deadline"] = "2026-10-18"
check("deadline of yesterday is a past call",
      "closed" in (validate.open_call_rejection(yesterday, today=today) or "").lower())

opened = {**good, "name": "Open call", "area": "3", "classification": "NEWS"}
op = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [opened], "rejected": [],
})))
check("string area 3 coerces to int", op["opportunities"][0]["area"] == 3)
check("area 3 is labeled GRANT", op["opportunities"][0]["classification"] == "GRANT")

missing = {**good, "name": "No area"}
del missing["area"]
ms = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [missing], "rejected": [],
})))
check("missing area is rejected", len(ms["opportunities"]) == 0 and len(ms["rejected"]) == 1)
check("missing area reason names area", "area" in (ms["rejected"][0].get("reason") or ""))

out_item = {**good, "name": "Equity raise", "area": "out", "classification": "NEWS"}
ot = validate.validate_payload(json.loads(json.dumps({
    "producer": "claude-code", "variant": "A", "wire": "crypto",
    "opportunities": [out_item], "rejected": [],
})))
check("OUT area is rejected", len(ot["opportunities"]) == 0)
check("OUT reason names OUT", "OUT" in (ot["rejected"][0].get("reason") or ""))

import submit
body, delivered = submit.build_submission_body(
    [good, award, out_item, missing], "crypto", "A", "2026-10-04", "claude-code")
raw = json.loads(body["rawText"])["opportunities"]
check("submit body keeps only the open call", len(raw) == 1 and len(delivered) == 1)
by_name = {o["name"]: o for o in raw}
check("submit labels the open call GRANT", by_name["Test Grant"]["classification"] == "GRANT" and by_name["Test Grant"]["area"] == 3)
check("submit drops the award announcement", "Round results" not in by_name)
check("submit body carries area", all("area" in o for o in raw))
check("submit drops OUT and missing area", "Equity raise" not in by_name and "No area" not in by_name)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "validate.py matrix" || bad "validate.py matrix"

echo "== skip_if_fed.py =="
out="$(env -u SCOUT_SKIP_IF_FED_HOURS -u DATABASE_URL \
       python3 "$ROOT/lib/skip_if_fed.py" crypto)"; rc=$?
[ "$rc" -eq 0 ] && ok "unset hours -> rc=0 (run)" || bad "unset hours rc=$rc"

out="$(env SCOUT_SKIP_IF_FED_HOURS=0 DATABASE_URL= \
       python3 "$ROOT/lib/skip_if_fed.py" crypto)"; rc=$?
[ "$rc" -eq 0 ] && ok "hours=0 -> rc=0 (run)" || bad "hours=0 rc=$rc"

out="$(env SCOUT_SKIP_IF_FED_HOURS=nope python3 "$ROOT/lib/skip_if_fed.py" crypto 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "bad hours -> rc=2" || bad "bad hours rc=$rc"

# Stub psycopg2: other lane has 3 rows -> skip 10
TMP="$(mktemp -d)"
cat > "$TMP/psycopg2.py" <<'PY'
class _Cur:
    def execute(self, sql, params=None): self.n = 3
    def fetchone(self): return (self.n,)
    def __enter__(self): return self
    def __exit__(self, *a): return False
class _Conn:
    def cursor(self): return _Cur()
    def close(self): pass
def connect(dsn, *a, **k): return _Conn()
PY
out="$(env PYTHONPATH="$TMP" DATABASE_URL=postgresql://stub/stub \
       SCOUT_SKIP_IF_FED_HOURS=36 SCOUT_SCAN_SOURCE=claude-code \
       python3 "$ROOT/lib/skip_if_fed.py" oss)"; rc=$?
[ "$rc" -eq 10 ] && ok "other lane fed -> rc=10 (skip)" || bad "fed skip rc=$rc"
printf '%s\n' "$out" | grep -q "skipping" && ok "skip names the wire" || bad "skip log: $out"
rm -rf "$TMP"

# Stub: 0 rows -> run
TMP="$(mktemp -d)"
cat > "$TMP/psycopg2.py" <<'PY'
class _Cur:
    def execute(self, sql, params=None): self.n = 0
    def fetchone(self): return (0,)
    def __enter__(self): return self
    def __exit__(self, *a): return False
class _Conn:
    def cursor(self): return _Cur()
    def close(self): pass
def connect(dsn, *a, **k): return _Conn()
PY
out="$(env PYTHONPATH="$TMP" DATABASE_URL=postgresql://stub/stub \
       SCOUT_SKIP_IF_FED_HOURS=36 SCOUT_SCAN_SOURCE=claude-code \
       python3 "$ROOT/lib/skip_if_fed.py" oss)"; rc=$?
[ "$rc" -eq 0 ] && ok "other lane quiet -> rc=0 (run)" || bad "quiet rc=$rc"
rm -rf "$TMP"

echo
echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
