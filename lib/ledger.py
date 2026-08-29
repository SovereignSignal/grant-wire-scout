#!/usr/bin/env python3
"""ledger.py — write a durable run record to the Wire Room Postgres (M8).

The scout's runs/ directory is ephemeral container filesystem, so post-mortems had
nothing to read once a container cycled. This persists ONE row per run (run_id, wire,
variant, status, opportunity_count, cost, duration) to the scout_runs table — queryable
long after the container is gone, and a foundation for trend/observability queries.

opportunity_count is the POST-DEDUP delivered set. found_count / dedup_dropped live on
meta.json (and opportunities.json funnel) so a later column can distinguish saturation
from a thin day without this writer mutating the shared Wire Room schema.

Best-effort by design: a ledger failure must NEVER break the run. Callers invoke it with
`|| true` and it returns 0 even on DB errors.

Usage: ledger.py <run_dir> <status> [error_class]
  status: ok | auth | quota | empty | delivery | failed
Env: DATABASE_URL (the Wire Room Postgres)
"""
import json
import os
import sys
from pathlib import Path


def main(run_dir, status, error_class=None):
    dsn = os.environ.get("DATABASE_URL", "")
    if not dsn:
        print("ledger: DATABASE_URL not set — run not recorded (non-fatal)", file=sys.stderr)
        return 0
    try:
        import psycopg2
    except ImportError:
        print("ledger: psycopg2 not installed — run not recorded (non-fatal)", file=sys.stderr)
        return 0

    rd = Path(run_dir)
    meta = {}
    try:
        meta = json.loads((rd / "meta.json").read_text())
    except Exception:
        pass
    n = meta.get("opportunity_count")
    if n is None:
        try:
            n = len(json.loads((rd / "opportunities.json").read_text()).get("opportunities", []))
        except Exception:
            n = None

    row = {
        "run_id": meta.get("run_id") or rd.name,
        "wire": meta.get("wire") or "",
        "variant": meta.get("variant"),
        "model": meta.get("model"),
        "status": status,
        "opportunity_count": n,
        "error_class": error_class,
        "cost_usd": meta.get("cost_usd"),
        "duration_ms": meta.get("duration_ms"),
    }
    extra = ""
    if meta.get("found_count") is not None or meta.get("dedup_dropped"):
        extra = (f" found={meta.get('found_count')} "
                 f"dedup_dropped={meta.get('dedup_dropped')}")
    row["found_count"] = meta.get("found_count")
    row["dedup_dropped"] = meta.get("dedup_dropped")

    insert_funnel = """INSERT INTO scout_runs
                         (run_id, wire, variant, model, status, opportunity_count,
                          error_class, cost_usd, duration_ms, found_count, dedup_dropped,
                          finished_at)
                       VALUES (%(run_id)s, %(wire)s, %(variant)s, %(model)s, %(status)s,
                               %(opportunity_count)s, %(error_class)s, %(cost_usd)s,
                               %(duration_ms)s, %(found_count)s, %(dedup_dropped)s, now())
                       ON CONFLICT (run_id) DO UPDATE SET
                         status            = EXCLUDED.status,
                         opportunity_count = EXCLUDED.opportunity_count,
                         error_class       = EXCLUDED.error_class,
                         cost_usd          = EXCLUDED.cost_usd,
                         duration_ms       = EXCLUDED.duration_ms,
                         found_count       = EXCLUDED.found_count,
                         dedup_dropped     = EXCLUDED.dedup_dropped,
                         finished_at       = now()"""
    insert_base = """INSERT INTO scout_runs
                         (run_id, wire, variant, model, status, opportunity_count,
                          error_class, cost_usd, duration_ms, finished_at)
                       VALUES (%(run_id)s, %(wire)s, %(variant)s, %(model)s, %(status)s,
                               %(opportunity_count)s, %(error_class)s, %(cost_usd)s,
                               %(duration_ms)s, now())
                       ON CONFLICT (run_id) DO UPDATE SET
                         status            = EXCLUDED.status,
                         opportunity_count = EXCLUDED.opportunity_count,
                         error_class       = EXCLUDED.error_class,
                         cost_usd          = EXCLUDED.cost_usd,
                         duration_ms       = EXCLUDED.duration_ms,
                         finished_at       = now()"""
    try:
        conn = psycopg2.connect(dsn)
        try:
            with conn, conn.cursor() as cur:
                try:
                    cur.execute(insert_funnel, row)
                except Exception as col_err:
                    # Columns land via sql/scout_runs_funnel.sql. Until that
                    # ALTER runs, fall back so a missing column cannot drop the row.
                    if "found_count" not in str(col_err) and "dedup_dropped" not in str(col_err):
                        raise
                    conn.rollback()
                    cur.execute(insert_base, row)
                    extra += " (funnel columns not yet on scout_runs)"
        finally:
            conn.close()
    except Exception as e:
        print(f"ledger: write failed (non-fatal): {e}", file=sys.stderr)
        return 0
    print(f"ledger: recorded run {row['run_id']} status={status} opps={n}{extra}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit("usage: ledger.py <run_dir> <status> [error_class]")
    sys.exit(main(*sys.argv[1:]))
