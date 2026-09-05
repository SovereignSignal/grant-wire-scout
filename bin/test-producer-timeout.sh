#!/usr/bin/env bash
# test-producer-timeout.sh — regression test for the producer wall-clock cap.
#
# History:
#   2026-06-30  600s cap < real runtime after known-catalog priming → rc=124,
#               work discarded, FAILED alert.
#   2026-09-05  1200s cap still too short for Claude oss/A (400-name prime) →
#               same rc=124, same discarded work.
# Fix: default cap 2400s, and a timeout no longer aborts before extract — if
# raw.json already holds a payload, we salvage it and finish the pipeline.
#
# Asserts:
#   (1) cap < run and nothing flushed → rc=124 (unrecoverable timeout)
#   (2) cap < run but a payload was already written → salvage, rc=0, artifacts
#   (3) cap > run → rc=0 + artifacts
#   (4) shipped default cap >= 2400s
# Portable: ships its own timeout shim + stub claude. No network, no quota.
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

# stub `claude`: STUB_MODE=sleep-first (default) sleeps then writes — a kill during
# the sleep leaves raw.json empty. STUB_MODE=write-first flushes a valid envelope
# then sleeps, so a kill still leaves something to salvage.
cat > "$TMP/claude" <<'EOF'
#!/usr/bin/env bash
payload='{"result":"{\"producer\":\"claude-code\",\"variant\":\"A\",\"wire\":\"crypto\",\"run_id\":\"test\",\"generated_at\":\"2026-06-30T00:00:00Z\",\"opportunities\":[{\"name\":\"Timeout Salvage Grant\",\"source_url\":\"https://127.0.0.1:1/timeout-salvage\",\"wire\":\"crypto\",\"amount\":\"$10k\",\"deadline\":\"2026-12-31\",\"summary\":\"Flushed before the kill.\",\"classification\":\"GRANT\",\"fit_score\":80,\"fit_reason\":\"test\",\"evidence\":[\"https://127.0.0.1:1/timeout-salvage\"],\"discovered_via\":\"web_search\"}],\"rejected\":[]}","total_cost_usd":0.01,"duration_ms":1234,"is_error":false}'
empty='{"result":"{\"producer\":\"claude-code\",\"variant\":\"A\",\"wire\":\"crypto\",\"run_id\":\"test\",\"generated_at\":\"2026-06-30T00:00:00Z\",\"opportunities\":[],\"rejected\":[]}","total_cost_usd":0.01,"duration_ms":1234,"is_error":false}'
mode="${STUB_MODE:-sleep-first}"
if [ "$mode" = "write-first" ]; then
  printf '%s' "$payload"
  sleep "${STUB_SLEEP:-1}"
else
  sleep "${STUB_SLEEP:-1}"
  printf '%s' "$empty"
fi
EOF
chmod +x "$TMP/claude"

base=(env "PATH=$TMP:$PATH" "CLAUDE=$TMP/claude" "SCOUT_PRIME_KNOWN=0")

echo "== case 1: cap (2s) < run (5s), nothing flushed -> rc=124 =="
o1="$("${base[@]}" STUB_SLEEP=5 STUB_MODE=sleep-first SCOUT_PRODUCER_TIMEOUT=2 "$ROOT/run-producer.sh" --wire crypto --variant A 2>&1)"; rc=$?
d1="$(printf '%s\n' "$o1" | sed -n 's/^RUN_DIR=//p' | tail -1)"; CLEAN_DIRS+=("${d1:-}")
[ "$rc" -eq 124 ] || { printf '%s\n' "$o1" | tail -12; fail "expected rc=124 when nothing was flushed, got rc=$rc"; }
printf '%s\n' "$o1" | grep -q "TIMEOUT" || fail "unrecoverable timeout did not say TIMEOUT"
echo "ok: rc=124, nothing to salvage"

echo "== case 2: cap (2s) < run (5s), payload already flushed -> salvage rc=0 =="
o2="$("${base[@]}" STUB_SLEEP=5 STUB_MODE=write-first SCOUT_PRODUCER_TIMEOUT=2 "$ROOT/run-producer.sh" --wire crypto --variant A 2>&1)"; rc=$?
d2="$(printf '%s\n' "$o2" | sed -n 's/^RUN_DIR=//p' | tail -1)"; CLEAN_DIRS+=("${d2:-}")
[ "$rc" -eq 0 ] || { printf '%s\n' "$o2" | tail -15; fail "expected salvage rc=0, got rc=$rc"; }
[ -s "$d2/opportunities.json" ] || fail "missing opportunities.json after salvage"
python3 - "$d2/opportunities.json" "$d2/meta.json" <<'PY' || fail "salvage artifacts invalid"
import json, sys
opps = json.load(open(sys.argv[1])).get("opportunities") or []
assert len(opps) == 1, opps
assert opps[0]["name"] == "Timeout Salvage Grant"
meta = json.load(open(sys.argv[2]))
assert meta.get("timed_out") is True, meta
assert meta.get("opportunity_count") == 1, meta
PY
printf '%s\n' "$o2" | grep -q "salvaged 1" || fail "salvage path did not log recovered count"
echo "ok: salvaged 1 opportunity, timed_out stamped, rc=0"

echo "== case 3: cap (30s) > run (1s) -> rc=0 + artifacts, not timed_out =="
o3="$("${base[@]}" STUB_SLEEP=1 STUB_MODE=sleep-first SCOUT_PRODUCER_TIMEOUT=30 "$ROOT/run-producer.sh" --wire crypto --variant A 2>&1)"; rc=$?
d3="$(printf '%s\n' "$o3" | sed -n 's/^RUN_DIR=//p' | tail -1)"; CLEAN_DIRS+=("${d3:-}")
[ "$rc" -eq 0 ] || { printf '%s\n' "$o3" | tail -15; fail "expected rc=0 within cap, got rc=$rc"; }
[ -s "$d3/opportunities.json" ] || fail "missing opportunities.json artifact"
[ -s "$d3/meta.json" ] || fail "missing meta.json artifact"
python3 - "$d3/meta.json" <<'PY' || fail "clean run should not stamp timed_out"
import json, sys
meta = json.load(open(sys.argv[1]))
assert meta.get("timed_out") is False, meta
PY
echo "ok: rc=0, artifacts written, timed_out=false"

echo "== case 4: shipped default cap >= 2400s =="
default="$(sed -n 's/.*SCOUT_PRODUCER_TIMEOUT:-\([0-9][0-9]*\).*/\1/p' "$ROOT/run-producer.sh" | head -1)"
[ -n "$default" ] && [ "$default" -ge 2400 ] \
  || fail "default SCOUT_PRODUCER_TIMEOUT must be >= 2400 (got '${default:-missing}')"
echo "ok: default cap=${default} >= 2400"

echo "ALL PASS"
