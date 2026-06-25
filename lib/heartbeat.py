#!/usr/bin/env python3
"""heartbeat.py — dead-man's-switch for the Grant Wire scout (runs as its own Railway cron).

Queries the shared Wire Room Postgres for scout-sourced entries in the last N hours. If none
landed, emails an ops alert. This is deliberately INDEPENDENT of the scout process: it catches
the failures per-run alerts structurally can't — a dead container, a stopped cron, an expired
token that also broke the scout's own alerting — because it runs elsewhere and reads the DB.

Env: DATABASE_URL (read access to the Wire Room Postgres), SCOUT_SILENCE_HOURS (default 26),
     plus RESEND_API_KEY + NOTIFICATION_EMAIL + ALERT_FROM (used by lib/notify.py).
"""
import os
import subprocess
import sys

SOURCE = "claude-code"  # must match lib/submit.py's SOURCE


def main():
    dsn = os.environ.get("DATABASE_URL", "")
    hours = float(os.environ.get("SCOUT_SILENCE_HOURS", "26"))
    if not dsn:
        print("heartbeat: DATABASE_URL is required", file=sys.stderr)
        return 2
    try:
        import psycopg2
    except ImportError:
        print("heartbeat: psycopg2 is required (add to requirements.txt)", file=sys.stderr)
        return 2

    conn = psycopg2.connect(dsn)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT count(*) FROM scan_entries "
                "WHERE scan_source = %s AND created_at > now() - (%s || ' hours')::interval",
                (SOURCE, str(hours)),
            )
            (n,) = cur.fetchone()
    finally:
        conn.close()

    if n and n > 0:
        print(f"heartbeat: ok — {n} '{SOURCE}' entries in the last {hours:g}h")
        return 0

    # Silent → alert (best-effort; shares the email path via notify.py)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    subprocess.run(
        [sys.executable, os.path.join(root, "lib", "notify.py"),
         f"⚠️ Grant Wire Scout SILENT — 0 entries in {hours:g}h"],
        input=(f"No scan_source='{SOURCE}' rows reached the Wire Room queue in the last {hours:g}h. "
               f"The scout cron may be down, or the claude OAuth token may have expired "
               f"(re-run `claude setup-token` and redeploy the credential to the Railway volume)."),
        text=True,
    )
    print(f"heartbeat: ALERT — 0 '{SOURCE}' entries in {hours:g}h", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
