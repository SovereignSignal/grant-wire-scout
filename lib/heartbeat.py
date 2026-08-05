#!/usr/bin/env python3
"""heartbeat.py — dead-man's-switch for the Grant Wire scout (runs as its own Railway cron).

Queries the shared Wire Room Postgres for scout-sourced entries in the last N hours, PER WIRE.
If any expected wire delivered nothing, emails an ops alert. This is deliberately INDEPENDENT
of the scout process: it catches the failures per-run alerts structurally can't — a dead
container, a stopped cron, an expired token that also broke the scout's own alerting, or a
single wire that silently dies or only produces empty runs while others keep delivering —
because it runs elsewhere and reads the DB.

Silence has MORE THAN ONE CAUSE, so the alert names the real one (2026-08-05). Previously this
asserted "the scout cron may be down, or the claude OAuth token may have expired" on every
alert; the day it first fired for real, the ledger showed a clean $3.00 oss run that simply
found nothing — cron alive, token valid, advice wrong. It now reads the scout_runs ledger (M8,
built for exactly this post-mortem) and reports what actually happened:

    no-run            no ledger row in the window        -> the cron did not run
    auth / quota      the run failed that way            -> the run's own error class
    zero-yield        status=ok, 0 opportunities         -> ran clean, found nothing (thin day)
    lost-in-delivery  status=ok, opps>0, 0 rows landed   -> broke between submit and the queue

EXIT CODES — a firing dead-man's-switch is NOT a crashed deploy. The service runs with
restartPolicyType=NEVER, so any non-zero exit makes Railway send "Deploy Crashed!"; returning 1
on a successful detection meant every true alert arrived twice, once mislabelled as an outage.
    0  healthy, or silent wire(s) detected AND the alert was delivered  (the switch worked)
    1  the alert could NOT be delivered — Railway's crash mail is then the intended backstop
    2  the heartbeat could not do its job at all (no DSN, no driver, DB unreachable)

Env: DATABASE_URL (read access to the Wire Room Postgres), SCOUT_SILENCE_HOURS (default 26),
     SCOUT_WIRES (default "crypto ai oss", whitespace-separated expected wires),
     plus RESEND_API_KEY + NOTIFICATION_EMAIL + ALERT_FROM (used by lib/notify.py).
"""
import os
import subprocess
import sys
from collections import namedtuple

SOURCE = "claude-code"  # must match lib/submit.py's SOURCE

# wire: the wire; silent: nothing reached the queue; cause: machine-readable code; text: the why.
Diagnosis = namedtuple("Diagnosis", "wire silent cause text")


def diagnose_wire(wire, count, run):
    """Explain one wire's delivery, given its queue row count and its latest scout_runs row.

    `run` is None (no run recorded in the window) or a (status, opportunity_count) tuple.
    """
    if count > 0:
        return Diagnosis(wire, False, "delivering", f"{count} entries reached the queue")

    if run is None:
        return Diagnosis(wire, True, "no-run",
                         "no run was recorded in the window — the scout did not run for this wire. "
                         "The cron may be stopped, the container may have failed to start, or the run "
                         "died before it could write its ledger row. Check the scout service's logs.")

    status = (run[0] or "").strip().lower()
    opps = run[1] or 0

    if status == "auth":
        return Diagnosis(wire, True, "auth",
                         "the last run failed AUTH — the claude token was rejected. Re-run "
                         "`claude setup-token` and update CLAUDE_CODE_OAUTH_TOKEN on the scout service.")
    if status == "quota":
        return Diagnosis(wire, True, "quota",
                         "the last run hit the Max usage cap (QUOTA) and produced nothing.")
    if status != "ok":
        return Diagnosis(wire, True, status or "unknown",
                         f"the last run failed with status '{status or 'unknown'}' — see the scout "
                         "service's logs and the scout_runs row for this wire.")
    if opps:
        return Diagnosis(wire, True, "lost-in-delivery",
                         f"the last run completed cleanly and reported {opps} "
                         f"{'opportunity' if opps == 1 else 'opportunities'}, but 0 reached the queue. "
                         "The break is between submit and the queue — a delivery error, or every item "
                         "was deduped as already-seen.")
    return Diagnosis(wire, True, "zero-yield",
                     "the last run completed cleanly and found nothing new — a thin day, not a fault. "
                     "No action needed unless it repeats.")


def _fetch(dsn, hours, wires):
    """Return (counts, runs): queue rows per wire, and the latest ledger row per wire."""
    import psycopg2

    conn = psycopg2.connect(dsn)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT wire, count(*) FROM scan_entries "
                "WHERE scan_source = %s AND created_at > now() - (%s || ' hours')::interval "
                "GROUP BY wire",
                (SOURCE, str(hours)),
            )
            counts = {w: n for w, n in cur.fetchall() if w in wires}
        with conn.cursor() as cur:
            # The most recent run per wire inside the SAME window we're judging, so "no row"
            # means "no run happened in the window", not "no run ever".
            cur.execute(
                "SELECT DISTINCT ON (wire) wire, status, opportunity_count FROM scout_runs "
                "WHERE created_at > now() - (%s || ' hours')::interval "
                "ORDER BY wire, created_at DESC",
                (str(hours),),
            )
            runs = {w: (s, n) for w, s, n in cur.fetchall() if w in wires}
    finally:
        conn.close()
    return counts, runs


def main():
    dsn = os.environ.get("DATABASE_URL", "")
    hours = float(os.environ.get("SCOUT_SILENCE_HOURS", "26"))
    wires = os.environ.get("SCOUT_WIRES", "crypto ai oss").split()
    if not dsn:
        print("heartbeat: DATABASE_URL is required", file=sys.stderr)
        return 2
    try:
        import psycopg2  # noqa: F401
    except ImportError:
        print("heartbeat: psycopg2 is required (add to requirements.txt)", file=sys.stderr)
        return 2

    try:
        counts, runs = _fetch(dsn, hours, set(wires))
    except Exception as e:
        # The heartbeat couldn't read the DB, so it can't rule silence in OR out. Fail loudly
        # (rc=2 -> Railway's crash mail) rather than staying quiet and looking healthy.
        print(f"heartbeat: DB query failed — cannot judge silence: {e}", file=sys.stderr)
        return 2

    results = [diagnose_wire(w, counts.get(w, 0), runs.get(w)) for w in wires]
    summary = " ".join(f"{d.wire}={counts.get(d.wire, 0)}" for d in results)
    silent = [d for d in results if d.silent]

    if not silent:
        print(f"heartbeat: ok — {summary} (last {hours:g}h)")
        return 0

    silent_str = " ".join(d.wire for d in silent)
    causes = ", ".join(sorted({d.cause for d in silent}))
    detail = "\n\n".join(f"{d.wire}: [{d.cause}] {d.text}" for d in silent)
    body = (
        f"{summary} — SILENT: {silent_str} (last {hours:g}h)\n\n"
        f"No scan_source='{SOURCE}' rows reached the Wire Room queue for the above wire(s). "
        f"Cause per wire, read from the scout_runs ledger:\n\n{detail}\n"
    )

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rc = subprocess.run(
        [sys.executable, os.path.join(root, "lib", "notify.py"),
         f"⚠️ Grant Wire Scout SILENT: {silent_str} ({causes}) — 0 entries in {hours:g}h"],
        input=body, text=True,
    ).returncode

    print(f"heartbeat: ALERT — {summary} — SILENT: {silent_str} ({causes}) (last {hours:g}h)",
          file=sys.stderr)
    if rc != 0:
        # Nobody received the alert. Exit non-zero so Railway's "Deploy Crashed" mail — noise
        # when the alert DID go out — becomes the alert of last resort.
        print("heartbeat: alert delivery FAILED — exiting non-zero so the crash mail is the backstop",
              file=sys.stderr)
        return 1
    # Detection worked and the alert was delivered: the switch did its job. Not a crash.
    return 0


if __name__ == "__main__":
    sys.exit(main())
