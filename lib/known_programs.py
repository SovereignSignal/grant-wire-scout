#!/usr/bin/env python3
"""known_programs.py — emit the already-catalogued program set to PRIME the producer.

The producer keeps spending finds re-discovering programs the Wire Room already has
(its dedup seen-set was structurally blind, so it never knew). This hands the producer a
recent "already covered" list so it can hunt genuinely-NEW opportunities instead of
re-walking the catalog. The output is spliced into the prompt at {{KNOWN_PROGRAMS}}.

RECALL-POSITIVE by design — this is discovery STEERING, not a reject filter:
  - It only discourages re-reporting the SAME program already on the list.
  - It explicitly KEEPS a genuinely-new round/cohort/RFP of a listed program in scope.
  - It never tells the producer to drop a novel find.

Best-effort, exactly like ledger.py: any failure (no DATABASE_URL, no psycopg2, query
error) prints NOTHING and exits 0, so the prompt simply renders without a known-list and
the run proceeds unchanged.

Usage: known_programs.py <wire> [days] [limit]
Env: DATABASE_URL (the Wire Room Postgres); SCOUT_KNOWN_DAYS, SCOUT_KNOWN_LIMIT overrides.
"""
import os
import sys


def fetch_names(wire, days, limit):
    dsn = os.environ.get("DATABASE_URL", "")
    if not dsn:
        return None
    try:
        import psycopg2
    except ImportError:
        return None
    try:
        conn = psycopg2.connect(dsn)
        try:
            with conn, conn.cursor() as cur:
                # Distinct recent program names for this wire, most-recently-seen first.
                # Any status: re-finding a declined/archived program is just as wasteful as
                # re-finding an approved one. Cap length so the prompt stays lean.
                cur.execute(
                    """
                    SELECT name
                    FROM (
                        SELECT name, MAX(created_at) AS last_seen
                        FROM scan_entries
                        WHERE wire = %s
                          AND name IS NOT NULL AND length(trim(name)) BETWEEN 3 AND 120
                          AND created_at >= now() - (%s || ' days')::interval
                        GROUP BY name
                    ) t
                    ORDER BY last_seen DESC
                    LIMIT %s
                    """,
                    (wire, str(days), limit),
                )
                return [r[0].strip() for r in cur.fetchall() if r[0] and r[0].strip()]
        finally:
            conn.close()
    except Exception:
        return None


def render(wire, names, truncated_at):
    head = (
        f"## Already in our system — do NOT spend finds re-reporting these\n"
        f"These {wire} programs are ALREADY catalogued in the Wire Room (recent finds). "
        f"Re-reporting one adds nothing — it is deduped downstream and wastes a slot. Treat this "
        f"as your \"already covered\" list and prioritize opportunities NOT on it.\n"
        f"IMPORTANT (still in scope): if a program below has a genuinely NEW round / cohort / RFP / "
        f"deadline in 2026 that is not yet reflected here, that new cycle IS a valid fresh find — "
        f"surface it and say what is new. Only the stale re-find of the same thing is the waste.\n"
    )
    bullets = "\n".join(f"- {n}" for n in names)
    tail = f"\n(+ more not shown)" if truncated_at else ""
    return f"{head}\n{bullets}{tail}\n"


def main(wire, days=None, limit=None):
    days = int(days or os.environ.get("SCOUT_KNOWN_DAYS", "120"))
    limit = int(limit or os.environ.get("SCOUT_KNOWN_LIMIT", "150"))
    names = fetch_names(wire, days, limit)
    if not names:
        # best-effort: no DB / error / genuinely empty -> emit nothing, prompt renders bare
        return 0
    sys.stdout.write(render(wire, names, truncated_at=(len(names) >= limit)))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: known_programs.py <wire> [days] [limit]")
    sys.exit(main(*sys.argv[1:]))
