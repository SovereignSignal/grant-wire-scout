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
#     zero-yield         status=ok, opportunity_count=0       -> ran clean, nothing new (thin or dedup)
#     lost-in-delivery   status=ok, opps>0, but 0 rows landed -> broke between submit and the queue
#
#   EXIT   — a firing dead-man's-switch is NOT a crashed deploy:
#     0  all wires healthy
#     0  silent wire(s) detected AND the alert was delivered   (detection worked)
#     1  alert delivery failed                                  (Railway's crash mail = backstop)
#     2  the heartbeat could not do its job (no DSN / DB down)
#
# The daily digest (lib/digest.py) is disabled here via SCOUT_DIGEST=0 so these
# cases stay exception-only. Digest coverage lives in bin/test-digest.sh.
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
        # heartbeat.py tags each query with an /* hb:<name> */ marker; two of them read
        # scout_runs, so the table name alone can no longer tell them apart.
        key = next((k for k in ("counts", "runs", "trend", "lanes", "funnel")
                    if f"/* hb:{k} */" in sql), None)
        assert key, f"unrecognized query (missing /* hb:* */ marker):\n{sql}"
        if key == "lanes" and "lanes" not in self.fx:
            # Fixtures that predate lane diagnosis: do not invent a dead lane.
            self.rows = [("__skip_lanes__", None, None)]
        else:
            self.rows = [tuple(r) for r in self.fx.get(key, [])]
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
      SCOUT_SCAN_SOURCE= SCOUT_SCAN_SOURCES= \
      RESEND_API_KEY= NOTIFICATION_EMAIL= ALERT_FROM= \
      SCOUT_DIGEST=0 \
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
    ("run hit wall-clock cap -> timeout",                 0, ("timeout", 0),          "timeout"),
    ("clean run, 0 opportunities -> zero-yield",          0, ("ok", 0),               "zero-yield"),
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

echo "== A2. collapse_runs(): every run in the window counts, not just the last one =="
# The window can hold MORE THAN ONE run per wire (SCOUT_VARIANTS='A B', or Claude + Grok
# both inside 60h). Reading only the newest row judged the wire by whichever variant
# finished last and went blind to the other — re-opening the wrong-cause hole 2026-08-05 closed.
python3 - "$ROOT" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import heartbeat as hb
cases = [
    # (label, rows for ONE wire, expected (status, opps))
    ("variant B's 0 must not erase variant A's 3", [("ok", 0), ("ok", 3)],      ("ok", 3)),
    ("a failed arm outranks a clean one",          [("ok", 3), ("auth", 0)],    ("auth", 3)),
    ("yields from both arms sum",                  [("ok", 2), ("ok", 1)],      ("ok", 3)),
    ("quota outranks a generic failure",           [("quota", 0), ("failed", 0)], ("quota", 0)),
    ("a null opportunity_count counts as 0",       [("ok", None)],              ("ok", 0)),
    ("a single run is unchanged",                  [("ok", 4)],                 ("ok", 4)),
]
fails = 0
for label, rows, want in cases:
    got = hb.collapse_runs(rows)
    if got != want:
        print(f"  FAIL: {label}: got={got!r} want={want!r}", file=sys.stderr); fails += 1
    else:
        print(f"  ok: {label}")
if hb.collapse_runs([]) is not None:
    print("  FAIL: no rows must collapse to None (a no-run, not a clean run)", file=sys.stderr); fails += 1
else:
    print("  ok: no rows -> None (stays a no-run)")
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "collapse_runs() folds every run in the window" || bad "collapse_runs() folds every run in the window"

echo "== A2b. collapse_lane(): one-wire timeout/other does not kill a live lane =="
# 2026-09-05 14:00: Claude crypto+ai ok, oss rc=124 recorded as other. Worst-status
# collapse paged LANE: Claude (lane-other) even though the lane had just delivered.
python3 - "$ROOT" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import heartbeat as hb
cases = [
    ("ok + other -> alive (the 2026-09-05 mail)",
     [("ok", 3), ("ok", 4), ("other", 0)], ("ok", 7)),
    ("ok + timeout -> alive",
     [("ok", 2), ("timeout", 0)], ("ok", 2)),
    ("skipped + empty -> alive",
     [("skipped", 0), ("empty", 0)], ("skipped", 0)),
    ("AUTH still wins over ok",
     [("ok", 3), ("auth", 0)], ("auth", 3)),
    ("QUOTA still wins over ok",
     [("ok", 1), ("quota", 0)], ("quota", 1)),
    ("only other -> other (lane really failed)",
     [("other", 0)], ("other", 0)),
    ("only timeout -> timeout",
     [("timeout", 0)], ("timeout", 0)),
]
fails = 0
for label, rows, want in cases:
    got = hb.collapse_lane(rows)
    if got != want:
        print(f"  FAIL: {label}: got={got!r} want={want!r}", file=sys.stderr); fails += 1
    else:
        print(f"  ok: {label}")
if hb.collapse_lane([]) is not None:
    print("  FAIL: no rows must collapse to None", file=sys.stderr); fails += 1
else:
    print("  ok: no rows -> None")
d = hb.diagnose_lane("claude-code", hb.collapse_lane([("ok", 3), ("other", 0)]))
if d.silent:
    print(f"  FAIL: ok+other must not page the lane: {d}", file=sys.stderr); fails += 1
else:
    print("  ok: diagnose_lane ok+other is alive")
d = hb.diagnose_lane("claude-code", hb.collapse_lane([("other", 0)]))
if not d.silent or d.cause != "lane-other":
    print(f"  FAIL: other-only should page lane-other: {d}", file=sys.stderr); fails += 1
else:
    print("  ok: diagnose_lane other-only still pages")
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "collapse_lane() keeps a live lane alive" || bad "collapse_lane() keeps a live lane alive"

echo "== A3. trend context: is this zero normal for this wire? =="
# Rows are (wire, day, daily_total) — day-ordered history, because "how many zeros" is not
# enough: WHERE they sit matters. 2026-08-11 proved it — ai's second consecutive zero day was
# reported as "empty days are normal for this wire" because the first day of the streak had
# rolled into the baseline as "1 of them zero". Consecutive zeros must escalate, not
# self-normalize.
python3 - "$ROOT" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import heartbeat as hb
fails = 0
def check(label, cond):
    global fails
    if cond: print(f"  ok: {label}")
    else: print(f"  FAIL: {label}", file=sys.stderr); fails += 1

t = hb.summarize_trend([
    ("ai", "2026-08-01", 3), ("ai", "2026-08-02", 4), ("ai", "2026-08-03", 3), ("ai", "2026-08-04", 2),
    # oss zeroes sometimes, but not lately: scattered, no trailing streak
    ("oss", "2026-08-01", 0), ("oss", "2026-08-02", 2), ("oss", "2026-08-03", 0), ("oss", "2026-08-04", 2),
])
check("median over prior run-days", t["ai"].median == 3)
check("counts the days observed", t["ai"].days == 4)
check("counts prior zero days", t["ai"].zeros == 0)
check("no trailing zeros -> streak 0", t["ai"].streak == 0 and t["oss"].streak == 0)
check("a wire with zero days reports them", t["oss"].zeros == 2 and t["oss"].days == 4)
check("a wire with no history is absent", "crypto" not in t)
check("out-of-order rows still find the streak",
      hb.summarize_trend([("x", "2026-08-03", 0), ("x", "2026-08-01", 3), ("x", "2026-08-02", 0)])["x"].streak == 2)

# THE 2026-08-11 CASE: 20 clean days median 3, then yesterday's first-ever zero. Today's zero
# is the SECOND of a streak — the "unless it repeats" repeat — not a normal empty day.
rows = [("ai", f"2026-07-{d:02d}", n) for d, n in enumerate([3,4,3,2,3,3,2,4,3,3,4,3,2,3,3,4,3,2,3,3], start=1)]
streak = hb.summarize_trend(rows + [("ai", "2026-08-10", 0)])["ai"]
check("trailing zero -> streak 1", streak.streak == 1)
check("streak days leave the baseline", streak.days == 20 and streak.zeros == 0)
check("streak does not flatten its own median", streak.median == 3)

second = hb.diagnose_wire("ai", 0, ("ok", 0), streak).text
check("a repeat says 'consecutive', with the count", "2nd consecutive" in second)
check("a repeat is NOT dressed up as normal", "normal" not in second.lower())
check("a repeat still quotes the pre-streak median", "median" in second.lower() and "3" in second)
check("three in a row says 3rd",
      "3rd consecutive" in hb.diagnose_wire("ai", 0, ("ok", 0),
          hb.summarize_trend(rows + [("ai", "2026-08-10", 0), ("ai", "2026-08-11", 0)])["ai"]).text)

# The other two readings survive
first = hb.diagnose_wire("ai", 0, ("ok", 0), t["ai"]).text
usual = hb.diagnose_wire("oss", 0, ("ok", 0), t["oss"]).text
check("unprecedented zero says so", "first" in first.lower())
check("unprecedented zero quotes the median", "3" in first and "median" in first.lower())
check("scattered zeros still read as normal", "normal" in usual.lower())
check("trend does not change the cause code", hb.diagnose_wire("ai", 0, ("ok", 0), streak).cause == "zero-yield")
check("no history -> message unchanged", "median" not in hb.diagnose_wire("ai", 0, ("ok", 0)).text.lower())
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "trend context on zero-yield" || bad "trend context on zero-yield"

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
grep -qi "found nothing\|zero-yield\|no new\|already in the catalog\|dedup" <<<"$body" \
  && ok "alert states the TRUE cause (clean run, no new finds)" || bad "alert omits the true cause"
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

echo "== B8. other lane already fed the wire (2026-08-27 Thursday oss) =="
# Claude oss was a clean post-dedup 0; Grok had delivered 5 oss rows the day before.
# Combined counts are what diagnose() sees. Must NOT page SILENT.
rc="$(run_hb '{"counts":[["crypto",3],["ai",4],["oss",5]],"runs":[["oss","ok",0]]}')"
[ "$rc" = "0" ] && ok "fed-by-other-lane -> rc=0" || bad "fed-by-other-lane -> rc=$rc (want 0)"
[ -z "$(alert_body)" ] && ok "fed-by-other-lane sends no alert" \
                       || bad "fed-by-other-lane sent an alert: $(alert_body)"

echo "== B9. lane-dead / lane-auth even when the other lane fed the wire =="
# Claude AUTH on oss, Grok already landed 5 oss rows. Must NOT SILENT the wire,
# MUST page the Claude lane. This is the hole dual-source wire-feed opened.
rc="$(run_hb '{"counts":[["crypto",3],["ai",4],["oss",5]],"runs":[["oss","auth",0]],"lanes":[["claude-code","auth",0],["grok-scout","ok",5]]}')"
[ "$rc" = "0" ] && ok "lane-auth + other-lane-fed -> rc=0" || bad "lane-auth rc=$rc (want 0)"
body="$(alert_body)"
grep -qi "LANE" <<<"$body" && ok "lane-auth alert names LANE" || bad "lane-auth alert missing LANE: $body"
grep -qi "AUTH\|setup-token" <<<"$body" && ok "lane-auth alert carries AUTH remedy" \
                                        || bad "lane-auth alert lost AUTH: $body"
grep -qi "SILENT" <<<"$body" && bad "lane-auth must not SILENT a fed wire" \
                             || ok "lane-auth does not SILENT a fed wire"

rc="$(run_hb '{"counts":[["crypto",3],["ai",4],["oss",5]],"runs":[["oss","ok",0]],"lanes":[["grok-scout","ok",5]]}')"
body="$(alert_body)"
grep -qi "LANE" <<<"$body" && ok "missing Claude ledger row pages LANE" \
                           || bad "lane-dead (no Claude row) did not page: $body"
grep -qi "did not run\|no scout_runs\|cron" <<<"$body" \
  && ok "lane-dead says that cron did not run" || bad "lane-dead copy wrong: $body"

echo "== B10. saturation vs thin (found_count on the ledger) =="
python3 - "$ROOT" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import heartbeat as hb
fails = 0
d = hb.diagnose_wire("oss", 0, ("ok", 0, 6))
if d.cause != "saturation" or "already in the catalog" not in d.text:
    print(f"  FAIL: found=6/kept=0 -> {d.cause!r} {d.text!r}", file=sys.stderr); fails += 1
else:
    print("  ok: found=6/kept=0 is saturation, not a thin day")
d = hb.diagnose_wire("oss", 0, ("ok", 0))
if d.cause != "zero-yield":
    print(f"  FAIL: no found_count should stay zero-yield, got {d.cause!r}", file=sys.stderr); fails += 1
else:
    print("  ok: missing found_count stays zero-yield (backward compatible)")
d = hb.diagnose_lane("claude-code", None)
if d.cause != "lane-dead" or not d.silent:
    print(f"  FAIL: diagnose_lane None -> {d}", file=sys.stderr); fails += 1
else:
    print("  ok: diagnose_lane None is lane-dead")
d = hb.diagnose_lane("claude-code", ("ok", 0))
if d.silent:
    print(f"  FAIL: ok lane must not be silent: {d}", file=sys.stderr); fails += 1
else:
    print("  ok: diagnose_lane ok is alive")
d = hb.diagnose_lane("claude-code", ("skipped", 0))
if d.silent:
    print(f"  FAIL: skipped lane must be alive: {d}", file=sys.stderr); fails += 1
else:
    print("  ok: diagnose_lane skipped is alive")
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "saturation + diagnose_lane unit matrix" || bad "saturation + diagnose_lane unit matrix"

rc="$(run_hb '{"counts":[["crypto",3],["ai",4]],"runs":[["oss","ok",0,6]],"funnel":[[1]]}')"
grep -qi "saturation\|already in the catalog" <<<"$(alert_body)" \
  && ok "end-to-end saturation copy when found_count=6" \
  || bad "saturation e2e copy: $(alert_body)"

echo "== B11. 2026-09-05 LANE: Claude (lane-other) — one oss timeout, lane still live =="
# crypto=5 ai=8 oss=2. Claude crypto+ai ok, oss other (the rc=124). Grok fed oss.
# Must NOT page LANE. The per-run TIMEOUT mail already fired; the lane is not dead.
rc="$(run_hb '{"counts":[["crypto",5],["ai",8],["oss",2]],"runs":[["crypto","ok",3],["ai","ok",4],["oss","ok",2]],"lanes":[["claude-code-crypto","ok",3],["claude-code-ai","ok",4],["claude-code-oss","other",0],["grok-build-oss","ok",2]]}')"
[ "$rc" = "0" ] && ok "ok+other lane -> rc=0" || bad "ok+other lane -> rc=$rc (want 0)"
[ -z "$(alert_body)" ] && ok "ok+other lane sends no LANE alert" \
                       || bad "ok+other lane still paged: $(alert_body)"

# AUTH on the same Claude tick still pages — token is lane-wide.
rc="$(run_hb '{"counts":[["crypto",5],["ai",8],["oss",2]],"runs":[["oss","auth",0]],"lanes":[["claude-code-crypto","ok",3],["claude-code-oss","auth",0],["grok-build-oss","ok",2]]}')"
body="$(alert_body)"
grep -qi "LANE" <<<"$body" && ok "AUTH + ok still pages LANE" || bad "AUTH + ok lost LANE: $body"
grep -qi "AUTH\|setup-token" <<<"$body" && ok "AUTH + ok still names AUTH" \
                                        || bad "AUTH + ok lost AUTH copy: $body"

echo "== B12. 2026-09-27 Claude QUOTA — pages until a later tick runs clean =="
# Sun 04:00: crypto ok, then ai + oss hit the Max cap (429). Rows are oldest first.
rc="$(run_hb '{"counts":[["crypto",8],["ai",4],["oss",3]],"runs":[["crypto","ok",1]],"lanes":[["claude-code-crypto","ok",1],["claude-code-ai","quota",0],["claude-code-oss","quota",0],["grok-build-oss","ok",1]]}')"
body="$(alert_body)"
grep -qi "lane-quota" <<<"$body" && ok "QUOTA after the last ok run still pages LANE" \
                                 || bad "QUOTA after ok lost the page: $body"
# Tue 04:00: all three wires ok. The Sunday QUOTA is still inside the 60h window.
rc="$(run_hb '{"counts":[["crypto",8],["ai",4],["oss",3]],"runs":[["crypto","ok",1]],"lanes":[["claude-code-crypto","ok",1],["claude-code-ai","quota",0],["claude-code-oss","quota",0],["grok-build-oss","ok",1],["claude-code-crypto","ok",2],["claude-code-ai","ok",1],["claude-code-oss","ok",1]]}')"
[ "$rc" = "0" ] && ok "recovered lane -> rc=0" || bad "recovered lane -> rc=$rc (want 0)"
[ -z "$(alert_body)" ] && ok "a clean tick after QUOTA clears the LANE page" \
                       || bad "recovered lane still paged: $(alert_body)"
# A skip-if-fed tick never called the CLI; it does not prove the cap reset.
rc="$(run_hb '{"counts":[["crypto",8],["ai",4],["oss",3]],"runs":[["crypto","ok",1]],"lanes":[["claude-code-ai","quota",0],["claude-code-crypto","skipped",0]]}')"
grep -qi "lane-quota" <<<"$(alert_body)" && ok "skipped after QUOTA still pages" \
                                         || bad "skipped after QUOTA cleared the page: $(alert_body)"

echo "== C. multi-variant windows (SCOUT_VARIANTS='A B') =="

# C1 THE MASKED CASE: variant A reported 3, variant B (tight-filter) reported 0, nothing landed.
#    Judging by the newest row alone called this "a thin day, no action needed" and swallowed a
#    real lost-in-delivery. Both rows must be read.
rc="$(run_hb '{"counts":[["crypto",3],["ai",4]],"runs":[["oss","ok",3],["oss","ok",0]]}')"
body="$(alert_body)"
grep -qi "deliver" <<<"$body" \
  && ok "A=3 + B=0 with 0 landed -> lost-in-delivery, not a thin day" \
  || bad "A=3 + B=0 with 0 landed -> cause is not lost-in-delivery"
grep -qi "found nothing" <<<"$body" \
  && bad "still reports 'found nothing' while variant A reported 3" \
  || ok "does not claim 'found nothing' when an arm reported finds"
[ "$rc" = "0" ] && ok "multi-variant detection -> rc=0" || bad "multi-variant detection -> rc=$rc (want 0)"

# C2 one arm's AUTH failure must not be hidden by the other arm's clean empty run
rc="$(run_hb '{"counts":[["crypto",3],["ai",4]],"runs":[["oss","auth",0],["oss","ok",0]]}')"
grep -qi "setup-token" <<<"$(alert_body)" \
  && ok "AUTH on one arm survives a clean run on the other" \
  || bad "AUTH on one arm was masked by the other arm"

echo "== D. trend context in the delivered alert =="

# D1 a zero day on a wire that has never had one must say so, with the median
rc="$(run_hb '{"counts":[["crypto",3],["ai",4]],"runs":[["oss","ok",0]],"trend":[["oss","2026-08-01",3],["oss","2026-08-02",4],["oss","2026-08-03",3]]}')"
body="$(alert_body)"
grep -qi "median" <<<"$body" && ok "zero-yield alert carries the wire's median" \
                             || bad "zero-yield alert has no trend context"
grep -qi "first" <<<"$body" && ok "alert flags an unprecedented zero day" \
                            || bad "alert does not flag the zero as unprecedented"

# D2 a wire that zeroes routinely (scattered, not lately) must NOT be dressed up as a first
rc="$(run_hb '{"counts":[["crypto",3],["ai",4]],"runs":[["oss","ok",0]],"trend":[["oss","2026-08-01",0],["oss","2026-08-02",2],["oss","2026-08-03",0],["oss","2026-08-04",2]]}')"
grep -qi "normal" <<<"$(alert_body)" && ok "a routinely-empty wire is called normal" \
                                     || bad "routine zero day not identified as normal"

# D3 no history (a brand-new wire) -> the message degrades cleanly, no trend sentence
rc="$(run_hb '{"counts":[["crypto",3],["ai",4]],"runs":[["oss","ok",0]],"trend":[]}')"
grep -qi "median" <<<"$(alert_body)" && bad "invented a trend for a wire with no history" \
                                    || ok "no history -> no trend sentence"
[ "$rc" = "0" ] && ok "trendless zero-yield -> rc=0" || bad "trendless zero-yield -> rc=$rc (want 0)"

# D4 THE 2026-08-11 EMAIL: yesterday's first-ever zero rolled into the baseline, and the
#    second consecutive zero day went out as "empty days are normal for this wire".
rc="$(run_hb '{"counts":[["crypto",3],["ai",4]],"runs":[["oss","ok",0]],"trend":[["oss","2026-08-01",3],["oss","2026-08-02",4],["oss","2026-08-03",3],["oss","2026-08-04",0]]}')"
body="$(alert_body)"
grep -qi "consecutive" <<<"$body" && ok "a trailing zero escalates to 'consecutive'" \
                                  || bad "trailing zero did not escalate"
grep -qi "normal" <<<"$body" && bad "second consecutive zero day still reads 'normal'" \
                             || ok "a streak is not called normal"

echo
echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ] && echo "ALL PASS"
exit $(( FAILN>0 ? 1 : 0 ))
