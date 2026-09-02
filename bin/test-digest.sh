#!/usr/bin/env bash
# test-digest.sh — hermetic test of the daily scout visibility email (lib/digest.py).
#
# The digest exists because exception-only alerting left operators with no picture
# of a working day. This pins:
#
#   SUBJECT  — how many finds wait for review (or the run's failure class)
#   BODY     — a one-sentence headline; each find with its description, score
#              reason and deadline; auto-archived finds with the reason; the
#              Wire Room backlog; the 7-day outcome funnel; a runs line and a
#              quota line (today / 7d / MTD)
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
        key = next((k for k in ("funnel", "queue", "runs", "spend", "backlog", "outcomes")
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
from datetime import datetime, timezone, date
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
os.environ.pop("WIRE_ROOM_UI", None)
import digest as dg

now = datetime(2026, 9, 2, 14, 0, tzinfo=timezone.utc)

# Shaped like the real 2 Sep 2026 tick: Grok landed 5 rows, the Wire Room queued 3,
# auto-archived 1 as off-domain noise, and matched 1 to an existing entry.
#            id  name  wire  amount  deadline  deadline_parsed  status  quality  score_reason
#            classification  classification_reason  description  scan_source  source_url  created_at
def item(id, name, wire, amount, deadline, parsed, status, q, why, cls, cls_why, desc, src="grok-scout"):
    return dg.QueueItem(id, name, wire, amount, deadline, parsed, status, q, why, cls, cls_why,
                        desc, src, f"https://ex.example/{id}", "2026-09-02")

gecko = item(11, "Gecko Fund (EXANTE)", "oss", "€10,000–€150,000", "Rolling", None, "queued", 72,
             "Real, currently-open OSS maintainer grant program with material funding. "
             "'Maintainers' keyword aligns with operator preferences. Missing exact deadline.",
             "GRANT", "Direct application path for a €1M OSS infrastructure fund.",
             "Apply now to EXANTE's €1 million Gecko Fund for maintainers of widely used, "
             "underfunded open-source infrastructure (Erlang/OTP, Scala, JVM, JavaScript).")
monad = item(12, "Monad Metropolis Global Hackathon", "crypto", "$250,000+ USD", "2026-10-13",
             date(2026, 10, 13), "queued", None, None, "UNCHECKED", None,
             "Register for Monad Foundation's six-week global online hackathon across four tracks.")
cmc = item(13, "CoinMarketCap API Hackathon (Build with CMC)", "crypto",
           "$10,000 worth of prizes (1-year CMC Pro API grants for top 3)", "2026-09-10",
           date(2026, 9, 10), "queued", None, None, "UNCHECKED", None,
           "Build a working product on CoinMarketCap market data during the September window.")
osnl = item(14, "Open Science NL — Mobility and Development Programme", "oss", "up to €25,000",
            "2026-12-03", date(2026, 12, 3), "archived", 15,
            "Real government-backed study-visit grant but off-domain.",
            "NOISE", "Study-visit grant for Dutch open science professionals to train abroad; "
            "study-abroad programs are off-scope.",
            "Apply through ISAAC for a study-visit grant of up to €25,000.")
dup = item(15, "Optimism Retro Funding Round 9", "crypto", "$8M", "2026-09-20", date(2026, 9, 20),
           "duplicate", None, None, "UNCHECKED", None, "Retro funding for onchain builders.")
queue = [gecko, monad, cmc, osnl, dup]

runs = [
    dg.RunRow("grok-build-2026-09-02T060122Z", "crypto", "A", "grok-4.6", "ok", 3, 4, 1, 0.91, None, "2026-09-02"),
    dg.RunRow("grok-build-2026-09-02T060755Z", "ai", "A", "grok-4.6", "ok", 0, 1, 1, 0.35, None, "2026-09-02"),
    dg.RunRow("grok-build-2026-09-02T061230Z", "oss", "A", "grok-4.6", "ok", 2, 2, 0, 0.61, None, "2026-09-02"),
]
spend = [dg.ModelSpend("grok-4.6", 3, 1.87, 12, 7.50, 45, 28.00, 6, 3.10)]
backlog = [dg.Backlog("ai", 27, date(2026, 9, 1)), dg.Backlog("crypto", 24, date(2026, 9, 1)),
           dg.Backlog("oss", 12, date(2026, 9, 2))]
outcomes = [dg.Outcome("archived", 15), dg.Outcome("declined", 12), dg.Outcome("queued", 9),
            dg.Outcome("approved", 6), dg.Outcome("duplicate", 2)]

fails = 0
def check(label, cond):
    global fails
    if cond: print(f"  ok: {label}")
    else: print(f"  FAIL: {label}", file=sys.stderr); fails += 1

subj, text, html = dg.build(queue, runs, spend, backlog, outcomes, 26, ["claude-code", "grok-scout"], now=now)
low = text.lower()

# subject: what needs me, not what the CLI spent
check("subject counts only rows waiting for review", "3 to review" in subj)
check("subject does not count archived/duplicate rows", "4 to review" not in subj and "5" not in subj)
check("subject has the short date", "2 Sep" in subj)
check("subject carries no spend", "$" not in subj)

# headline: one sentence that explains the day
check("headline names the lane and wires", "Grok" in text and "crypto, ai, oss" in text)
check("headline gives the funnel in words", "found 7" in text and "3 waiting for your review" in text)
check("headline counts the archived row", "1 auto-archived" in text)
check("headline counts the duplicate row", "1 duplicate" in text)

# to-review cards
review = text.split("TO REVIEW")[1].split("AUTO-ARCHIVED")[0]
check("review section header counts 3", "TO REVIEW (3)" in text)
check("review carries the model-written description", "maintainers of widely used" in review)
check("review shows the score and its reason", "score 72" in review and "aligns with operator preferences" in review)
check("unscored rows say so instead of showing nothing", "not scored yet" in review)
check("scored rows sort above unscored", review.index("Gecko") < review.index("CoinMarketCap"))
check("nearer deadline sorts first among unscored", review.index("CoinMarketCap") < review.index("Monad"))
check("deadline is rendered as a date with days left", "due 13 Oct (41 days)" in review)
check("deadline inside 14 days is flagged", "due 10 Sep (8 days, soon)" in review)
check("rolling deadline says rolling", "rolling" in review.lower())
check("archived row is not in the review list", "Open Science" not in review)
check("duplicate row is not in the review list", "Optimism" not in review)

# auto-archived: name + the reason the Wire Room gave, so a bad call is visible
arch = text.split("AUTO-ARCHIVED")[1].split("ALREADY HANDLED")[0]
check("archived section counts 1", "AUTO-ARCHIVED (1)" in text)
check("archived row shows its reason", "Open Science" in arch and "off-scope" in arch)

# already handled: duplicate/approved/declined rows, one line each
handled = text.split("ALREADY HANDLED")[1].split("QUEUE")[0]
check("handled section lists the duplicate with its status", "Optimism" in handled and "duplicate" in handled)

# backlog and 7-day funnel
check("backlog totals the Wire Room queue", "63 waiting" in text)
check("backlog breaks down by wire", "ai 27" in text and "crypto 24" in text and "oss 12" in text)
check("backlog names the oldest row", "oldest 1 Sep" in text)
check("7-day line totals scout finds", "44 scout finds" in text)
check("7-day line has the verdicts", "6 approved" in text and "12 declined" in text and "15 archived" in text)
check("7-day line calls queued rows waiting", "9 waiting" in text)

# footer: runs and quota, one line each
check("runs line names lane and model", "Grok" in text and "grok-4.6" in text)
check("runs line shows the per-wire funnel", "crypto 3 of 4 (1 known)" in text)
check("runs line notes a clean day", "all ok" in text)
check("runs line carries today's cost", "$1.87" in text)
check("quota line has today / 7d / MTD", "$1.87 today" in text and "$7.50 last 7d" in text and "$3.10 Sep to date" in text)
check("quota line drops the 30-day figure", "$28.00" not in text)
check("quota is labelled not-a-bill", "not a bill" in low)
check("one model today means no by-model table", "by model" not in low)

# html twin
check("html has the names and descriptions", "Gecko" in html and "maintainers of widely used" in html)
check("html has the score reason", "aligns with operator preferences" in html)
check("html has backlog and funnel", "63 waiting" in html and "44 scout finds" in html)
hreview = html.split("To review")[1].split("Auto-archived")[0]
check("html review cards are stacked blocks, never columns", "<table" not in hreview and "nowrap" not in hreview)
check("html has no wire room link without WIRE_ROOM_UI", "queue?entry=" not in html)
check("every font shorthand names a family", not re.search(r'font:\d+px[;"]', html))
check("html flags the near deadline", "soon" in hreview)

# wire room deep link
os.environ["WIRE_ROOM_UI"] = "https://wr.example"
_, _, linked = dg.build(queue, runs, spend, backlog, outcomes, 26, ["grok-scout"], now=now)
check("html titles link into the Wire Room", 'href="https://wr.example/queue?entry=11"' in linked)
os.environ.pop("WIRE_ROOM_UI")

# two models today -> by-model line
two = spend + [dg.ModelSpend("claude-sonnet-4-6", 1, 1.20, 4, 4.80, 16, 19.20, 4, 4.80)]
_, two_text, _ = dg.build(queue, runs, two, backlog, outcomes, 26, ["grok-scout"], now=now)
check("two models today -> by-model line", "by model" in two_text.lower() and "claude-sonnet-4-6" in two_text)
grokless = [dg.ModelSpend("grok-4.6", 3, None, 12, None, 45, None, 6, None)]
_, na_text, _ = dg.build(queue, runs, grokless, backlog, outcomes, 26, ["grok-scout"], now=now)
check("no $ reported -> n/a, explained", "n/a" in na_text and "did not report" in na_text)

# empty days
e_subj, e_text, _ = dg.build([], runs, spend, backlog, outcomes, 26, ["grok-scout"], now=now)
check("ran but nothing landed -> subject says so", "nothing to review" in e_subj.lower())
check("ran but nothing landed -> body explains", "already in the catalog" in e_text.lower() or "nothing new" in e_text.lower())
q_subj, q_text, _ = dg.build([], [], [], [], [], 26, ["grok-scout"], now=now)
check("no run -> subject says nothing to review", "nothing to review" in q_subj.lower())
check("no run -> body says no tick landed", "no scout run" in q_text.lower())
check("no run -> empty backlog does not crash", "QUEUE" in q_text)

# failure day: the failure class goes in the subject
auth_runs = [dg.RunRow("grok-build-x", "oss", "A", "grok-4.6", "auth", 0, 0, 0, None, None, "2026-09-02")]
a_subj, a_text, _ = dg.build([], auth_runs, [], backlog, outcomes, 26, ["grok-scout"], now=now)
check("auth day puts the failure in the subject", "auth" in a_subj.lower())
check("auth day names the failed wire in the runs line", "oss auth" in a_text or "oss: auth" in a_text)

# 40-item cap
many = [item(100 + i, f"Grant {i}", "crypto", "$1", "rolling", None, "queued", 50 - (i % 5), None,
             "GRANT", None, f"Description {i}") for i in range(42)]
_, many_text, _ = dg.build(many, [], [], [], [], 26, ["grok-scout"], now=now)
check("caps the review list at 40", many_text.count("Description ") == 40)
check("says how many more", "2 more" in many_text)

# long free-text amount cannot break layout (1 Sep 2026 regression): stacked blocks only
long_amt = [item(1, "NIH Common Fund PRIMED-AI", "ai",
                 "not specified (five separate RFAs: RFA-RM-27-011 through RFA-RM-27-015)",
                 None, None, "queued", None, None, "UNCHECKED", None, "NIH RFA set.")]
_, _, long_html = dg.build(long_amt, [], [], [], [], 26, ["grok-scout"], now=now)
lsec = long_html.split("To review")[1]
check("long amount stays in a stacked block", "RFA-RM-27-015" in lsec and "nowrap" not in lsec and "<table" not in lsec.split("Queue")[0])

sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "render contract" || bad "render contract"

echo "== B. send path + exit codes =="

# A working day: Claude landed two rows, spent $1.84; the Wire Room holds a small backlog.
FX='{
  "funnel": [[1]],
  "queue": [
    [11, "Avalanche Research Grants", "crypto", "up to $50,000", "rolling", null, "queued", 72, "Credible org, material funding.", "GRANT", "Open grant program.", "Rolling research grants for Avalanche builders.", "claude-code", "https://avax.example/grants", "2026-08-30"],
    [12, "Schmidt Sciences AI Safety RFP", "ai", "$2M pool", "31 Jul", null, "queued", 80, "Major funder, clear scope.", "GRANT", "Open RFP.", "RFP for AI safety research.", "claude-code", "https://schmidt.example/rfp", "2026-08-30"]
  ],
  "runs": [
    ["claude-code-2026-08-30T040000Z", "crypto", "A", "claude-sonnet-4-6", "ok", 1, 4, 3, 1.20, 540000, "2026-08-30"],
    ["claude-code-2026-08-30T041000Z", "ai", "A", "claude-sonnet-4-6", "ok", 1, 2, 1, 0.64, 420000, "2026-08-30"]
  ],
  "spend": [
    ["claude-sonnet-4-6", 2, 1.84, 8, 7.50, 30, 28.00, 30, 28.00]
  ],
  "backlog": [["crypto", 5, "2026-08-29"], ["ai", 3, "2026-08-30"]],
  "outcomes": [["approved", 4], ["declined", 3], ["queued", 8]]
}'

rc="$(run_dg "$FX")"
[ "$rc" = "0" ] && ok "sent digest -> rc=0" || bad "sent digest -> rc=$rc (want 0)"
body="$(mail_body)"
grep -qi "to review" <<<"$body" && ok "mail subject/body says what needs review" || bad "mail missing 'to review': $body"
grep -qi "Avalanche" <<<"$body" && ok "mail lists a queued grant" || bad "mail missing grant name"
grep -qi "claude-sonnet-4-6" <<<"$body" && ok "mail names the model" || bad "mail missing model"
grep -qi "7.50\|\$7.50" <<<"$body" && ok "mail has week spend" || bad "mail missing week spend: $body"
grep -qi "28.00\|\$28.00" <<<"$body" && ok "mail has MTD spend" || bad "mail missing MTD spend"
grep -qi "Rolling research grants" <<<"$body" && ok "mail carries the description" || bad "mail missing description"
grep -qi "8 waiting\|backlog" <<<"$body" && ok "mail has the backlog" || bad "mail missing backlog"

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
rc = notify.send("Scout · 30 Aug · 2 to review", "body", html="<p>x</p>", record=False)
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
  "queue": [[11, "Avalanche Research Grants", "crypto", "$50k", "rolling", null, "queued", 72, null, "GRANT", null, "Rolling grants.", "claude-code", "https://avax.example", "2026-08-30"]],
  "spend": [["claude-sonnet-4-6", 1, 1.20, 4, 4.80, 16, 19.20, 16, 19.20]],
  "backlog": [],
  "outcomes": []
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
                           ("digest", ("funnel", "queue", "runs", "spend", "backlog", "outcomes"))):
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
grep -qi "Avalanche\|to review" <<<"$body" && ok "healthy day still sends the digest" \
                                        || bad "healthy day sent no digest: $body"

echo
echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ] && echo "ALL PASS"
exit $(( FAILN>0 ? 1 : 0 ))
