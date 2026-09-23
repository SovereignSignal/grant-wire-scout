#!/usr/bin/env bash
# test-grok-engine.sh — hermetic coverage for the parallel Grok Build lane.
#
# The Claude e2e suite (bin/test-e2e.sh) stays the default-engine contract. This file pins
# the Grok additions: extract.py reads Grok's `{text, sessionId}` envelope, submit.py sends
# scan_source=grok-scout, run-all.sh refuses a grok-scout service with no credentials, and
# a stubbed `grok -p` happy path delivers without firing an alert.
#
# No network, no Grok quota, no prod side effects.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
    [ -x "$b" ] && [ "$("$b" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)" -ge 4 ] 2>/dev/null && exec "$b" "$0" "$@"
  done
  echo "test-grok-engine: need bash >= 4" >&2; exit 1
fi
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAILN=0
ok(){ echo "  ok: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1" >&2; FAILN=$((FAILN+1)); }

TMP="$(mktemp -d)"; CAP="$TMP/cap"; mkdir -p "$CAP" "$TMP/bin" "$TMP/grokhome"
MOCK_PID=""; RUN_DIRS=()
c_end(){ [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$TMP"
         for d in "${RUN_DIRS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done; }
trap c_end EXIT

echo "== 1. extract.py: Grok {text, sessionId} envelope =="
python3 - "$ROOT" "$TMP" <<'PY'
import json, os, sys, tempfile
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "lib"))
import extract
payload = {
    "producer": "grok-build", "variant": "A", "wire": "crypto", "run_id": "t",
    "generated_at": "2026-08-22T00:00:00Z", "rejected": [],
    "opportunities": [{
        "name": "Grok Envelope Grant", "source_url": "https://example.com/g",
        "wire": "crypto", "amount": "$10k", "deadline": "2026-12-31",
        "summary": "Test.", "classification": "GRANT", "fit_score": 80,
        "fit_reason": "test", "evidence": ["https://example.com/g"],
        "discovered_via": "x_search",
    }],
}
raw = {
    "text": json.dumps(payload),
    "stopReason": "EndTurn",
    "sessionId": "sess-1",
    "requestId": "req-1",
}
fails = 0
def check(label, cond):
    global fails
    if cond: print(f"  ok: {label}")
    else: print(f"  FAIL: {label}", file=sys.stderr); fails += 1

# Grok envelope → payload
got, text = extract.split_envelope(raw)
check("split_envelope reads .text, not a nested dict", got is None and '"producer"' in text)
# Claude envelope still preferred when both exist
both = dict(raw); both["result"] = json.dumps({**payload, "producer": "claude-code"})
got, text = extract.split_envelope(both)
check("Claude .result wins when both keys present", got is None and "claude-code" in text)
# Nested dict under text
nested = {"text": payload, "sessionId": "s"}
got, text = extract.split_envelope(nested)
check("dict-in-text is accepted as payload", got is not None and got["producer"] == "grok-build")
# Bare payload
got, text = extract.split_envelope(payload)
check("bare payload still works", got is payload)

raw_path = os.path.join(sys.argv[2], "raw-grok.json")
out_path = os.path.join(sys.argv[2], "opps.json")
json.dump(raw, open(raw_path, "w"))
rc = extract.main(raw_path, out_path)
out = json.load(open(out_path))
check("main() grok envelope rc=0", rc == 0)
check("main() extracted grok-build producer", out.get("producer") == "grok-build")
check("main() kept x_search discovered_via", out["opportunities"][0]["discovered_via"] == "x_search")

# Social source_url is a lead — hard-reject even if the model emitted it.
social = dict(payload)
social["opportunities"] = [{
    **payload["opportunities"][0],
    "name": "Base Batches via tweet",
    "source_url": "https://x.com/base/status/2090115624764629058",
}]
social_raw = {"text": json.dumps(social), "sessionId": "s"}
social_in = os.path.join(sys.argv[2], "raw-social.json")
social_out = os.path.join(sys.argv[2], "opps-social.json")
json.dump(social_raw, open(social_in, "w"))
extract.main(social_in, social_out)
sout = json.load(open(social_out))
check("x.com source_url is stripped from opportunities", sout.get("opportunities") == [])
check("x.com source_url landed in rejected",
      any(r.get("source_url", "").startswith("https://x.com/") for r in sout.get("rejected") or []))

# 2026-09-10: Grok Fri 06:00 wrote a complete opportunities array, omitted
# top-level producer, extract aborted (`payload missing required key 'producer'`).
for k in ("SCOUT_PRODUCER", "SCOUT_VARIANT", "SCOUT_WIRE", "SCOUT_RUN_ID"):
    os.environ.pop(k, None)
no_meta = {
    "opportunities": [payload["opportunities"][0]],
    "rejected": [],
}
no_meta_raw = {
    "text": json.dumps(no_meta),
    "stopReason": "error",
    "sessionId": "sess-910",
    "numTurns": 5,
    "modelUsage": {"grok-4.6-build": {"totalTokens": 2262318, "modelCalls": 5}},
}
no_meta_in = os.path.join(sys.argv[2], "raw-no-meta.json")
no_meta_out = os.path.join(sys.argv[2], "opps-no-meta.json")
json.dump(no_meta_raw, open(no_meta_in, "w"))
try:
    rc = extract.main(no_meta_in, no_meta_out)
    nout = json.load(open(no_meta_out))
    check("missing producer does not abort extract", rc == 0)
    check("missing-producer run keeps the opportunity",
          len(nout.get("opportunities") or []) == 1)
    check("missing-producer run does not invent a producer without wrapper env",
          "producer" not in nout)
except SystemExit as e:
    check(f"missing producer must not SystemExit ({e})", False)

os.environ["SCOUT_PRODUCER"] = "grok-build"
os.environ["SCOUT_VARIANT"] = "A"
os.environ["SCOUT_WIRE"] = "crypto"
os.environ["SCOUT_RUN_ID"] = "grok-build-2026-09-11T060000Z"
stamped_out = os.path.join(sys.argv[2], "opps-stamped.json")
rc = extract.main(no_meta_in, stamped_out)
sout = json.load(open(stamped_out))
check("wrapper stamps producer=grok-build", sout.get("producer") == "grok-build")
check("wrapper stamps variant/wire/run_id",
      sout.get("variant") == "A" and sout.get("wire") == "crypto"
      and sout.get("run_id") == "grok-build-2026-09-11T060000Z")
check("stamped payload still has the opportunity",
      len(sout.get("opportunities") or []) == 1)
check("stamped payload has generated_at", bool(sout.get("generated_at")))

# Bare payload without producer used to be skipped by split_envelope
# (required `producer` on the top-level object) and then fail coerce of "".
got, text = extract.split_envelope(no_meta)
check("bare payload without producer is still a payload",
      got is no_meta and text == "")

# Root array of opportunities (model skipped the wrapper object entirely).
root_arr_in = os.path.join(sys.argv[2], "raw-root-array.json")
root_arr_out = os.path.join(sys.argv[2], "opps-root-array.json")
json.dump({"text": json.dumps([payload["opportunities"][0]])}, open(root_arr_in, "w"))
rc = extract.main(root_arr_in, root_arr_out)
rout = json.load(open(root_arr_out))
check("root array is wrapped into opportunities",
      rc == 0 and len(rout.get("opportunities") or []) == 1
      and rout.get("producer") == "grok-build")
for k in ("SCOUT_PRODUCER", "SCOUT_VARIANT", "SCOUT_WIRE", "SCOUT_RUN_ID"):
    os.environ.pop(k, None)
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "extract.py grok envelope matrix" || bad "extract.py grok envelope matrix"

echo "== 2. classify_failure.py: Grok AUTH / EMPTY =="
python3 - "$ROOT" "$TMP" <<'PY'
import json, os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "lib"))
import classify_failure as cf
tmp = sys.argv[2]
fails = 0
def write(name, obj):
    p = os.path.join(tmp, name)
    json.dump(obj, open(p, "w")); return p
def check(label, path, want):
    global fails
    got = cf.classify(path)
    if got == want: print(f"  ok: {label}")
    else: print(f"  FAIL: {label}: got={got!r} want={want!r}", file=sys.stderr); fails += 1
check("grok not-authenticated -> AUTH",
      write("a.json", {"text": "Error: not authenticated. Run grok login.", "stopReason": "Error", "is_error": True}),
      "AUTH")
check("empty grok envelope -> EMPTY",
      write("e.json", {"text": "", "stopReason": "EndTurn", "sessionId": "x"}),
      "EMPTY")
check("grok 429 in text -> QUOTA",
      write("q.json", {"text": "HTTP 429 rate limit", "is_error": True}),
      "QUOTA")
check("max_tokens_truncation inside .text -> EMPTY",
      write("mt.json", {"text": 'Error: Internal error: {"error_kind": "max_tokens_truncation"}',
                        "stopReason": "error"}),
      "EMPTY")
bare = os.path.join(tmp, "bare.txt")
open(bare, "w").write('Error: Internal error: {\n "message": "response truncated by max_tokens"\n}')
check("bare (non-JSON) truncation blob -> EMPTY", bare, "EMPTY")
check("cli timed-out envelope -> TIMEOUT",
      write("t.json", {"text": "", "stopReason": "Error", "is_error": True,
                       "error": "command timed out"}),
      "TIMEOUT")
sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "classify_failure grok signals" || bad "classify_failure grok signals"

echo "== 3. run-all.sh auth guards =="
out="$(env -u CLAUDE_CODE_OAUTH_TOKEN -u GROK_AUTH_JSON -u XAI_API_KEY \
       SERVICE_ROLE=grok-scout SCOUT_ENGINE=grok GROK_HOME="$TMP/empty-grok" \
       "$ROOT/bin/run-all.sh" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "grok-scout with no credentials -> rc=1" || bad "grok-scout no-auth rc=$rc (want 1)"
printf '%s\n' "$out" | grep -qi "GROK_AUTH_JSON" \
  && ok "grok-scout refusal names GROK_AUTH_JSON" || bad "grok-scout refusal lost the remedy"

out="$(env -u CLAUDE_CODE_OAUTH_TOKEN -u GROK_AUTH_JSON -u XAI_API_KEY \
       SERVICE_ROLE=scout "$ROOT/bin/run-all.sh" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "claude scout with no token still -> rc=1" || bad "claude no-token rc=$rc (want 1)"

out="$(env -u CLAUDE_CODE_OAUTH_TOKEN -u GROK_AUTH_JSON -u XAI_API_KEY \
       SERVICE_ROLE=heartbeat "$ROOT/bin/run-all.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "heartbeat role with no tokens -> clean no-op rc=0" \
                || bad "heartbeat no-op rc=$rc (want 0)"

echo "== 4. hydrate_grok_auth.py =="
out="$(env -u GROK_AUTH_JSON -u XAI_API_KEY GROK_HOME="$TMP/empty-grok" \
       python3 "$ROOT/lib/hydrate_grok_auth.py" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ok "hydrate with no credentials -> rc=2" || bad "hydrate empty rc=$rc (want 2)"
export GROK_HOME="$TMP/grokhome"
export GROK_AUTH_JSON='{"access_token":"test-token"}'
hout="$(python3 "$ROOT/lib/hydrate_grok_auth.py" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ -s "$TMP/grokhome/auth.json" ] \
  && ok "hydrate writes auth.json mode 600-able" || bad "hydrate did not write auth.json"
printf '%s\n' "$hout" | grep -q "wrote GROK_AUTH_JSON" \
  && ok "hydrate logs a write on seed" || bad "hydrate write log missing"

# On-disk refresh newer than env seed must survive (Railway volume case).
python3 - "$TMP/volhome" "$ROOT" <<'PY'
import json, os, sys, subprocess
vol, root = sys.argv[1], sys.argv[2]
os.makedirs(vol, exist_ok=True)
disk = {
    "https://auth.x.ai::test": {
        "create_time": "2026-08-24T13:00:00Z",
        "expires_at": "2026-08-24T19:00:00Z",
        "refresh_token": "disk-refresh",
        "email": "disk@example.com",
    }
}
env = {
    "https://auth.x.ai::test": {
        "create_time": "2026-08-22T13:00:00Z",
        "expires_at": "2026-08-22T19:00:00Z",
        "refresh_token": "env-refresh",
        "email": "env@example.com",
    }
}
open(os.path.join(vol, "auth.json"), "w").write(json.dumps(disk))
envp = os.environ.copy()
envp["GROK_HOME"] = vol
envp["GROK_AUTH_JSON"] = json.dumps(env)
envp.pop("XAI_API_KEY", None)
r = subprocess.run(["python3", os.path.join(root, "lib/hydrate_grok_auth.py")],
                   env=envp, capture_output=True, text=True)
got = json.load(open(os.path.join(vol, "auth.json")))
inner = next(iter(got.values()))
ok = r.returncode == 0 and inner.get("refresh_token") == "disk-refresh" and "keeping on-disk" in r.stdout
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && ok "hydrate keeps newer on-disk session" || bad "hydrate clobbered newer on-disk session"

# Re-login: newer env seed must replace a stale volume file.
python3 - "$TMP/volhome2" "$ROOT" <<'PY'
import json, os, sys, subprocess
vol, root = sys.argv[1], sys.argv[2]
os.makedirs(vol, exist_ok=True)
disk = {
    "https://auth.x.ai::test": {
        "create_time": "2026-08-22T13:00:00Z",
        "refresh_token": "disk-refresh",
    }
}
env = {
    "https://auth.x.ai::test": {
        "create_time": "2026-08-24T13:51:00Z",
        "refresh_token": "env-refresh",
    }
}
open(os.path.join(vol, "auth.json"), "w").write(json.dumps(disk))
envp = os.environ.copy()
envp["GROK_HOME"] = vol
envp["GROK_AUTH_JSON"] = json.dumps(env)
envp.pop("XAI_API_KEY", None)
r = subprocess.run(["python3", os.path.join(root, "lib/hydrate_grok_auth.py")],
                   env=envp, capture_output=True, text=True)
got = json.load(open(os.path.join(vol, "auth.json")))
inner = next(iter(got.values()))
ok = r.returncode == 0 and inner.get("refresh_token") == "env-refresh" and "wrote GROK_AUTH_JSON" in r.stdout
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && ok "hydrate writes newer env seed over stale disk" || bad "hydrate did not replace stale disk"
unset GROK_AUTH_JSON

echo "== 5. happy path: stub grok -> submit source=grok-scout, no alert =="
ln -sf "$BASH" "$TMP/bin/bash"
# `timeout` shim: no real clock. GROK_STUB_FORCE_TIMEOUT=1 plays the wall-clock kill for
# the MAIN call only (exit 124, nothing on stdout — json output is one object at exit); the
# producer's `--resume` flush still runs, so the salvage path can be exercised.
cat > "$TMP/bin/timeout" <<'SH'
#!/usr/bin/env bash
[ "$1" = "-k" ] && shift 2
dur="$1"; shift
if [ "${GROK_STUB_FORCE_TIMEOUT:-0}" = "1" ]; then
  is_resume=0; for a in "$@"; do [ "$a" = "--resume" ] && is_resume=1; done
  [ "$is_resume" = "0" ] && exit 124
fi
exec "$@"
SH
cat > "$TMP/bin/grok" <<'PY'
#!/usr/bin/env python3
import os, sys, json
mode = os.environ.get("GROK_STUB_MODE", "ok")
base = os.environ.get("MOCK_BASE", "http://127.0.0.1")
def out(text, **x):
    d = {"text": text, "stopReason": "EndTurn", "sessionId": "e2e", "requestId": "r"}
    d.update(x); sys.stdout.write(json.dumps(d))
if "--resume" in sys.argv:
    # Resume-flush after a wall-clock kill. Record the argv so the test can pin the flags.
    argv_f = os.environ.get("GROK_STUB_RESUME_ARGV")
    if argv_f: open(argv_f, "w").write("\n".join(sys.argv[1:]))
    if os.environ.get("GROK_STUB_RESUME") == "payload":
        p = {"producer": "grok-build", "variant": "A", "wire": "crypto", "run_id": "e2e-g",
             "generated_at": "2026-09-23T00:00:00Z", "rejected": [],
             "opportunities": [{"name": "Grok Resume Flush Grant", "source_url": base + "/g1",
                 "wire": "crypto", "amount": "$10k", "deadline": "2026-12-31", "summary": "Test grant.",
                 "classification": "GRANT", "fit_score": 80, "fit_reason": "verified before the kill",
                 "evidence": [base + "/g1"], "discovered_via": "x_search"}]}
        out(json.dumps(p)); sys.exit(0)
    out(json.dumps({"producer": "grok-build", "variant": "A", "wire": "crypto", "opportunities": [],
                    "rejected": []})); sys.exit(0)
if mode == "ok":
    p = {"producer": "grok-build", "variant": "A", "wire": "crypto", "run_id": "e2e-g",
         "generated_at": "2026-08-22T00:00:00Z", "rejected": [],
         "opportunities": [{"name": "Grok E2E Grant", "source_url": base + "/g1", "wire": "crypto",
             "amount": "$10k", "deadline": "2026-12-31", "summary": "Test grant.", "classification": "GRANT",
             "fit_score": 80, "fit_reason": "fresh x lead", "evidence": [base + "/g1"],
             "discovered_via": "x_search"}]}
    out(json.dumps(p)); sys.exit(0)
if mode == "auth":
    out("not authenticated: run grok login", stopReason="Error"); sys.exit(1)
# 2026-09-16 production shape: Grok CLI 1.0.5 hit its per-response output cap on the
# final turn (reasoning ate the budget), printed an internal-error blob instead of a
# payload, rc=1. Nothing for extract to salvage.
TRUNC = ('Error: Internal error: {\n  "message": "response truncated by max_tokens",\n'
         '  "error_kind": "max_tokens_truncation",\n  "promptUsage": {"inputTokens": 304640,'
         ' "outputTokens": 5070, "reasoningTokens": 3740, "modelCalls": 4}\n}\n')
calls_f = os.environ.get("GROK_STUB_CALLS")
n = 0
if calls_f:
    try: n = int(open(calls_f).read() or 0)
    except Exception: n = 0
    n += 1
    open(calls_f, "w").write(str(n))
    open(calls_f + ".argv." + str(n), "w").write("\n".join(sys.argv[1:]))
prompt = " ".join(sys.argv[1:])
is_oss = "\noss \u2014 " in prompt
def ok_payload(name):
    return {"producer": "grok-build", "variant": "A", "wire": "crypto", "run_id": "e2e-g",
         "generated_at": "2026-08-22T00:00:00Z", "rejected": [],
         "opportunities": [{"name": name, "source_url": base + "/g1", "wire": "crypto",
             "amount": "$10k", "deadline": "2026-12-31", "summary": "Test grant.", "classification": "GRANT",
             "fit_score": 80, "fit_reason": "fresh x lead", "evidence": [base + "/g1"],
             "discovered_via": "x_search"}]}
def truncated():
    out(TRUNC, stopReason="error", numTurns=4); sys.exit(1)
if mode == "truncated-then-ok":
    if n <= 1: truncated()
    out(json.dumps(ok_payload("Grok Retry Grant"))); sys.exit(0)
if mode == "truncated-always":
    truncated()
if mode == "oss-truncated":
    if is_oss: truncated()
    out(json.dumps(ok_payload("Grok Crypto Grant"))); sys.exit(0)
# 2026-09-10 production shape: complete finds, no top-level producer, CLI rc=1.
if mode == "no-meta":
    p = {"opportunities": [{"name": "Grok No-Meta Grant", "source_url": base + "/g1",
             "wire": "crypto", "amount": "$10k", "deadline": "2026-12-31",
             "summary": "Test grant.", "classification": "GRANT", "fit_score": 80,
             "fit_reason": "fresh x lead", "evidence": [base + "/g1"],
             "discovered_via": "x_search"}], "rejected": []}
    out(json.dumps(p), stopReason="error", numTurns=5); sys.exit(1)
out(""); sys.exit(0)
PY
chmod +x "$TMP/bin/timeout" "$TMP/bin/grok"

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
            self.s(200, {"ok": True, "totalIngested": 1, "newUnique": 1})
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

CASE_OUT="$(env PATH="$TMP/bin:$PATH" GROK="$TMP/bin/grok" GROK_STUB_MODE=ok \
   MOCK_BASE="$BASEURL" WIRE_ROOM_API="$BASEURL" INTERNAL_API_KEY=test \
   NOTIFY_WEBHOOK_URL="$BASEURL/webhook" SCOUT_PRIME_KNOWN=0 \
   SCOUT_ENGINE=grok GROK_MODEL=stub GROK_HOME="$TMP/grokhome" \
   GROK_AUTH_JSON='{"access_token":"test"}' \
   "$TMP/bin/bash" "$ROOT/bin/run-scout.sh" crypto A 2>&1)"; CASE_RC=$?
d="$(printf '%s\n' "$CASE_OUT" | sed -n 's/^RUN_DIR=//p' | tail -1)"
[ -n "$d" ] && RUN_DIRS+=("$d")

[ "$CASE_RC" -eq 0 ] && ok "grok run-scout rc=0" || { printf '%s\n' "$CASE_OUT" | tail -20; bad "grok happy rc=$CASE_RC"; }
[ -s "$CAP/submit.json" ] && ok "grok lane delivered to Wire Room" || bad "no grok submit captured"
python3 - "$CAP/submit.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
src = d.get("source")
ok = src == "grok-scout"
raw = json.loads(d.get("rawText") or "{}")
opps = raw.get("opportunities") or []
prod = (opps[0].get("discovered_via") if opps else None)
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && ok "submit source=grok-scout" || bad "submit source was not grok-scout: $(cat "$CAP/submit.json" 2>/dev/null | head -c 200)"
[ -z "$(cat "$CAP/alerts.log" 2>/dev/null || true)" ] && ok "grok happy path fired no alert" \
  || bad "unexpected grok alert: $(cat "$CAP/alerts.log" 2>/dev/null)"
if [ -n "${d:-}" ] && [ -f "$d/meta.json" ]; then
  python3 - "$d/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
sys.exit(0 if m.get("engine") == "grok" and m.get("producer") == "grok-build" else 1)
PY
  [ $? -eq 0 ] && ok "meta.json engine=grok producer=grok-build" || bad "meta.json attribution wrong"
  grep -q "Grok Build Producer" "$d/report.md" 2>/dev/null \
    && ok "report.md titled Grok Build Producer" || bad "report.md missing Grok Build title"
else
  bad "missing grok run meta.json"
fi

echo "== 6. grok AUTH alert names grok login, not claude setup-token =="
rm -f "$CAP/submit.json" "$CAP/alerts.log"
CASE_OUT="$(env PATH="$TMP/bin:$PATH" GROK="$TMP/bin/grok" GROK_STUB_MODE=auth \
   MOCK_BASE="$BASEURL" WIRE_ROOM_API="$BASEURL" INTERNAL_API_KEY=test \
   NOTIFY_WEBHOOK_URL="$BASEURL/webhook" SCOUT_PRIME_KNOWN=0 \
   SCOUT_ENGINE=grok GROK_MODEL=stub GROK_HOME="$TMP/grokhome" \
   GROK_AUTH_JSON='{"access_token":"test"}' \
   "$TMP/bin/bash" "$ROOT/bin/run-scout.sh" crypto A 2>&1)"; CASE_RC=$?
d="$(printf '%s\n' "$CASE_OUT" | sed -n 's/^RUN_DIR=//p' | tail -1)"
[ -n "$d" ] && RUN_DIRS+=("$d")
alerts="$(cat "$CAP/alerts.log" 2>/dev/null || true)"
echo "$alerts" | grep -q "AUTH" && ok "grok auth fires AUTH alert" || bad "grok auth alert: $alerts"
echo "$alerts" | grep -qi "GROK_AUTH_JSON\|grok login" \
  && ok "grok AUTH remedy names grok credentials" || bad "grok AUTH remedy wrong: $alerts"
echo "$alerts" | grep -q "setup-token" \
  && bad "grok AUTH alert still says claude setup-token" || ok "grok AUTH alert does not mention setup-token"

echo "== 7. heartbeat AUTH remedy switches with SCOUT_SCAN_SOURCE =="
python3 - "$ROOT" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
# import after setting env so SOURCE is grok-scout
os.environ["SCOUT_SCAN_SOURCE"] = "grok-scout"
import importlib
import heartbeat
importlib.reload(heartbeat)
d = heartbeat.diagnose_wire("oss", 0, ("auth", 0))
ok = d.cause == "auth" and "GROK_AUTH_JSON" in d.text and "setup-token" not in d.text
print("  ok: grok-scout AUTH remedy" if ok else f"  FAIL: {d.text!r}")
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && ok "heartbeat grok-scout AUTH text" || bad "heartbeat grok-scout AUTH text"

echo "== 8. grok omits producer + exits 1 -> stamp, deliver, no alert =="
rm -f "$CAP/submit.json" "$CAP/alerts.log"
CASE_OUT="$(env PATH="$TMP/bin:$PATH" GROK="$TMP/bin/grok" GROK_STUB_MODE=no-meta \
   MOCK_BASE="$BASEURL" WIRE_ROOM_API="$BASEURL" INTERNAL_API_KEY=test \
   NOTIFY_WEBHOOK_URL="$BASEURL/webhook" SCOUT_PRIME_KNOWN=0 \
   SCOUT_ENGINE=grok GROK_MODEL=stub GROK_HOME="$TMP/grokhome" \
   GROK_AUTH_JSON='{"access_token":"test"}' \
   "$TMP/bin/bash" "$ROOT/bin/run-scout.sh" crypto A 2>&1)"; CASE_RC=$?
d="$(printf '%s\n' "$CASE_OUT" | sed -n 's/^RUN_DIR=//p' | tail -1)"
[ -n "$d" ] && RUN_DIRS+=("$d")
[ "$CASE_RC" -eq 0 ] && ok "no-meta grok run-scout rc=0" \
  || { printf '%s\n' "$CASE_OUT" | tail -25; bad "no-meta grok rc=$CASE_RC"; }
printf '%s\n' "$CASE_OUT" | grep -q "payload missing required key" \
  && bad "no-meta path still aborted on missing producer" \
  || ok "no-meta path no longer says missing producer"
[ -s "$CAP/submit.json" ] && ok "no-meta grok lane still delivered" \
  || bad "no-meta grok did not submit"
[ -z "$(cat "$CAP/alerts.log" 2>/dev/null || true)" ] && ok "no-meta grok fired no alert" \
  || bad "no-meta grok alerted: $(cat "$CAP/alerts.log" 2>/dev/null)"
if [ -n "${d:-}" ] && [ -f "$d/opportunities.json" ] && [ -f "$d/meta.json" ]; then
  python3 - "$d/opportunities.json" "$d/meta.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
m = json.load(open(sys.argv[2]))
ok = (p.get("producer") == "grok-build" and p.get("variant") == "A"
      and p.get("wire") == "crypto" and len(p.get("opportunities") or []) == 1
      and m.get("producer") == "grok-build" and m.get("opportunity_count") == 1)
sys.exit(0 if ok else 1)
PY
  [ $? -eq 0 ] && ok "no-meta payload+meta stamped grok-build" \
    || bad "no-meta stamp/count wrong: $(cat "$d/opportunities.json" | head -c 400)"
  printf '%s\n' "$CASE_OUT" | grep -q "stamped wrapper metadata" \
    && ok "extract logged the wrapper stamp" || bad "extract did not log stamp"
else
  bad "missing no-meta run artifacts"
fi

grok_env(){ # $1=stub mode, rest = extra env
  local mode="$1"; shift
  env PATH="$TMP/bin:$PATH" GROK="$TMP/bin/grok" GROK_STUB_MODE="$mode" GROK_STUB_CALLS="$CAP/calls" \
     MOCK_BASE="$BASEURL" WIRE_ROOM_API="$BASEURL" INTERNAL_API_KEY=test \
     NOTIFY_WEBHOOK_URL="$BASEURL/webhook" SCOUT_PRIME_KNOWN=0 \
     SCOUT_ENGINE=grok GROK_MODEL=stub GROK_HOME="$TMP/grokhome" \
     GROK_AUTH_JSON='{"access_token":"test"}' "$@"
}
reset_cap(){ rm -f "$CAP/submit.json" "$CAP/alerts.log" "$CAP/calls" "$CAP"/calls.argv.*; }

echo "== 9. max_tokens_truncation -> retry once at low reasoning effort, deliver, no alert =="
reset_cap
CASE_OUT="$(grok_env truncated-then-ok "$TMP/bin/bash" "$ROOT/bin/run-scout.sh" crypto A 2>&1)"; CASE_RC=$?
d="$(printf '%s\n' "$CASE_OUT" | sed -n 's/^RUN_DIR=//p' | tail -1)"
[ -n "$d" ] && RUN_DIRS+=("$d")
[ "$CASE_RC" -eq 0 ] && ok "truncated-then-ok rc=0" \
  || { printf '%s\n' "$CASE_OUT" | tail -25; bad "truncated-then-ok rc=$CASE_RC"; }
[ "$(cat "$CAP/calls" 2>/dev/null)" = "2" ] && ok "grok invoked exactly twice" \
  || bad "grok call count: $(cat "$CAP/calls" 2>/dev/null)"
grep -q -- "--reasoning-effort" "$CAP/calls.argv.2" 2>/dev/null \
  && grep -A1 -- "--reasoning-effort" "$CAP/calls.argv.2" | grep -qx "low" \
  && ok "retry passes --reasoning-effort low" || bad "retry did not lower reasoning effort"
grep -q -- "--reasoning-effort" "$CAP/calls.argv.1" 2>/dev/null \
  && bad "first attempt already lowered reasoning effort" || ok "first attempt runs at default effort"
printf '%s\n' "$CASE_OUT" | grep -qi "truncat.*retry" && ok "producer logged the retry" \
  || bad "producer did not log a truncation retry"
[ -s "$CAP/submit.json" ] && ok "retry delivered to Wire Room" || bad "retry did not submit"
[ -z "$(cat "$CAP/alerts.log" 2>/dev/null || true)" ] && ok "successful retry fired no alert" \
  || bad "successful retry alerted: $(cat "$CAP/alerts.log")"
[ -n "${d:-}" ] && [ -s "$d/raw.attempt1.json" ] && grep -q max_tokens_truncation "$d/raw.attempt1.json" \
  && ok "first attempt's raw output kept as raw.attempt1.json" || bad "first attempt raw output not preserved"

echo "== 10. truncation on both attempts -> EMPTY alert, exactly two calls =="
reset_cap
CASE_OUT="$(grok_env truncated-always "$TMP/bin/bash" "$ROOT/bin/run-scout.sh" crypto A 2>&1)"; CASE_RC=$?
d="$(printf '%s\n' "$CASE_OUT" | sed -n 's/^RUN_DIR=//p' | tail -1)"
[ -n "$d" ] && RUN_DIRS+=("$d")
[ "$CASE_RC" -ne 0 ] && ok "truncated-always rc!=0" || bad "truncated-always returned rc=0"
[ "$(cat "$CAP/calls" 2>/dev/null)" = "2" ] && ok "retry is bounded to one extra call" \
  || bad "grok call count: $(cat "$CAP/calls" 2>/dev/null) (want 2)"
grep -q "EMPTY" "$CAP/alerts.log" 2>/dev/null && ok "double truncation alerts EMPTY" \
  || bad "double truncation alert: $(cat "$CAP/alerts.log" 2>/dev/null)"
[ ! -s "$CAP/submit.json" ] && ok "double truncation delivered nothing" || bad "double truncation submitted"

echo "== 11. run-all: one wire delivered, one wire dead -> rc=0 (alert still fires) =="
reset_cap
CASE_OUT="$(grok_env oss-truncated SERVICE_ROLE=grok-scout SCOUT_WIRES="crypto oss" \
   "$TMP/bin/bash" "$ROOT/bin/run-all.sh" 2>&1)"; CASE_RC=$?
for d in $(printf '%s\n' "$CASE_OUT" | sed -n 's/^RUN_DIR=//p'); do RUN_DIRS+=("$d"); done
[ "$CASE_RC" -eq 0 ] && ok "run-all rc=0 when at least one wire delivered" \
  || { printf '%s\n' "$CASE_OUT" | tail -20; bad "run-all rc=$CASE_RC with a delivered wire (want 0)"; }
[ -s "$CAP/submit.json" ] && ok "crypto still delivered" || bad "crypto did not submit"
grep -q "EMPTY.*oss" "$CAP/alerts.log" 2>/dev/null && ok "oss EMPTY alert still fired" \
  || bad "oss alert missing: $(cat "$CAP/alerts.log" 2>/dev/null)"
printf '%s\n' "$CASE_OUT" | grep -q "run-all\].*1 of 2" && ok "run-all summarizes wires delivered" \
  || bad "run-all summary line missing"

echo "== 12. run-all: every wire dead -> rc=1 =="
reset_cap
CASE_OUT="$(grok_env oss-truncated SERVICE_ROLE=grok-scout SCOUT_WIRES="oss" \
   "$TMP/bin/bash" "$ROOT/bin/run-all.sh" 2>&1)"; CASE_RC=$?
for d in $(printf '%s\n' "$CASE_OUT" | sed -n 's/^RUN_DIR=//p'); do RUN_DIRS+=("$d"); done
[ "$CASE_RC" -eq 1 ] && ok "run-all rc=1 when no wire delivered" || bad "run-all rc=$CASE_RC (want 1)"

echo "== 13. wall-clock kill, raw.json empty -> resume flush recovers the session's finds =="
reset_cap; rm -f "$CAP/resume.argv"
CASE_OUT="$(grok_env ok GROK_STUB_FORCE_TIMEOUT=1 GROK_STUB_RESUME=payload GROK_STUB_RESUME_ARGV="$CAP/resume.argv" \
   SCOUT_PRODUCER_TIMEOUT=5 "$TMP/bin/bash" "$ROOT/bin/run-scout.sh" crypto A 2>&1)"; CASE_RC=$?
d="$(printf '%s\n' "$CASE_OUT" | sed -n 's/^RUN_DIR=//p' | tail -1)"
[ -n "$d" ] && RUN_DIRS+=("$d")
[ "$CASE_RC" -eq 0 ] && ok "grok timeout + resume flush rc=0" \
  || { printf '%s\n' "$CASE_OUT" | tail -25; bad "grok timeout + resume flush rc=$CASE_RC"; }
[ -s "$CAP/submit.json" ] && ok "resumed grok session's finds delivered" || bad "grok resume flush did not submit"
[ -z "$(cat "$CAP/alerts.log" 2>/dev/null || true)" ] && ok "no TIMEOUT alert after grok resume flush" \
  || bad "grok resume flush alerted: $(cat "$CAP/alerts.log")"
grep -qx -- "--resume" "$CAP/resume.argv" 2>/dev/null && ok "grok flush passes --resume" || bad "grok flush lacks --resume"
grep -qx -- "--disable-web-search" "$CAP/resume.argv" 2>/dev/null && ok "grok flush disables web search" \
  || bad "grok flush did not disable web search"
grep -qx -- "--always-approve" "$CAP/resume.argv" 2>/dev/null && ok "grok flush keeps --always-approve" \
  || bad "grok flush lost --always-approve"
if [ -n "${d:-}" ] && [ -f "$d/meta.json" ]; then
  python3 - "$d/meta.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
sys.exit(0 if m.get("timed_out") is True and m.get("salvaged_via_resume") is True
         and m.get("opportunity_count") == 1 and m.get("session_id") else 1)
PY
  [ $? -eq 0 ] && ok "meta.json records timed_out + salvaged_via_resume + session_id" \
    || bad "meta.json missing timeout/salvage fields: $(cat "$d/meta.json")"
  [ -e "$d/raw.killed.json" ] && ok "killed run's empty raw.json kept as raw.killed.json" \
    || bad "raw.killed.json not kept"
else
  bad "missing grok timeout run meta.json"
fi

echo "== 14. wall-clock kill, resumed session had verified nothing -> TIMEOUT alert, rc!=0 =="
reset_cap
CASE_OUT="$(grok_env ok GROK_STUB_FORCE_TIMEOUT=1 SCOUT_PRODUCER_TIMEOUT=5 \
   "$TMP/bin/bash" "$ROOT/bin/run-scout.sh" crypto A 2>&1)"; CASE_RC=$?
d="$(printf '%s\n' "$CASE_OUT" | sed -n 's/^RUN_DIR=//p' | tail -1)"
[ -n "$d" ] && RUN_DIRS+=("$d")
[ "$CASE_RC" -eq 124 ] && ok "empty resume flush still exits 124" || bad "empty resume flush rc=$CASE_RC (want 124)"
grep -q "TIMEOUT" "$CAP/alerts.log" 2>/dev/null && ok "empty resume flush alerts TIMEOUT" \
  || bad "empty resume flush alert: $(cat "$CAP/alerts.log" 2>/dev/null)"
[ ! -s "$CAP/submit.json" ] && ok "empty resume flush delivered nothing" || bad "empty resume flush submitted"

echo
echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
