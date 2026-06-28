#!/usr/bin/env python3
"""heartbeat.py — dead-man's-switch for the Grant Wire scout (runs as its own Railway cron).

Queries the shared Wire Room Postgres for scout-sourced entries in the last N hours, PER WIRE.
If any expected wire delivered nothing, emails an ops alert. This is deliberately INDEPENDENT
of the scout process: it catches the failures per-run alerts structurally can't — a dead
container, a stopped cron, an expired token that also broke the scout's own alerting, or a
single wire that silently dies or only produces empty runs while others keep delivering —
because it runs elsewhere and reads the DB.

Env: DATABASE_URL (read access to the Wire Room Postgres), SCOUT_SILENCE_HOURS (default 26),
     SCOUT_WIRES (default "crypto ai oss", whitespace-separated expected wires),
     plus RESEND_API_KEY + NOTIFICATION_EMAIL + ALERT_FROM (used by lib/notify.py).
"""
import os
import subprocess
import sys

SOURCE = "claude-code"  # must match lib/submit.py's SOURCE


def main():
    dsn = os.environ.get("DATABASE_URL", "")
    hours = float(os.environ.get("SCOUT_SILENCE_HOURS", "26"))
    wires = os.environ.get("SCOUT_WIRES", "crypto ai oss").split()
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
                "SELECT wire, count(*) FROM scan_entries "
                "WHERE scan_source = %s AND created_at > now() - (%s || ' hours')::interval "
                "GROUP BY wire",
                (SOURCE, str(hours)),
            )
            rows = cur.fetchall()
    finally:
        conn.close()

    counts = {wire: 0 for wire in wires}
    for wire, n in rows:
        if wire in counts:
            counts[wire] = n

    summary = " ".join(f"{wire}={counts[wire]}" for wire in wires)
    silent = [wire for wire in wires if counts[wire] == 0]

    if not silent:
        print(f"heartbeat: ok — {summary} (last {hours:g}h)")
        return 0

    # One or more expected wires silent → alert (best-effort; shares the email path via notify.py)
    silent_str = " ".join(silent)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    subprocess.run(
        [sys.executable, os.path.join(root, "lib", "notify.py"),
         f"⚠️ Grant Wire Scout SILENT wire(s): {silent_str} — 0 entries in {hours:g}h"],
        input=(f"{summary} — SILENT: {silent_str}\n\n"
               f"No scan_source='{SOURCE}' rows reached the Wire Room queue for the above wire(s) "
               f"in the last {hours:g}h. The scout cron may be down, or the claude OAuth token may "
               f"have expired (re-run `claude setup-token` and update CLAUDE_CODE_OAUTH_TOKEN on the "
               f"scout service)."),
        text=True,
    )
    print(f"heartbeat: ALERT — {summary} — SILENT: {silent_str} (last {hours:g}h)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
