#!/usr/bin/env bash
# test-heartbeat.sh — hermetic test of the dead-man's-switch (lib/heartbeat.py).
#
# The heartbeat had NO coverage until 2026-08-05, when it fired a TRUE alert (oss delivered
# 0 rows) carrying a FALSE cause ("the scout cron may be down, or the claude OAuth token may
# have expired") — while the scout_runs ledger showed a clean $3.00 run that simply found
# nothing. It also returned 1 on that successful detection, so Railway's restartPolicyType
# =NEVER reported a correctly-working monitor as "Deploy Crashed!".
#
# This pins both contracts:
#
#   CAUSE  — diagnose() reads the scout_runs ledger and names the REAL cause per wire:
#     no-run             no ledger row in the window          -> cron down / container never started
#     auth|quota|failed  the run itself failed                -> the run's own error class
#     zero-yield         status=ok, opportunity_count=0       -> ran clean, found nothing (thin day)
#     lost-in-delivery   status=ok, opps>0, but 0 rows landed -> broke between submit and the queue
#
#   EXIT   — a firing dead-man's-switch is NOT a crashed deploy:
#     0  all wires healthy
#     0  silent wire(s) detected AND the alert was delivered   (detection worked)
#     1  alert delivery failed                                  (Railway's crash mail = backstop)
#     2  the heartbeat could not do its job (no DSN / DB down)
#
# Hermetic: psycopg2 is stubbed on PYTHONPATH from a JSON fixture, alerts are captured via
# notify.py's webhook fallback pointed at a local mock. No network, no prod side effects.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAILN=0
ok(){ echo "  ok: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1" >&2; FAILN=$((FAILN+1)); }

TMP="$(mktemp -d)"; CAP="$TMP/cap"; mkdir -p "$CAP" "$TMP/stub"
MOCK_PID=""
c_end(){ [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$TMP"; }
trap c_end EXIT

# --- stub psycopg2: canned rows from $STUB_DB_FIXTURE, dispatched by table name -------------
cat > "$TMP/stub/psycopg2.py" <<'PY'
import json, os
class _Cur:
    def __init__(self, fx): self.fx = fx; self.rows = []
    def execute(self, sql, params=None):
        self.rows = [tuple(r) for r in self.fx.get("runs" if "scout_runs" in sql else "counts", [])]
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
    if os.environ.get("STUB_DB_FAIL") == "1": raise RuntimeError("could not connect to server")
    return _Conn(json.load(open(os.environ["STUB_DB_FIXTURE"])))
PY

# --- mock alert sink: records subject + body so the CAUSE text is assertable ----------------
cat > "$TMP/mock.py" <<'PY'
import sys, os, json
from http.server import BaseHTTPRequestHandler, HTTPServer
CAP = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); b = self.rfile.read(n)
        code = 500 if os.path.exists(os.path.join(CAP, "force_500")) else 200
        if code == 200:
            try: d = json.loads(b)
            except Exception: d = {"subject": b.decode("utf-8", "ignore"), "body": ""}
            open(os.path.join(CAP, "alerts.log"), "a").write(
                (d.get("subject") or "") + "\n" + (d.get("body") or "") + "\n--8<--\n")
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"ok":true}')
srv = HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(CAP, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$TMP/mock.py" "$CAP" & MOCK_PID=$!
for _ in $(seq 1 50); do [ -s "$CAP/port" ] && break; sleep 0.1; done
PORT="$(cat "$CAP/port" 2>/dev/null)"
[ -n "$PORT" ] || { echo "test-heartbeat: mock failed to start" >&2; exit 1; }

# run heartbeat.py against a fixture; echoes "<rc>" and leaves the alert in $CAP/alerts.log
run_hb(){ # $1=fixture json, $2..=extra env assignments
  local fx="$TMP/fx.json"; printf '%s' "$1" > "$fx"; shift
  rm -f "$CAP/alerts.log"
  env PYTHONPATH="$TMP/stub" STUB_DB_FIXTURE="$fx" \
      DATABASE_URL="postgresql://stub/stub" SCOUT_WIRES="crypto ai oss" SCOUT_SILENCE_HOURS=26 \
      RESEND_API_KEY= NOTIFICATION_EMAIL= ALERT_FROM= \
      NOTIFY_WEBHOOK_URL="http://127.0.0.1:$PORT/webhook" \
      "$@" python3 "$ROOT/lib/heartbeat.py" >"$CAP/out.txt" 2>&1
  echo $?
}
alert_body(){ cat "$CAP/alerts.log" 2>/dev/null; }

echo "== A. pure diagnose(): the ledger names the cause =="
python3 - "$ROOT" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import heartbeat as hb
cases = [
    # (label, count, run row or None, expected cause code)
    ("no ledger row at all -> the cron never ran",        0, None,                    "no-run"),
    ("run failed AUTH -> token rejected",                 0, ("auth", 0),             "auth"),
    ("run failed QUOTA -> usage cap",                     0, ("quota", 0),            "quota"),
    ("clean run, 0 opportunities -> thin day",            0, ("ok", 0),               "zero-yield"),
    ("clean run delivered 3 but 0 landed -> lost",        0, ("ok", 3),               "lost-in-delivery"),
]
fails = 0
for label, count, run, want in cases:
    got = hb.diagnose_wire("oss", count, run)
    if got.cause != want:
        print(f"  FAIL: {label}: cause={got.cause!r} want={want!r}", file=sys.stderr); fails += 1
    else:
        print(f"  ok: {label}")
# a wire with rows is never silent, whatever the ledger says
d = hb.diagnose_wire("oss", 4, ("ok", 4))
if d.silent:
    print("  FAIL: wire with 4 rows must not be silent", file=sys.stderr); fails += 1
else:
    print("  ok: wire with rows is not silent")
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "diagnose() cause matrix" || bad "diagnose() cause matrix"

echo "== B. exit contract =="

# B1 all wires delivering -> healthy, rc=0, no alert
rc="$(run_hb '{"counts":[["crypto",3],["ai",4],["oss",2]],"runs":[]}')"
[ "$rc" = "0" ] && ok "all wires healthy -> rc=0" || bad "all wires healthy -> rc=$rc (want 0)"
[ -z "$(alert_body)" ] && ok "healthy run sends no alert" || bad "healthy run sent an alert"

# B2 THE 2026-08-05 CASE: oss silent, ledger shows a clean zero-yield run.
#    Detection succeeded and the alert went out -> rc=0, NOT a crashed deploy.
FX_ZERO='{"counts":[["crypto",3],["ai",4]],"runs":[["oss","ok",0]]}'
rc="$(run_hb "$FX_ZERO")"
[ "$rc" = "0" ] && ok "silent wire + alert delivered -> rc=0 (no false 'Deploy Crashed')" \
                || bad "silent wire + alert delivered -> rc=$rc (want 0)"
body="$(alert_body)"
grep -qi "oss" <<<"$body" && ok "alert names the silent wire" || bad "alert omits the wire"
grep -qi "found nothing\|zero-yield\|no new" <<<"$body" \
  && ok "alert states the TRUE cause (clean run, no finds)" || bad "alert omits the true cause"
grep -qi "setup-token\|token may have expired" <<<"$body" \
  && bad "alert still blames the OAuth token on a clean zero-yield run" \
  || ok "alert does NOT blame the token when the run was clean"

# B3 cron genuinely down (no ledger row) -> the token/cron advice IS correct here
rc="$(run_hb '{"counts":[["crypto",3],["ai",4]],"runs":[]}')"
[ "$rc" = "0" ] && ok "no-run detection -> rc=0" || bad "no-run detection -> rc=$rc (want 0)"
grep -qi "did not run\|no run" <<<"$(alert_body)" \
  && ok "no-run alert says the run never happened" || bad "no-run alert omits 'did not run'"

# B4 expired token -> alert must carry the AUTH remedy
rc="$(run_hb '{"counts":[["crypto",3],["ai",4]],"runs":[["oss","auth",0]]}')"
grep -qi "setup-token" <<<"$(alert_body)" \
  && ok "auth failure alert carries the setup-token remedy" || bad "auth alert lost the remedy"

# B5 delivered-but-missing: the run says 3, the queue has 0 -> a real anomaly, flagged as such
rc="$(run_hb '{"counts":[["crypto",3],["ai",4]],"runs":[["oss","ok",3]]}')"
grep -qi "deliver" <<<"$(alert_body)" \
  && ok "lost-in-delivery alert points between submit and the queue" || bad "lost-in-delivery cause missing"

# B6 alert delivery FAILS -> rc=1 so Railway's crash mail becomes the backstop
touch "$CAP/force_500"
rc="$(run_hb "$FX_ZERO")"
rm -f "$CAP/force_500"
[ "$rc" = "1" ] && ok "undeliverable alert -> rc=1 (crash mail is the backstop)" \
                || bad "undeliverable alert -> rc=$rc (want 1)"

# B7 the heartbeat itself is broken -> rc=2, distinct from a detection
rc="$(env STUB_DB_FAIL=1 bash -c "$(declare -f run_hb); TMP='$TMP'; CAP='$CAP'; ROOT='$ROOT'; PORT='$PORT'; run_hb '{\"counts\":[],\"runs\":[]}' STUB_DB_FAIL=1")"
[ "$rc" = "2" ] && ok "unreachable DB -> rc=2 (heartbeat failure, not a detection)" \
                || bad "unreachable DB -> rc=$rc (want 2)"

rc="$(env PYTHONPATH="$TMP/stub" DATABASE_URL= python3 "$ROOT/lib/heartbeat.py" >/dev/null 2>&1; echo $?)"
[ "$rc" = "2" ] && ok "missing DATABASE_URL -> rc=2" || bad "missing DATABASE_URL -> rc=$rc (want 2)"

echo
echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ] && echo "ALL PASS"
exit $(( FAILN>0 ? 1 : 0 ))
