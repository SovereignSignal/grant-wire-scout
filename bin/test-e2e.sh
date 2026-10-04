#!/usr/bin/env bash
# test-e2e.sh — strenuous end-to-end test of the Grant Wire Scout pipeline.
#
# Runs the FULL bin/run-scout.sh (prompt render -> prime -> claude -> extract -> verify ->
# dedup -> report -> submit -> ledger -> alert) against a LOCAL mock Wire Room and a STUBBED
# claude. Hermetic: no network, no Claude quota, no prod side effects, deterministic, seconds.
#
# Coverage:
#   A happy path        -> delivered to Wire Room, NO alert, rc=0
#   B timeout, nothing flushed -> "TIMEOUT" alert + rc=124     (unrecoverable kill)
#   C auth              -> "AUTH" alert
#   D quota             -> "QUOTA" alert
#   E empty output      -> "EMPTY" alert
#   F malformed JSON    -> "FAILED" alert (extract parse failure)
#   G delivery HTTP 500 -> "DELIVERY" alert, nonzero exit
#   H timeout after flush -> delivered, NO alert, rc=0         (salvage)
#   I timeout, nothing flushed, resumed session flushes -> delivered, NO alert, rc=0
#
# Alerts are captured via notify.py's webhook fallback (NOTIFY_WEBHOOK_URL) pointed at the
# mock — no prod code change. Wire Room submit/seen-urls are mocked. DATABASE_URL is unset so
# ledger/prime no-op cleanly.
#
# Gated LIVE smoke: E2E_LIVE=1 runs ONE real `run-scout crypto A` against the prod env
# (needs real env vars, ~$3, delivers to the real Wire Room) and asserts rc=0.
#
# Portable: macOS /bin/bash is 3.2 (no associative arrays); this re-execs under bash>=4 and
# puts it first on PATH so the scripts' `#!/usr/bin/env bash` and `timeout` resolve correctly.

# --- re-exec under bash >= 4 if needed ---
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
    [ -x "$b" ] && [ "$("$b" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)" -ge 4 ] 2>/dev/null && exec "$b" "$0" "$@"
  done
  echo "test-e2e: need bash >= 4 (macOS default is 3.2; install via 'brew install bash')" >&2; exit 1
fi
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAILN=0
ok(){ echo "  ok: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1" >&2; FAILN=$((FAILN+1)); }

# --- gated live smoke -------------------------------------------------------
if [ "${E2E_LIVE:-0}" = "1" ]; then
  echo "== LIVE smoke: real run-scout crypto A (prod env, ~\$3, delivers for real) =="
  "$ROOT/bin/run-scout.sh" crypto A; rc=$?
  [ "$rc" -eq 0 ] && ok "live run-scout rc=0 (check scout_runs for a fresh ok row)" || bad "live run-scout rc=$rc"
  echo "PASS=$PASS FAIL=$FAILN"; [ "$FAILN" -eq 0 ] && echo "ALL PASS"; exit $(( FAILN>0 ? 1 : 0 ))
fi

# --- hermetic harness -------------------------------------------------------
TMP="$(mktemp -d)"; CAP="$TMP/cap"; mkdir -p "$CAP" "$TMP/bin"
MOCK_PID=""; RUN_DIRS=()
c_end(){ [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$TMP"
         for d in "${RUN_DIRS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done; }
trap c_end EXIT

ln -sf "$BASH" "$TMP/bin/bash"   # modern bash first on PATH -> #!/usr/bin/env bash resolves here

# portable coreutils-`timeout` shim (macOS has none; prod Linux uses the real one).
# The timer is a DIRECT background `sleep` killed by pid — NOT a `( sleep; kill ) &` subshell,
# whose sleep child would orphan on kill and hold the caller's command-substitution pipe open.
cat > "$TMP/bin/timeout" <<'SH'
#!/usr/bin/env bash
[ "$1" = "-k" ] && shift 2   # accept GNU `-k GRACE` (the producer passes it)
dur="$1"; shift
"$@" & cmd=$!
sleep "$dur" & slp=$!
rc=""
while kill -0 "$cmd" 2>/dev/null; do
  kill -0 "$slp" 2>/dev/null || { kill -TERM "$cmd" 2>/dev/null; wait "$cmd" 2>/dev/null; rc=124; break; }
  sleep 0.2
done
[ -z "$rc" ] && { wait "$cmd" 2>/dev/null; rc=$?; }
kill -TERM "$slp" 2>/dev/null; wait "$slp" 2>/dev/null
[ "$rc" -ge 128 ] && rc=124
exit "$rc"
SH

# stubbed `claude` — CLAUDE_STUB_MODE picks the outcome; emits a `claude -p --output-format json` envelope
cat > "$TMP/bin/claude" <<'PY'
#!/usr/bin/env python3
import os, sys, time, json
mode = os.environ.get("CLAUDE_STUB_MODE", "ok")
base = os.environ.get("MOCK_BASE", "http://127.0.0.1")
def out(result, is_error=False, **x):
    d = {"result": result, "total_cost_usd": 0.01, "duration_ms": 100, "is_error": is_error}
    d.update(x); sys.stdout.write(json.dumps(d)); sys.stdout.flush()
def payload():
    return {"producer": "claude-code", "variant": "A", "wire": "crypto", "run_id": "e2e",
         "generated_at": "2026-07-01T00:00:00Z", "rejected": [],
         "opportunities": [{"name": "E2E Test Grant", "source_url": base + "/g1", "wire": "crypto",
             "amount": "$10k", "deadline": "2026-12-31", "summary": "Test grant.", "area": 3, "classification": "GRANT",
             "fit_score": 80, "fit_reason": "test", "evidence": [base + "/g1"], "discovered_via": "web_search"}]}
if "--resume" in sys.argv:
    # The producer's resume-flush after a wall-clock kill. STUB_RESUME=payload plays a
    # session that had verified finds; the default plays one that had nothing to give.
    if os.environ.get("STUB_RESUME") == "payload":
        out(json.dumps(payload())); sys.exit(0)
    out(json.dumps({**payload(), "opportunities": []})); sys.exit(0)
if mode == "slow":
    time.sleep(int(os.environ.get("STUB_SLEEP", "5")))
    out(json.dumps(payload())); sys.exit(0)
if mode == "flush-then-slow":
    out(json.dumps(payload()))
    time.sleep(int(os.environ.get("STUB_SLEEP", "5")))
    sys.exit(0)
if mode == "ok":
    out(json.dumps(payload())); sys.exit(0)
if mode == "auth":  out("Error 401 unauthorized: oauth token invalid", is_error=True, subtype="error", api_error_status="401"); sys.exit(1)
if mode == "quota": out("HTTP 429 rate limit: usage limit reached", is_error=True, subtype="error", api_error_status="429"); sys.exit(1)
if mode == "empty": out(""); sys.exit(0)
if mode == "malformed": out("this is not json {["); sys.exit(0)
out(""); sys.exit(0)
PY
chmod +x "$TMP/bin/timeout" "$TMP/bin/claude"

# mock Wire Room: seen-urls (GET), submit (POST), webhook alert sink (POST), opp pages (GET)
cat > "$TMP/mock.py" <<'PY'
import sys, os, json
from http.server import BaseHTTPRequestHandler, HTTPServer
CAP = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def s(self, code, obj=None):
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers()
        if obj is not None: self.wfile.write(json.dumps(obj).encode())
    def do_GET(self):
        if self.path.startswith("/api/scan/seen-urls"): self.s(200, [])
        else: self.s(200, {"ok": True})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); b = self.rfile.read(n)
        if self.path.startswith("/api/scan/submit"):
            open(os.path.join(CAP, "submit.json"), "wb").write(b)
            if os.path.exists(os.path.join(CAP, "force_500")): self.s(500, {"error": "boom"})
            else: self.s(200, {"ok": True, "totalIngested": 1, "newUnique": 1})
        elif self.path.startswith("/webhook"):
            try: subj = json.loads(b).get("subject", "")
            except Exception: subj = b.decode("utf-8", "ignore")
            open(os.path.join(CAP, "alerts.log"), "a").write(subj + "\n"); self.s(200, {"ok": True})
        else: self.s(200, {"ok": True})
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(CAP, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP/mock.py" "$CAP" & MOCK_PID=$!
for _ in $(seq 1 50); do [ -s "$CAP/port" ] && break; sleep 0.1; done
PORT="$(cat "$CAP/port" 2>/dev/null || true)"; [ -n "$PORT" ] || { echo "mock failed to start" >&2; exit 1; }
BASEURL="http://127.0.0.1:$PORT"

run_case(){ # <mode> [EXTRA_ENV=val ...]
  local mode="$1"; shift
  rm -f "$CAP/submit.json" "$CAP/alerts.log"
  CASE_OUT="$(env PATH="$TMP/bin:$PATH" CLAUDE="$TMP/bin/claude" CLAUDE_STUB_MODE="$mode" \
     MOCK_BASE="$BASEURL" WIRE_ROOM_API="$BASEURL" INTERNAL_API_KEY=test \
     NOTIFY_WEBHOOK_URL="$BASEURL/webhook" SCOUT_PRIME_KNOWN=0 MODEL=stub \
     SCOUT_SKIP_IF_FED_HOURS= SCOUT_REQUIRE_VERIFIED=0 "$@" \
     "$TMP/bin/bash" "$ROOT/bin/run-scout.sh" crypto A 2>&1)"; CASE_RC=$?
  local d; d="$(printf '%s\n' "$CASE_OUT" | sed -n 's/^RUN_DIR=//p' | tail -1)"
  [ -n "$d" ] && RUN_DIRS+=("$d")
}
alerts(){ cat "$CAP/alerts.log" 2>/dev/null || true; }

echo "== A happy path: delivered + no alert =="
run_case ok
[ "$CASE_RC" -eq 0 ] && ok "rc=0" || { printf '%s\n' "$CASE_OUT" | tail -15; bad "happy rc=$CASE_RC"; }
[ -s "$CAP/submit.json" ] && ok "delivered to Wire Room" || bad "no submit captured"
python3 - "$CAP/submit.json" <<'PY' && ok "submit body has area 3 labeled GRANT" || bad "submit body missing area or mislabeled GRANT"
import json, sys
body = json.load(open(sys.argv[1]))
opps = json.loads(body["rawText"])["opportunities"]
assert len(opps) == 1, opps
assert opps[0]["area"] == 3, opps[0]
assert opps[0]["classification"] == "GRANT", opps[0]
PY
[ -z "$(alerts)" ] && ok "no alert fired" || bad "unexpected alert: $(alerts)"
printf '%s\n' "$CASE_OUT" | grep -q '\[grok\] cli version' \
  && bad "claude run logged a grok cli version" || ok "claude run does not touch the grok cli"

echo "== B timeout, nothing flushed -> rc=124 + TIMEOUT alert =="
run_case slow SCOUT_PRODUCER_TIMEOUT=2 STUB_SLEEP=5
[ "$CASE_RC" -eq 124 ] && ok "rc=124" || bad "timeout rc=$CASE_RC"
alerts | grep -q "TIMEOUT" && ok "alert: TIMEOUT" || bad "alert not TIMEOUT: $(alerts)"
[ -z "$(cat "$CAP/submit.json" 2>/dev/null)" ] && ok "unrecoverable timeout did not submit" \
  || bad "unrecoverable timeout still submitted"
printf '%s\n' "$CASE_OUT" | grep -q "resumed session had verified nothing" \
  && ok "log says the resumed session had nothing to flush" || bad "timeout log lacks the resume outcome"

echo "== C auth -> AUTH alert =="
run_case auth
alerts | grep -q "AUTH" && ok "alert: AUTH" || bad "alert not AUTH: $(alerts)"

echo "== D quota -> QUOTA alert =="
run_case quota
alerts | grep -q "QUOTA" && ok "alert: QUOTA" || bad "alert not QUOTA: $(alerts)"

echo "== E empty -> EMPTY alert =="
run_case empty
alerts | grep -q "EMPTY" && ok "alert: EMPTY" || bad "alert not EMPTY: $(alerts)"

echo "== F malformed JSON -> FAILED alert =="
run_case malformed
alerts | grep -q "FAILED" && ok "alert: FAILED (parse)" || bad "alert not FAILED: $(alerts)"

echo "== G delivery HTTP 500 -> DELIVERY alert + nonzero =="
: > "$CAP/force_500"; run_case ok; rm -f "$CAP/force_500"
[ "$CASE_RC" -ne 0 ] && ok "rc nonzero ($CASE_RC)" || bad "delivery-fail rc=0"
alerts | grep -qi "DELIVERY" && ok "alert: DELIVERY" || bad "alert not DELIVERY: $(alerts)"

echo "== H timeout after flush -> salvage + deliver + no alert =="
run_case flush-then-slow SCOUT_PRODUCER_TIMEOUT=2 STUB_SLEEP=5
[ "$CASE_RC" -eq 0 ] && ok "salvage rc=0" || { printf '%s\n' "$CASE_OUT" | tail -20; bad "salvage rc=$CASE_RC"; }
[ -s "$CAP/submit.json" ] && ok "salvaged find delivered" || bad "salvage did not submit"
[ -z "$(alerts)" ] && ok "no TIMEOUT alert after salvage" || bad "salvage still alerted: $(alerts)"

echo "== I timeout, nothing flushed, resume flush recovers -> deliver + no alert =="
run_case slow SCOUT_PRODUCER_TIMEOUT=2 STUB_SLEEP=5 STUB_RESUME=payload
[ "$CASE_RC" -eq 0 ] && ok "resume-flush rc=0" || { printf '%s\n' "$CASE_OUT" | tail -20; bad "resume-flush rc=$CASE_RC"; }
[ -s "$CAP/submit.json" ] && ok "resumed session's finds delivered" || bad "resume flush did not submit"
[ -z "$(alerts)" ] && ok "no TIMEOUT alert after resume flush" || bad "resume flush still alerted: $(alerts)"
printf '%s\n' "$CASE_OUT" | grep -q "via resume flush" && ok "producer logged the resume salvage" \
  || bad "producer did not log the resume salvage"

echo
echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
