#!/usr/bin/env bash
# test-producer-timeout.sh — regression test for the 2026-06-30 rc=124 producer-timeout failure.
#
# What broke: the producer is `timeout <cap> claude -p ...`. The cap (600s) fell below the real
# run time once the 2026-06-29 known-catalog priming was added, so in the Linux container
# `timeout` killed claude mid-flight (rc=124), discarding all work and firing an alert. Fix:
# raise the wall-clock safety-net (default 1200s) so the turn-bounded work can finish.
#
# Asserts: (1) a cap BELOW the run time kills with rc=124 (the bug class); (2) a cap ABOVE it
# finishes rc=0 with artifacts; (3) the shipped default cap is >= 1200s (guards the fix).
# Portable: ships its own `timeout` shim (macOS dev hosts have none) and a stub `claude`, so it
# needs no network, no claude quota, and no DATABASE_URL. Runs in a few seconds.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
CLEAN_DIRS=()
cleanup(){ rm -rf "$TMP"; for d in "${CLEAN_DIRS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done; }
trap cleanup EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

# portable coreutils-`timeout` shim: `timeout DUR CMD...` -> run CMD, SIGTERM after DUR, map to 124.
# Timer is a DIRECT background `sleep` killed by pid, so it can't orphan and hold the caller's
# command-substitution pipe open (a `( sleep; kill ) &` subshell leaks its sleep child on kill).
cat > "$TMP/timeout" <<'EOF'
#!/usr/bin/env bash
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
EOF
chmod +x "$TMP/timeout"

# stub `claude`: sleep STUB_SLEEP, then emit a valid `claude -p --output-format json` envelope.
cat > "$TMP/claude" <<'EOF'
#!/usr/bin/env bash
sleep "${STUB_SLEEP:-1}"
printf '%s' '{"result":"{\"producer\":\"claude-code\",\"variant\":\"A\",\"wire\":\"crypto\",\"run_id\":\"test\",\"generated_at\":\"2026-06-30T00:00:00Z\",\"opportunities\":[],\"rejected\":[]}","total_cost_usd":0.01,"duration_ms":1234,"is_error":false}'
EOF
chmod +x "$TMP/claude"

base=(env "PATH=$TMP:$PATH" "CLAUDE=$TMP/claude" "SCOUT_PRIME_KNOWN=0")

echo "== case 1: cap (2s) < run (5s) -> expect rc=124 (the original bug) =="
o1="$("${base[@]}" STUB_SLEEP=5 SCOUT_PRODUCER_TIMEOUT=2 "$ROOT/run-producer.sh" --wire crypto --variant A 2>&1)"; rc=$?
d1="$(printf '%s\n' "$o1" | sed -n 's/^RUN_DIR=//p' | tail -1)"; CLEAN_DIRS+=("${d1:-}")
[ "$rc" -eq 124 ] || { printf '%s\n' "$o1" | tail -8; fail "expected rc=124 under a too-small cap, got rc=$rc"; }
echo "ok: rc=124"

echo "== case 2: cap (30s) > run (1s) -> expect rc=0 + artifacts =="
o2="$("${base[@]}" STUB_SLEEP=1 SCOUT_PRODUCER_TIMEOUT=30 "$ROOT/run-producer.sh" --wire crypto --variant A 2>&1)"; rc=$?
d2="$(printf '%s\n' "$o2" | sed -n 's/^RUN_DIR=//p' | tail -1)"; CLEAN_DIRS+=("${d2:-}")
[ "$rc" -eq 0 ] || { printf '%s\n' "$o2" | tail -15; fail "expected rc=0 within cap, got rc=$rc"; }
[ -s "$d2/opportunities.json" ] || fail "missing opportunities.json artifact"
[ -s "$d2/meta.json" ] || fail "missing meta.json artifact"
echo "ok: rc=0, artifacts written"

echo "== case 3: shipped default cap >= 1200s (guards the fix) =="
grep -Eq 'SCOUT_PRODUCER_TIMEOUT:-(1[2-9][0-9]{2}|[2-9][0-9]{3,})' "$ROOT/run-producer.sh" \
  || fail "default SCOUT_PRODUCER_TIMEOUT must be >= 1200 in run-producer.sh"
echo "ok: default cap >= 1200"

echo "ALL PASS"
