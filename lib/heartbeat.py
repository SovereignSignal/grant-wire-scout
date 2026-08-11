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
    auth / quota      a run failed that way              -> that run's own error class
    zero-yield        status=ok, 0 opportunities         -> ran clean, found nothing (thin day)
    lost-in-delivery  status=ok, opps>0, 0 rows landed   -> broke between submit and the queue

The window is judged from EVERY run in it, not the newest one. A wire runs once per prompt
variant per tick (run-all.sh defaults to SCOUT_VARIANTS='A B'), so it can write two ledger
rows; picking the latest judged the wire by whichever arm finished last — B, the deliberately
low-yield tight-filter — and hid the other arm's auth failure or lost-in-delivery behind B's
clean empty run, reporting it as "a thin day, no action needed". collapse_runs() folds them:
worst status wins, yields sum. Production runs variant A only today, so this was latent — it
would have gone live the moment the A/B that bin/ab-score.sh exists to score was switched on.

A zero-yield alert also carries the wire's habit (summarize_trend): the 26h window spans one
tick and has no memory, so it cannot tell a thin day from a wire drying up. The median daily
yield and the count of prior zero days answer "is this normal for this wire?" — 2026-08-10,
ai returned 0 for the first time in 20 run-days against a median of 3, while crypto zeroes
roughly weekly. Identical alerts, opposite meanings.

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
import statistics
import subprocess
import sys
from collections import namedtuple

SOURCE = "claude-code"  # must match lib/submit.py's SOURCE

# wire: the wire; silent: nothing reached the queue; cause: machine-readable code; text: the why.
Diagnosis = namedtuple("Diagnosis", "wire silent cause text")
# median: typical daily yield; days: run-days observed; zeros: how many yielded nothing —
# all three measured over the days BEFORE any trailing zero streak. streak: consecutive zero
# days at the end of the history, i.e. the streak today's zero would extend.
Trend = namedtuple("Trend", "median days zeros streak")

# Worst status wins when a wire ran more than once in the window: a failed arm is more
# actionable than a clean one, and auth (needs a token rotation) outranks everything.
_SEVERITY = {"ok": 0, "auth": 3, "quota": 2}


def _severity(status):
    return _SEVERITY.get((status or "").strip().lower(), 1)  # any other failure sits above ok


def collapse_runs(rows):
    """Fold every run one wire had in the window into a single (status, opportunity_count).

    A window can hold MORE THAN ONE run per wire: run-all.sh defaults to SCOUT_VARIANTS='A B',
    so each wire runs both prompt arms per tick and each run writes its own ledger row. Reading
    only the newest row judged the wire by whichever arm finished last — variant B, the
    deliberately low-yield tight-filter — and went blind to the other, so an auth failure or a
    lost-in-delivery on variant A could hide behind B's clean empty run and be reported as
    "a thin day, no action needed". That is the wrong-cause hole 2026-08-05 closed, reopened
    through the variant dimension. Worst status wins; yields sum. Returns None for no rows,
    which keeps "no run happened" distinct from "a run happened and found nothing".
    """
    rows = list(rows)
    if not rows:
        return None
    # max() keeps the first maximal element, so ties resolve to the earliest run.
    status = max((r[0] for r in rows), key=_severity)
    return status, sum((r[1] or 0) for r in rows)


def summarize_trend(rows):
    """Per-wire yield habit from (wire, day, daily_total) triples — one per wire per prior day.

    A single alert cannot tell "thin day" from "this wire is drying up"; the 26h window spans
    one tick and has no memory. The median says what this wire normally returns, and the zero
    count says whether an empty day is routine here or unprecedented.

    Day order matters, not just the zero count: consecutive zeros must not self-normalize.
    On 2026-08-11 ai's second consecutive zero day went out as "empty days are normal for this
    wire" because the streak's first day had rolled into the baseline as "1 of them zero" —
    the "no action needed unless it repeats" repeat, reported as routine. A trailing run of
    zeros is therefore split off as `streak` (the streak today's zero would extend, counted in
    run-days — days the wire did not run at all do not break it), and median/days/zeros
    describe only the days before it, so a streak cannot flatten its own baseline either.
    """
    by_wire = {}
    for wire, day, total in rows:
        by_wire.setdefault(wire, []).append((day, total or 0))
    out = {}
    for w, pairs in by_wire.items():
        totals = [n for _, n in sorted(pairs)]
        streak = next((i for i, n in enumerate(reversed(totals)) if n), len(totals))
        base = totals[:len(totals) - streak]
        out[w] = Trend(statistics.median(base) if base else 0, len(base),
                       sum(1 for n in base if not n), streak)
    return out


def _ordinal(n):
    if 10 <= n % 100 <= 20:
        return f"{n}th"
    return f"{n}{ {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th') }"


def _trend_text(trend):
    """One sentence of history, or nothing at all when the wire has none to speak of."""
    if not trend or not (trend.days or trend.streak):
        return ""
    if trend.streak:
        base = (f" The {trend.days} run-days before the streak had a median of "
                f"{trend.median:g}/day." if trend.days else "")
        return (f" Trend: this is the {_ordinal(trend.streak + 1)} consecutive zero day for "
                f"this wire — the repeat the last alert said to watch for, so take a look "
                f"at its sources.{base}")
    if trend.zeros:
        return (f" Trend: a median of {trend.median:g}/day over {trend.days} prior run-days, "
                f"{trend.zeros} of them zero — empty days are normal for this wire.")
    return (f" Trend: a median of {trend.median:g}/day over {trend.days} prior run-days, none "
            f"of them zero — this is a first for this wire, so it is worth a look.")


def diagnose_wire(wire, count, run, trend=None):
    """Explain one wire's delivery, given its queue row count and its collapsed scout_runs rows.

    `run` is None (no run recorded in the window) or a (status, opportunity_count) tuple, as
    returned by collapse_runs(). `trend` is an optional Trend giving the wire's prior habit.
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
                         "a run failed AUTH — the claude token was rejected. Re-run "
                         "`claude setup-token` and update CLAUDE_CODE_OAUTH_TOKEN on the scout service.")
    if status == "quota":
        return Diagnosis(wire, True, "quota",
                         "a run hit the Max usage cap (QUOTA) and produced nothing.")
    if status != "ok":
        return Diagnosis(wire, True, status or "unknown",
                         f"a run failed with status '{status or 'unknown'}' — see the scout "
                         "service's logs and the scout_runs rows for this wire.")
    if opps:
        return Diagnosis(wire, True, "lost-in-delivery",
                         f"the scout ran cleanly and reported {opps} "
                         f"{'opportunity' if opps == 1 else 'opportunities'}, but 0 reached the queue. "
                         "The break is between submit and the queue — a delivery error, or every item "
                         "was deduped as already-seen.")
    return Diagnosis(wire, True, "zero-yield",
                     "the scout ran cleanly and found nothing new — a thin day, not a fault. "
                     "No action needed unless it repeats." + _trend_text(trend))


def _fetch(dsn, hours, wires):
    """Return (counts, runs, trends): queue rows per wire, the wire's collapsed ledger outcome,
    and its yield habit over the 30 days BEFORE the judged window.

    Each query carries an /* hb:<name> */ marker: two of them read scout_runs, so bin/
    test-heartbeat.sh's psycopg2 stub can no longer tell them apart by table name alone.
    """
    import psycopg2

    conn = psycopg2.connect(dsn)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "/* hb:counts */ SELECT wire, count(*) FROM scan_entries "
                "WHERE scan_source = %s AND created_at > now() - (%s || ' hours')::interval "
                "GROUP BY wire",
                (SOURCE, str(hours)),
            )
            counts = {w: n for w, n in cur.fetchall() if w in wires}
        with conn.cursor() as cur:
            # EVERY run in the window we're judging, not just the newest — a wire runs once per
            # prompt variant per tick. "No rows" still means "no run happened in the window".
            cur.execute(
                "/* hb:runs */ SELECT wire, status, opportunity_count FROM scout_runs "
                "WHERE created_at > now() - (%s || ' hours')::interval "
                "ORDER BY wire, created_at",
                (str(hours),),
            )
            grouped = {}
            for w, s, n in cur.fetchall():
                if w in wires:
                    grouped.setdefault(w, []).append((s, n))
            runs = {w: collapse_runs(rows) for w, rows in grouped.items()}
        with conn.cursor() as cur:
            # One row per wire per prior run-day. Bounded to clean runs: a failed run's 0 says
            # something about the scout, not about how much the wire normally yields. Ends where
            # the judged window begins, so today's silence can't flatten its own baseline.
            cur.execute(
                "/* hb:trend */ SELECT wire, (created_at AT TIME ZONE 'UTC')::date AS day, "
                "sum(opportunity_count) FROM scout_runs "
                "WHERE status = 'ok' AND created_at > now() - interval '30 days' "
                "AND created_at <= now() - (%s || ' hours')::interval "
                "GROUP BY wire, day",
                (str(hours),),
            )
            trends = summarize_trend([(w, d, n) for w, d, n in cur.fetchall() if w in wires])
    finally:
        conn.close()
    return counts, runs, trends


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
        counts, runs, trends = _fetch(dsn, hours, set(wires))
    except Exception as e:
        # The heartbeat couldn't read the DB, so it can't rule silence in OR out. Fail loudly
        # (rc=2 -> Railway's crash mail) rather than staying quiet and looking healthy.
        print(f"heartbeat: DB query failed — cannot judge silence: {e}", file=sys.stderr)
        return 2

    results = [diagnose_wire(w, counts.get(w, 0), runs.get(w), trends.get(w)) for w in wires]
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
