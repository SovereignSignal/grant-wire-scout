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
    "wire": "crypto", "amount": "$10k", "deadline": "2026-12-31",
    "summary": "Apply now.", "classification": "GRANT", "fit_score": 80,
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
