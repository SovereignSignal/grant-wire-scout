#!/usr/bin/env bash
# test-digest.sh — hermetic test of the daily scout visibility email (lib/digest.py).
#
# The digest exists because exception-only alerting left operators with no picture
# of a working day. This pins:
#
#   SUBJECT  — queued count + today's quota-equiv (or the run's failure class)
#   BODY     — queue items, per-run funnel, models used, week/month/MTD spend
#   SEND     — goes through notify.py with record=False (not an alert)
#   EXIT     — 0 sent / disabled; 1 send failed; 2 cannot read the DB
#   OFF      — SCOUT_DIGEST=0 is a no-op (heartbeat tests rely on this)
#
# Hermetic: psycopg2 stubbed from a JSON fixture; notify webhook pointed at a
# local mock. No network, no prod side effects.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAILN=0
ok(){ echo "  ok: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1" >&2; FAILN=$((FAILN+1)); }

TMP="$(mktemp -d)"; CAP="$TMP/cap"; mkdir -p "$CAP" "$TMP/stub"
MOCK_PID=""
c_end(){ [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$TMP"; }
trap c_end EXIT

cat > "$TMP/stub/psycopg2.py" <<'PY'
import json, os
class _Cur:
    def __init__(self, fx): self.fx = fx; self.rows = []
    def execute(self, sql, params=None):
        key = next((k for k in ("funnel", "queue", "runs", "spend")
                    if f"/* digest:{k} */" in sql), None)
        assert key, f"unrecognized digest query (missing /* digest:* */ marker):\n{sql}"
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
    if os.environ.get("STUB_DB_FAIL") == "1":
        raise RuntimeError("could not connect to server")
    return _Conn(json.load(open(os.environ["STUB_DB_FIXTURE"])))
PY

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
            open(os.path.join(CAP, "mail.log"), "a").write(
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
[ -n "$PORT" ] || { echo "test-digest: mock failed to start" >&2; exit 1; }

run_dg(){
  local fx="$TMP/fx.json"; printf '%s' "$1" > "$fx"; shift
  rm -f "$CAP/mail.log"
  env PYTHONPATH="$TMP/stub:$ROOT/lib" STUB_DB_FIXTURE="$fx" \
      DATABASE_URL="postgresql://stub/stub" \
      SCOUT_WIRES="crypto ai oss" SCOUT_SCAN_SOURCE= SCOUT_SCAN_SOURCES= \
      RESEND_API_KEY= NOTIFICATION_EMAIL= ALERT_FROM= \
      NOTIFY_WEBHOOK_URL="http://127.0.0.1:$PORT/webhook" \
      "$@" python3 "$ROOT/lib/digest.py" >"$CAP/out.txt" 2>&1
  echo $?
}
mail_body(){ cat "$CAP/mail.log" 2>/dev/null; }

echo "== A. render: subject + body contract =="
python3 - "$ROOT" <<'PY'
import sys, os, re
from datetime import datetime, timezone
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import digest as dg

now = datetime(2026, 8, 30, 14, 0, tzinfo=timezone.utc)
queue = [
    dg.QueueItem(11, "Avalanche Research Grants", "crypto", "up to $50,000", "rolling",
                 "queued", 72, "claude-code", "https://avax.example/grants", "2026-08-30"),
    dg.QueueItem(12, "Schmidt Sciences AI Safety RFP", "ai", "$2M pool", "31 Jul",
                 "queued", 80, "claude-code", "https://schmidt.example/rfp", "2026-08-30"),
]
runs = [
    dg.RunRow("claude-code-2026-08-30T040000Z", "crypto", "A", "claude-sonnet-4-6",
              "ok", 1, 4, 3, 1.20, 540000, "2026-08-30"),
    dg.RunRow("claude-code-2026-08-30T041000Z", "ai", "A", "claude-sonnet-4-6",
              "ok", 1, 2, 1, 0.64, 420000, "2026-08-30"),
    dg.RunRow("claude-code-2026-08-30T042000Z", "oss", "A", "claude-sonnet-4-6",
              "ok", 0, 6, 6, 0.40, 360000, "2026-08-30"),
]
spend = [
    dg.ModelSpend("claude-sonnet-4-6", 3, 2.24, 9, 8.20, 36, 31.40, 36, 31.40),
    dg.ModelSpend("grok-4.6", 0, None, 3, None, 12, None, 12, None),
]
fails = 0
def check(label, cond):
    global fails
    if cond: print(f"  ok: {label}")
    else: print(f"  FAIL: {label}", file=sys.stderr); fails += 1

subj, text, html = dg.build(queue, runs, spend, 26, ["claude-code", "grok-scout"], now=now)
check("subject names queued count", "2 queued" in subj)
check("subject carries today's spend", "$2.24 today" in subj)
check("subject has the short date", "30 Aug" in subj)
check("body lists both queue names", "Avalanche" in text and "Schmidt" in text)
check("body shows found → submitted funnel", "found 4 → submitted 1" in text)
check("body names saturation", "already known" in text)
check("body lists the model used today", "claude-sonnet-4-6" in text and "3 runs" in text)
check("body has week spend", "$8.20" in text and "last 7 days" in text)
check("body has month spend", "$31.40" in text and "last 30 days" in text)
check("body has August MTD", "Aug MTD" in text)
check("body notes SuperGrok n/a", "n/a" in text and "grok-4.6" in text)
check("html twin has the same names", "Avalanche" in html and "Schmidt" in html)
check("html has week/month", "$8.20" in html and "$31.40" in html)
check("quota is labelled not-a-bill", "not a bill" in text.lower())

empty_subj, empty_text, _ = dg.build([], runs, spend, 26, ["claude-code"], now=now)
check("empty queue says nothing landed", "nothing queued" in empty_subj.lower() or "Nothing new landed" in empty_text)
check("empty queue still reports spend", "$2.24" in empty_subj or "$2.24" in empty_text)

auth_runs = [dg.RunRow("claude-code-x", "oss", "A", "claude-sonnet-4-6", "auth", 0, 0, 0, None, None, "2026-08-30")]
auth_subj, _, _ = dg.build([], auth_runs, [], 26, ["claude-code"], now=now)
check("auth day puts the failure in the subject", "auth" in auth_subj.lower())

quiet_subj, quiet_text, _ = dg.build([], [], [], 26, ["claude-code"], now=now)
check("no-run day says nothing queued", "nothing queued" in quiet_subj.lower())
check("no-run body says no tick", "no producer tick" in quiet_text.lower() or "No scout rows" in quiet_text)

# 40-item cap
many = [dg.QueueItem(i, f"Grant {i}", "crypto", "$1", "rolling", "queued", 50,
                     "claude-code", "https://ex.example/"+str(i), "2026-08-30")
        for i in range(42)]
_, many_text, _ = dg.build(many, [], [], 26, ["claude-code"], now=now)
check("caps the queue list", "Grant 0" in many_text and "Grant 39" in many_text)
check("says how many more", "2 more" in many_text)
check("does not dump the 41st", "Grant 40" not in many_text)

# Layout regression (1 Sep 2026): `amount` is free text from the model. A two-column
# table with the meta cell set to white-space:nowrap let one long amount push the table
# past the mail viewport and squeeze every title to one word per line. Each queue item
# must be a single stacked cell (title over meta) that can always wrap.
long_amt = [dg.QueueItem(1, "NIH Common Fund PRIMED-AI", "ai",
                         "not specified (five separate RFAs: RFA-RM-27-011 through RFA-RM-27-015)",
                         None, None, None, "claude-code", "https://nih.example/rfa", "2026-08-30")]
_, _, long_html = dg.build(long_amt, [], [], 26, ["claude-code"], now=now)
qsec = long_html.split("Added to the queue")[1].split("<h3")[0]
check("queue rows never forbid wrapping", "nowrap" not in qsec)
check("queue item is one stacked cell, not two columns", qsec.count("<tr") == 1 and qsec.count("<td") == 1)
check("stacked cell still carries the full meta line", "RFA-RM-27-015" in qsec and "Claude" in qsec)

# `font:12px;` is not a valid CSS shorthand (size needs a family); mail clients drop the
# whole declaration and the footer/captions fall back to 16px serif.
_, _, full_html = dg.build(many, runs, spend, 26, ["claude-code"], now=now)
check("every font shorthand names a family", not re.search(r'font:\d+px[;"]', full_html))

sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "render contract" || bad "render contract"

echo "== B. send path + exit codes =="

# A working day: Claude landed two rows, spent $2.24; Grok has month history only.
FX='{
  "funnel": [[1]],
  "queue": [
    [11, "Avalanche Research Grants", "crypto", "up to $50,000", "rolling", "queued", 72, "claude-code", "https://avax.example/grants", "2026-08-30"],
    [12, "Schmidt Sciences AI Safety RFP", "ai", "$2M pool", "31 Jul", "queued", 80, "claude-code", "https://schmidt.example/rfp", "2026-08-30"]
  ],
  "runs": [
    ["claude-code-2026-08-30T040000Z", "crypto", "A", "claude-sonnet-4-6", "ok", 1, 4, 3, 1.20, 540000, "2026-08-30"],
    ["claude-code-2026-08-30T041000Z", "ai", "A", "claude-sonnet-4-6", "ok", 1, 2, 1, 0.64, 420000, "2026-08-30"]
  ],
  "spend": [
    ["claude-sonnet-4-6", 2, 1.84, 8, 7.50, 30, 28.00, 30, 28.00]
  ]
}'

rc="$(run_dg "$FX")"
[ "$rc" = "0" ] && ok "sent digest -> rc=0" || bad "sent digest -> rc=$rc (want 0)"
body="$(mail_body)"
grep -qi "queued" <<<"$body" && ok "mail subject/body mentions queued" || bad "mail missing queued: $body"
grep -qi "Avalanche" <<<"$body" && ok "mail lists a queued grant" || bad "mail missing grant name"
grep -qi "claude-sonnet-4-6" <<<"$body" && ok "mail names the model" || bad "mail missing model"
grep -qi "7.50\|\$7.50" <<<"$body" && ok "mail has week spend" || bad "mail missing week spend: $body"
grep -qi "28.00\|\$28.00" <<<"$body" && ok "mail has month spend" || bad "mail missing month spend"

# disabled
rc="$(run_dg "$FX" SCOUT_DIGEST=0)"
[ "$rc" = "0" ] && ok "SCOUT_DIGEST=0 -> rc=0" || bad "disabled digest rc=$rc"
[ -z "$(mail_body)" ] && ok "SCOUT_DIGEST=0 sends nothing" || bad "disabled digest still sent mail"

# send failed
touch "$CAP/force_500"
rc="$(run_dg "$FX")"
rm -f "$CAP/force_500"
[ "$rc" = "1" ] && ok "undeliverable digest -> rc=1" || bad "undeliverable digest rc=$rc (want 1)"

# DB down
rc="$(run_dg "$FX" STUB_DB_FAIL=1)"
[ "$rc" = "2" ] && ok "unreachable DB -> rc=2" || bad "unreachable DB rc=$rc (want 2)"

rc="$(env PYTHONPATH="$ROOT/lib" DATABASE_URL= python3 "$ROOT/lib/digest.py" >/dev/null 2>&1; echo $?)"
[ "$rc" = "2" ] && ok "missing DATABASE_URL -> rc=2" || bad "missing DATABASE_URL rc=$rc (want 2)"

echo "== C. notify.record=False (digest is not an alert) =="
python3 - "$ROOT" <<'PY'
import sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import notify
recorded = []
def fake_record(subject, text, channels_ok):
    recorded.append(subject)
sent = []
def fake_resend(subject, text, html=None):
    sent.append(subject)
    return True
notify._record_alert = fake_record
notify._send_resend = fake_resend
rc = notify.send("Scout · 30 Aug — 2 queued · $1.84 today", "body", html="<p>x</p>", record=False)
assert rc == 0 and sent and not recorded, (rc, sent, recorded)
rc = notify.send("ALERT", "fail")
assert rc == 0 and recorded == ["ALERT"], recorded
print("  ok: digest does not write scout_alerts; alerts still do")
PY
[ $? -eq 0 ] && ok "record=False keeps scout_alerts clean" || bad "record=False contract"

echo "== D. heartbeat still exception-only when digest is off; on when digest is on =="
# Reuse heartbeat's own fixture shape via a tiny inline: digest-on + healthy wires
# must produce a digest mail, not a SILENT alert.
# heartbeat will call digest.main(), which needs digest:* fixtures. Combined fixture:
FX_BOTH='{
  "counts": [["crypto", 2], ["ai", 1], ["oss", 1]],
  "runs": [],
  "funnel": [[1]],
  "queue": [[11, "Avalanche Research Grants", "crypto", "$50k", "rolling", "queued", 72, "claude-code", "https://avax.example", "2026-08-30"]],
  "spend": [["claude-sonnet-4-6", 1, 1.20, 4, 4.80, 16, 19.20, 16, 19.20]]
}'
# The heartbeat stub only understands hb:* keys. For this combined run we need a
# stub that accepts BOTH marker families.
cat > "$TMP/stub/psycopg2.py" <<'PY'
import json, os
class _Cur:
    def __init__(self, fx): self.fx = fx; self.rows = []
    def execute(self, sql, params=None):
        key = None
        for fam, names in (("hb", ("counts", "runs", "trend", "lanes", "funnel")),
                           ("digest", ("funnel", "queue", "runs", "spend"))):
            key = next((k for k in names if f"/* {fam}:{k} */" in sql), None)
            if key:
                # prefix-collide: hb funnel vs digest funnel share the name; that's fine,
                # same fixture key.
                break
        assert key, f"unrecognized query:\n{sql}"
        if key == "lanes" and "lanes" not in self.fx:
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
    return _Conn(json.load(open(os.environ["STUB_DB_FIXTURE"])))
PY

run_hb(){
  local fx="$TMP/fx.json"; printf '%s' "$1" > "$fx"; shift
  rm -f "$CAP/mail.log"
  env PYTHONPATH="$TMP/stub:$ROOT/lib" STUB_DB_FIXTURE="$fx" \
      DATABASE_URL="postgresql://stub/stub" SCOUT_WIRES="crypto ai oss" \
      SCOUT_SILENCE_HOURS=26 SCOUT_SCAN_SOURCE= SCOUT_SCAN_SOURCES= \
      RESEND_API_KEY= NOTIFICATION_EMAIL= ALERT_FROM= \
      NOTIFY_WEBHOOK_URL="http://127.0.0.1:$PORT/webhook" \
      "$@" python3 "$ROOT/lib/heartbeat.py" >"$CAP/out.txt" 2>&1
  echo $?
}

rc="$(run_hb "$FX_BOTH" SCOUT_DIGEST=1)"
[ "$rc" = "0" ] && ok "heartbeat + digest on a healthy day -> rc=0" \
                || bad "heartbeat + digest rc=$rc out=$(cat "$CAP/out.txt")"
body="$(mail_body)"
grep -qi "Grant Wire Scout SILENT\|Grant Wire Scout LANE\|⚠️" <<<"$body" \
  && bad "healthy day sent an exception alert: $body" \
  || ok "healthy day does not send a SILENT/LANE alert"
grep -qi "Avalanche\|queued" <<<"$body" && ok "healthy day still sends the digest" \
                                        || bad "healthy day sent no digest: $body"

echo
echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ] && echo "ALL PASS"
exit $(( FAILN>0 ? 1 : 0 ))
