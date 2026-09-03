#!/usr/bin/env python3
"""known_programs.py — tell the producer what it has already found, so it hunts NEW.

The output is spliced into the prompt at {{KNOWN_PROGRAMS}}.

WHY THIS SHAPE. The first version sent "the 150 most recent names for this wire, from any
source". The ai wire carries 2,807 distinct names in a 120-day window and crypto 2,164, so
the cap was filled by whatever the RSS and Telegram feeds happened to land that week, and
the producer's OWN repeat offenders fell off the list entirely. In the 30 days to
2026-09-03 the Claude lane re-found Avalanche Team1 seven times and NSF CISE Future CoRe
eight, both while the priming was on.

So the list is now built from the two sets that actually predict a wasted slot:

  1. What THIS producer already submitted (scan_source = $SCOUT_SCAN_SOURCE). Its own
     history is the single best predictor of what it will re-find tomorrow.
  2. What the operator has already DECIDED on (approved / declined / archived / duplicate).
     A decided program is settled: re-finding it cannot teach anyone anything.

Rows still awaiting review are deliberately excluded — the producer re-finding something
that is sitting unreviewed in the queue is not the failure mode, and listing them would
crowd out the two sets above.

Best-effort by contract: no DATABASE_URL, no psycopg2, or any DB error prints NOTHING and
exits 0, so the prompt renders bare and the run proceeds exactly as before.

Usage: known_programs.py <wire> [days] [limit]
Env: DATABASE_URL; SCOUT_SCAN_SOURCE (which producer is asking); SCOUT_KNOWN_DAYS,
     SCOUT_KNOWN_LIMIT overrides.
"""
from __future__ import annotations

import os
import sys

_DECIDED = ("approved", "declined", "archived", "duplicate", "deduped")


def fetch_names(wire, days, limit, source=None):
    """[(name, origin)] where origin is 'self' or 'decided', most recent first."""
    dsn = os.environ.get("DATABASE_URL", "")
    if not dsn:
        return None
    try:
        import psycopg2
    except ImportError:
        return None
    source = source or os.environ.get("SCOUT_SCAN_SOURCE", "")
    try:
        conn = psycopg2.connect(dsn)
        try:
            with conn, conn.cursor() as cur:
                # Two buckets in one pass, ranked so the producer's own history wins the cap.
                # 'self' rows are what this producer submitted; 'decided' rows are settled
                # verdicts from any source. A name in both is reported as 'self'.
                cur.execute(
                    """
                    /* known */
                    SELECT name, origin FROM (
                        SELECT name,
                               MIN(CASE WHEN scan_source = %s THEN 0 ELSE 1 END) AS rank,
                               CASE WHEN bool_or(scan_source = %s) THEN 'self' ELSE 'decided' END
                                    AS origin,
                               MAX(created_at) AS last_seen
                        FROM scan_entries
                        WHERE wire = %s
                          AND name IS NOT NULL AND length(trim(name)) BETWEEN 3 AND 120
                          AND created_at >= now() - (%s || ' days')::interval
                          AND (scan_source = %s OR status = ANY(%s))
                        GROUP BY name
                    ) t
                    ORDER BY rank, last_seen DESC
                    LIMIT %s
                    """,
                    (source, source, wire, str(days), source, list(_DECIDED), limit),
                )
                out = []
                for row in cur.fetchall():
                    name = (row[0] or "").strip()
                    if name:
                        out.append((name, row[1] if len(row) > 1 else "decided"))
                return out
        finally:
            conn.close()
    except Exception:
        return None


def render(wire, rows, truncated_at):
    mine = [n for n, origin in rows if origin == "self"]
    others = [n for n, origin in rows if origin != "self"]

    head = (
        f"## Already in our system — do NOT spend finds re-reporting these\n"
        f"Re-reporting one of these adds nothing: it is deduped downstream and wastes a slot "
        f"you could have spent on something the {wire} wire has never seen.\n"
        f"IMPORTANT (still in scope): if a program below has a genuinely NEW round / cohort / "
        f"RFP / deadline in 2026 that is not yet reflected here, that new cycle IS a valid "
        f"fresh find — surface it and say what is new. Only the stale re-find of the same "
        f"thing is the waste.\n"
    )
    parts = [head]
    if mine:
        parts.append(
            "\n### You have already reported these yourself — re-finding them is the single "
            "biggest way this run wastes its budget\n"
            + "\n".join(f"- {n}" for n in mine)
            + "\n"
        )
    if others:
        parts.append(
            "\n### Already decided by the operator (approved, declined, or archived)\n"
            + "\n".join(f"- {n}" for n in others)
            + "\n"
        )
    if truncated_at:
        parts.append("\n(+ more not shown)\n")
    return "".join(parts)


def main(wire, days=None, limit=None):
    days = int(days or os.environ.get("SCOUT_KNOWN_DAYS", "120"))
    limit = int(limit or os.environ.get("SCOUT_KNOWN_LIMIT", "400"))
    rows = fetch_names(wire, days, limit)
    if not rows:
        # best-effort: no DB / error / genuinely empty -> emit nothing, prompt renders bare
        return 0
    sys.stdout.write(render(wire, rows, truncated_at=(len(rows) >= limit)))
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: known_programs.py <wire> [days] [limit]")
    sys.exit(main(*sys.argv[1:]))
