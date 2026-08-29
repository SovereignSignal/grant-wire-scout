#!/usr/bin/env python3
"""skip_if_fed.py — opt-in: skip a wire the other scout lane just filled.

When SCOUT_SKIP_IF_FED_HOURS is set (e.g. 36), a Thursday Claude oss tick that
would only re-discover Wednesday's Grok batch exits 10 instead of burning
~15 min of Max / SuperGrok. Default unset/0 = never skip (production safe).

"The other lane" = every scout scan_source except this process's
SCOUT_SCAN_SOURCE. Rows in scan_entries (queue), not ledger — "fed" means
something actually landed.

Exit codes (so run-scout.sh can tell skip from error):
  0   not configured, or the other lane has NOT fed this wire — run normally
  10  skip: the other lane landed ≥1 row for this wire inside the window
  2   misconfiguration (bad hours)

Best-effort: no DATABASE_URL / query failure → 0 (run, don't skip).

Usage: skip_if_fed.py <wire>
Env: DATABASE_URL, SCOUT_SKIP_IF_FED_HOURS, SCOUT_SCAN_SOURCE
"""
import os
import sys

SCOUT_SOURCES = ("claude-code", "grok-scout", "grok-build")


def other_sources(mine: str) -> list[str]:
    mine = (mine or "").strip()
    return [s for s in SCOUT_SOURCES if s != mine]


def fed_recently(wire: str, hours: float, sources: list[str]) -> int | None:
    """Return landed-row count, or None if we could not ask."""
    dsn = os.environ.get("DATABASE_URL", "")
    if not dsn or not sources:
        return None
    try:
        import psycopg2
    except ImportError:
        return None
    try:
        conn = psycopg2.connect(dsn)
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT count(*) FROM scan_entries "
                    "WHERE wire = %s AND scan_source = ANY(%s) "
                    "AND created_at > now() - (%s || ' hours')::interval",
                    (wire, sources, str(hours)),
                )
                return int(cur.fetchone()[0] or 0)
        finally:
            conn.close()
    except Exception as e:
        print(f"skip_if_fed: query failed (running anyway): {e}", file=sys.stderr)
        return None


def main(wire: str) -> int:
    raw = (os.environ.get("SCOUT_SKIP_IF_FED_HOURS") or "").strip()
    if not raw or raw == "0":
        return 0
    try:
        hours = float(raw)
    except ValueError:
        print(f"skip_if_fed: SCOUT_SKIP_IF_FED_HOURS must be a number (got {raw!r})",
              file=sys.stderr)
        return 2
    if hours <= 0:
        return 0
    mine = os.environ.get("SCOUT_SCAN_SOURCE", "claude-code")
    others = other_sources(mine)
    n = fed_recently(wire, hours, others)
    if n is None:
        return 0
    if n > 0:
        print(f"skip_if_fed: {wire} already fed by {others} "
              f"({n} row{'s' if n != 1 else ''} in last {hours:g}h) — skipping")
        return 10
    print(f"skip_if_fed: {wire} not fed by {others} in last {hours:g}h — running")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: skip_if_fed.py <wire>")
    sys.exit(main(sys.argv[1]))
