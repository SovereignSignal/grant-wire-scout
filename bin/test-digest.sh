#!/usr/bin/env bash
# test-digest.sh — hermetic test of the daily scout visibility email (lib/digest.py).
#
# The digest exists because exception-only alerting left operators with no picture
# of a working day. This pins:
#
#   SUBJECT  — how many finds wait for review (or the run's failure class)
#   BODY     — a one-sentence headline; two lines per find (name + meta, then
#              the score reason or, unscored, the description); auto-archived
#              finds with the reason; the Wire Room backlog; a Claude-vs-Grok
#              7-day scorecard (runs, found, verdicts, approve rate, quota);
#              a today line and a quota line. Readable in two minutes.
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
        key = next((k for k in ("funnel", "queue", "runs", "spend", "backlog", "outcomes", "lane_runs")
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
SRC = ["claude-code", "grok-scout"]

# Shaped like the real 2 Sep 2026 tick: Grok landed 5 rows, the Wire Room queued 3,
# auto-archived 1 as off-domain noise, and matched 1 to an existing entry.
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
# 7-day verdicts per lane (real 26 Aug–2 Sep shape): Claude 18 finds, Grok 26.
outcomes = [dg.Outcome("claude-code", "archived", 7), dg.Outcome("claude-code", "declined", 5),
            dg.Outcome("claude-code", "queued", 4), dg.Outcome("claude-code", "duplicate", 1),
            dg.Outcome("claude-code", "approved", 1),
            dg.Outcome("grok-scout", "archived", 8), dg.Outcome("grok-scout", "declined", 7),
            dg.Outcome("grok-scout", "queued", 5), dg.Outcome("grok-scout", "approved", 5),
            dg.Outcome("grok-scout", "duplicate", 1)]
# 7-day runs per lane: Claude 12 runs (4 days × 3 wires) at $2.00, Grok 9 at $1.20.
lane_runs = ([dg.LaneRun(f"claude-code-2026-08-{27+i//3}T04000{i%3}Z", "ok", 2 + (i % 3), None, 2.00)
              for i in range(12)]
             + [dg.LaneRun(f"grok-build-2026-08-{26+i//3}T06000{i%3}Z", "ok", 3, None, 1.20)
                for i in range(9)])

fails = 0
def check(label, cond):
    global fails
    if cond: print(f"  ok: {label}")
    else: print(f"  FAIL: {label}", file=sys.stderr); fails += 1

def build(q=queue, r=runs, sp=spend, bl=backlog, oc=outcomes, lr=lane_runs, src=SRC):
    return dg.build(q, r, sp, bl, oc, lr, 26, src, now=now)

subj, text, html = build()
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

# to-review: two lines per find, nothing more
review = text.split("TO REVIEW")[1].split("AUTO-ARCHIVED")[0]
check("review section header counts 3", "TO REVIEW (3)" in text)
check("scored rows show the score and its reason", "72" in review and "aligns with operator preferences" in review)
check("scored rows drop the description (WireOps already sends it)", "maintainers of widely used" not in review)
check("unscored rows fall back to the description", "six-week global online hackathon" in review)
check("unscored rows say so", "unscored" in review)
check("scored rows sort above unscored", review.index("Gecko") < review.index("CoinMarketCap"))
check("nearer deadline sorts first among unscored", review.index("CoinMarketCap") < review.index("Monad"))
check("deadline is a date with days left", "due 13 Oct (41 days)" in review)
check("deadline inside 14 days is flagged", "due 10 Sep (8 days, soon)" in review)
check("rolling deadline says rolling", "rolling" in review.lower())
check("archived row is not in the review list", "Open Science" not in review)
check("duplicate row is not in the review list", "Optimism" not in review)
check("each find is exactly two lines", len([l for l in review.split("\n", 1)[1].splitlines() if l.strip()]) == 6)

# auto-archived: name + the reason the Wire Room gave, one line, so a bad call is visible
arch = text.split("AUTO-ARCHIVED")[1].split("ALREADY HANDLED")[0]
check("archived section counts 1", "AUTO-ARCHIVED (1)" in text)
check("archived row shows its reason on one line", any("Open Science" in l and "off-scope" in l for l in arch.splitlines()))

handled = text.split("ALREADY HANDLED")[1].split("QUEUE")[0]
check("handled section lists the duplicate with its status", "Optimism" in handled and "duplicate" in handled)

# backlog
check("backlog totals the Wire Room queue", "63 waiting" in text)
check("backlog breaks down by wire", "ai 27" in text and "crypto 24" in text and "oss 12" in text)
check("backlog names the oldest row", "oldest 1 Sep" in text)

# lane scorecard: Claude vs Grok over 7 days, every day, whoever ran today
lanes = text.split("LANES")[1].split("Today")[0]
claude = next(l for l in lanes.splitlines() if l.strip().startswith("Claude"))
grok = next(l for l in lanes.splitlines() if l.strip().startswith("Grok"))
def cols(line): return line.split()
check("scorecard has a Claude row even though Claude did not run today", bool(claude))
check("Claude row: 12 runs, 36 found", cols(claude)[1] == "12" and cols(claude)[2] == "36")
check("Claude row: verdicts approved/declined/archived/waiting", cols(claude)[3:7] == ["1", "5", "7", "4"])
check("Claude row: approve rate = approved / decided (1 of 14)", "7%" in claude)
check("Claude row: 7-day quota", "$24.00" in claude)
check("Grok row: 9 runs, 27 found, 24% approve rate, $10.80", cols(grok)[1] == "9" and cols(grok)[2] == "27" and "24%" in grok and "$10.80" in grok)
check("scorecard explains the columns", "approve" in lanes.lower() and "quota" in lanes.lower())
check("the old 7-day funnel line is gone", "scout finds" not in text)

# footer: today and quota, one line each
today_line = next(l for l in text.splitlines() if l.startswith("Today"))
check("today line names lane and model", "Grok" in today_line and "grok-4.6" in today_line)
check("today line shows the per-wire funnel", "crypto 3 of 4 (1 known)" in today_line)
check("today line notes a clean day and the cost", "all ok" in today_line and "$1.87" in today_line)
check("quota line has today and MTD", "$1.87 today" in text and "$3.10 Sep to date" in text)
check("quota line drops 7d (the scorecard has it) and 30d", "last 7d" not in text and "$28.00" not in text)
check("quota is labelled not-a-bill", "not a bill" in low)
check("one model today means no by-model line", "by model" not in low)

# html twin
check("html has the names and reasons", "Gecko" in html and "aligns with operator preferences" in html)
check("html has backlog", "63 waiting" in html)
hreview = html.split("To review")[1].split("Auto-archived")[0]
check("html review rows are stacked blocks, never columns", "<table" not in hreview and "nowrap" not in hreview)
hlanes = html.split("Lanes")[1].split("Today")[0]
check("html scorecard lists both lanes", "Claude" in hlanes and "Grok" in hlanes and "$24.00" in hlanes and "24%" in hlanes)
check("html scorecard is stacked rows, never a grid (nine columns overflow a phone)", "<table" not in hlanes and "nowrap" not in hlanes)
check("html has no table anywhere", "<table" not in html)
check("html has no wire room link without WIRE_ROOM_UI", "queue?entry=" not in html)
check("every font shorthand names a family", not re.search(r'font:\d+px[;"]', html))
check("html flags the near deadline", "soon" in hreview)

os.environ["WIRE_ROOM_UI"] = "https://wr.example"
_, _, linked = build()
check("html titles link into the Wire Room", 'href="https://wr.example/queue?entry=11"' in linked)
os.environ.pop("WIRE_ROOM_UI")

two = spend + [dg.ModelSpend("claude-sonnet-4-6", 1, 1.20, 4, 4.80, 16, 19.20, 4, 4.80)]
_, two_text, _ = build(sp=two)
check("two models today -> by-model line", "by model" in two_text.lower() and "claude-sonnet-4-6" in two_text)
grokless = [dg.ModelSpend("grok-4.6", 3, None, 12, None, 45, None, 6, None)]
noquota = [dg.LaneRun("grok-build-x", "ok", 3, None, None)]
_, na_text, _ = build(sp=grokless, lr=noquota)
check("no $ reported -> n/a, explained", "n/a" in na_text and "did not report" in na_text)

# a lane that never ran this week still gets a row, and says so
_, dead_text, _ = build(lr=[r for r in lane_runs if r.run_id.startswith("grok")],
                        oc=[o for o in outcomes if o.scan_source == "grok-scout"])
dead = next(l for l in dead_text.split("LANES")[1].splitlines() if l.strip().startswith("Claude"))
check("lane with no runs this week is still listed", cols(dead)[1] == "0")

# empty days
e_subj, e_text, _ = build(q=[])
check("ran but nothing landed -> subject says so", "nothing to review" in e_subj.lower())
check("ran but nothing landed -> body explains", "already in the catalog" in e_text.lower())
q_subj, q_text, _ = build(q=[], r=[], sp=[], bl=[], oc=[], lr=[])
check("no run -> subject says nothing to review", "nothing to review" in q_subj.lower())
check("no run -> body says no tick landed", "no scout run" in q_text.lower())
check("no run -> empty backlog and scorecard do not crash", "QUEUE" in q_text and "LANES" in q_text)

auth_runs = [dg.RunRow("grok-build-x", "oss", "A", "grok-4.6", "auth", 0, 0, 0, None, None, "2026-09-02")]
a_subj, a_text, _ = build(q=[], r=auth_runs, sp=[])
check("auth day puts the failure in the subject", "auth" in a_subj.lower())
check("auth day names the failed wire in the today line", "oss auth" in a_text)

# cap: two minutes means at most 15 finds in the mail
many = [item(100 + i, f"Grant {i}", "crypto", "$1", "rolling", None, "queued", 50 - (i % 5), None,
             "GRANT", None, f"Description {i}") for i in range(20)]
_, many_text, _ = build(q=many, r=[], sp=[], bl=[], oc=[], lr=[])
check("caps the review list at 15", many_text.count("Grant ") == 15)
check("says how many more", "5 more" in many_text)

# long free-text amount cannot break layout (1 Sep 2026 regression): stacked blocks only
long_amt = [item(1, "NIH Common Fund PRIMED-AI", "ai",
                 "not specified (five separate RFAs: RFA-RM-27-011 through RFA-RM-27-015)",
                 None, None, "queued", None, None, "UNCHECKED", None, "NIH RFA set.")]
_, _, long_html = build(q=long_amt, r=[], sp=[], bl=[], oc=[], lr=[])
lsec = long_html.split("To review")[1].split("Queue")[0]
check("long amount stays in a stacked block", "RFA-RM-27-015" in lsec and "nowrap" not in lsec and "<table" not in lsec)

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
  "outcomes": [["claude-code", "approved", 4], ["claude-code", "declined", 3], ["claude-code", "queued", 8]],
  "lane_runs": [["claude-code-2026-08-30T040000Z", "ok", 1, 4, 5.00], ["claude-code-2026-08-30T041000Z", "ok", 1, 2, 2.50]]
}'

rc="$(run_dg "$FX")"
[ "$rc" = "0" ] && ok "sent digest -> rc=0" || bad "sent digest -> rc=$rc (want 0)"
body="$(mail_body)"
grep -qi "to review" <<<"$body" && ok "mail subject/body says what needs review" || bad "mail missing 'to review': $body"
grep -qi "Avalanche" <<<"$body" && ok "mail lists a queued grant" || bad "mail missing grant name"
grep -qi "claude-sonnet-4-6" <<<"$body" && ok "mail names the model" || bad "mail missing model"
grep -qi "7.50\|\$7.50" <<<"$body" && ok "mail has the lane 7-day quota" || bad "mail missing lane quota: $body"
grep -qi "28.00\|\$28.00" <<<"$body" && ok "mail has MTD spend" || bad "mail missing MTD spend"
grep -qi "Credible org" <<<"$body" && ok "mail carries the score reason" || bad "mail missing score reason"
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
  "outcomes": [],
  "lane_runs": []
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
                           ("digest", ("funnel", "queue", "runs", "spend", "backlog", "outcomes", "lane_runs"))):
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
