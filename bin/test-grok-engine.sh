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
cat > "$TMP/bin/timeout" <<'SH'
#!/usr/bin/env bash
dur="$1"; shift
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

echo
echo "PASS=$PASS FAIL=$FAILN"
[ "$FAILN" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
