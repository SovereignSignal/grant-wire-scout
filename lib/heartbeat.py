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
    zero-yield        status=ok, 0 opportunities         -> ran clean, nothing new landed
    lost-in-delivery  status=ok, opps>0, 0 rows landed   -> broke between submit and the queue

A 60h window is required on the weekday cadence (Claude Sun/Tue/Thu/Sat 04:00, Grok
Mon/Wed/Fri 06:00, heartbeat daily 14:00). 52h looks back to 10:00 two days earlier and
misses the previous Claude tick (04:00 is 58h before Tue/Thu/Sat 14:00) and Friday's
lookback also misses Wednesday's Grok tick (56h). 60h covers both.

A wire with rows is never SILENT. A producer lane can still be dead: diagnose_lane()
pages if Claude (or Grok) has no ok/skipped ledger row, or failed AUTH/QUOTA, even
when the other lane already fed the queue. A single-wire timeout / other / empty
does not mark the whole lane dead when another wire on that producer already
ran ok — that is the 2026-09-05 heartbeat: Claude crypto+ai succeeded, oss
timed out as status=other, and worst-status collapse paged LANE: Claude
(lane-other) for the rest of the 60h window. AUTH/QUOTA still win (lane-wide).

By default this watches BOTH scout lanes (claude-code + grok-scout). After Grok existed,
"SILENT: oss" no longer meant the oss wire was empty — 2026-08-27 Claude oss was a
saturation zero while Wednesday Grok had just delivered 5 oss rows. A wire is silent only
when NEITHER source landed rows. Pin a single lane with SCOUT_SCAN_SOURCE=claude-code
(or grok-scout) if you want the old isolated monitor.

The window is judged from EVERY run in it, not the newest one. A wire can write two ledger
rows if SCOUT_VARIANTS='A B'; picking the latest judged the wire by whichever arm finished
last — B, the deliberately low-yield tight-filter — and hid the other arm's auth failure
or lost-in-delivery behind B's clean empty run. collapse_runs() folds them: worst status
wins, yields sum. Production runs variant A only; this stays latent unless A/B is on.

A zero-yield alert also carries the wire's habit (summarize_trend). opportunity_count is
post-dedup, so a clean 0 is either a thin market OR every find was already in the catalog
— same ledger row, opposite meanings. The copy says both; the trend says whether to look.

A healthy day can also send a daily digest (lib/digest.py) so operators can see what
landed, which models ran, and week/month quota-equivalent spend. That is visibility,
not an alert — it does not write scout_alerts. It stays off unless
SCOUT_REVIEW_EMAIL=1 (WireOps is the routine mail). SCOUT_DIGEST=0 forces it off.

EXIT CODES — a firing dead-man's-switch is NOT a crashed deploy. The service runs with
restartPolicyType=NEVER, so any non-zero exit makes Railway send "Deploy Crashed!"; returning 1
on a successful detection meant every true alert arrived twice, once mislabelled as an outage.
    0  healthy, or silent wire(s) detected AND the alert was delivered  (the switch worked)
    1  the alert or the daily digest could NOT be delivered — Railway's crash mail is then the backstop
    2  the heartbeat could not do its job at all (no DSN, no driver, DB unreachable)

Env: DATABASE_URL (read access to the Wire Room Postgres), SCOUT_SILENCE_HOURS (default 60),
     SCOUT_WIRES (default "crypto ai oss", whitespace-separated expected wires),
     plus RESEND_API_KEY + NOTIFICATION_EMAIL + ALERT_FROM (used by lib/notify.py).
     SCOUT_SCAN_SOURCES (default "claude-code grok-scout") is the wire-feed set.
     SCOUT_SCAN_SOURCE, if set, pins a single lane (overrides the default pair).
     Ledger rows are scoped by run_id prefix so a dedicated single-lane heartbeat
     does not diagnose the other producer's ticks.
     SCOUT_REVIEW_EMAIL (default off) sends the daily "N to review" email after
     the silence check. Set it to 1 to turn that mail back on. SCOUT_DIGEST=0
     forces it off either way. Exception and lane-death alerts are separate.
"""
import os
import statistics
import subprocess
import sys
from collections import namedtuple

# Map scan_source → scout_runs.run_id prefix (run-producer.sh: ${PRODUCER}-${ts}).
# Without this, a Grok AUTH would make a Claude-only heartbeat scream, and vice versa.
_RUN_ID_PREFIX = {
    "claude-code": "claude-code-",
    "grok-scout": "grok-build-",
    "grok-build": "grok-build-",
}


def watch_sources():
    """Which scan_source values count as 'the scout fed this wire'.

    SCOUT_SCAN_SOURCES wins when set (whitespace-separated). Else SCOUT_SCAN_SOURCE
    pins one lane. Else both lanes — the Wire Room is fed if either producer landed.
    """
    multi = (os.environ.get("SCOUT_SCAN_SOURCES") or "").split()
    if multi:
        return multi
    single = (os.environ.get("SCOUT_SCAN_SOURCE") or "").strip()
    if single:
        return [single]
    return ["claude-code", "grok-scout"]


# Kept for callers / tests that imported SOURCE. Prefer watch_sources() — it is
# live, so SCOUT_SCAN_SOURCE set after import (test-grok-engine.sh) still works
# if diagnose_wire reads watch_sources() rather than this snapshot.
SOURCE = os.environ.get("SCOUT_SCAN_SOURCE") or "claude-code"


def run_id_prefix(source=None):
    source = source if source is not None else (watch_sources()[0] if watch_sources() else "claude-code")
    explicit = (os.environ.get("SCOUT_RUN_ID_PREFIX") or "").strip()
    if explicit and len(watch_sources()) == 1:
        return explicit if explicit.endswith("-") else explicit + "-"
    return _RUN_ID_PREFIX.get(source, source.rstrip("-") + "-")

# wire: the wire; silent: nothing reached the queue; cause: machine-readable code; text: the why.
Diagnosis = namedtuple("Diagnosis", "wire silent cause text")
# median: typical daily yield; days: run-days observed; zeros: how many yielded nothing —
# all three measured over the days BEFORE any trailing zero streak. streak: consecutive zero
# days at the end of the history, i.e. the streak today's zero would extend.
Trend = namedtuple("Trend", "median days zeros streak")

# Worst status wins when a wire ran more than once in the window: a failed arm is more
# actionable than a clean one, and auth (needs a token rotation) outranks everything.
# skipped = the lane ran and chose not to burn quota (SCOUT_SKIP_IF_FED_HOURS) — alive.
_SEVERITY = {"ok": 0, "skipped": 0, "auth": 3, "quota": 2}
# Per-tick misses that are not lane-wide. collapse_lane() ignores these when the
# same producer also wrote an ok/skipped row in the window.
_LANE_ALIVE = frozenset(("ok", "skipped"))
_LANE_TICK_MISS = frozenset(("timeout", "other", "empty", "failed", "delivery"))

_LANE_LABEL = {
    "claude-code": "Claude",
    "grok-scout": "Grok",
    "grok-build": "Grok Build",
}


def _severity(status):
    return _SEVERITY.get((status or "").strip().lower(), 1)  # any other failure sits above ok


def collapse_runs(rows):
    """Fold every run one wire had in the window into a single (status, opportunity_count).

    A window can hold MORE THAN ONE run per wire: two prompt variants, or Claude + Grok
    both ticking inside 60h. Reading only the newest row judged the wire by whichever
    arm finished last and went blind to the other, so an auth failure or a
    lost-in-delivery on variant A could hide behind B's clean empty run and be reported as
    "a thin day, no action needed". Worst status wins; yields sum. Returns None for no rows,
    which keeps "no run happened" distinct from "a run happened and found nothing".
    """
    rows = list(rows)
    if not rows:
        return None
    # max() keeps the first maximal element, so ties resolve to the earliest run.
    status = max((r[0] for r in rows), key=_severity)
    opps = sum((r[1] or 0) for r in rows)
    # Optional found_count (pre-dedup). Absent on older ledger rows / fixtures.
    if any(len(r) >= 3 and r[2] is not None for r in rows):
        found = sum((r[2] or 0) for r in rows if len(r) >= 3)
        return status, opps, found
    return status, opps


def collapse_lane(rows):
    """Fold one producer's ticks across every wire it ran in the window.

    AUTH/QUOTA still win — those are lane-wide (shared token / shared cap).
    A timeout, empty, delivery miss, or generic `other` on one wire does not
    page the whole lane when another wire already ran ok/skipped. That was the
    2026-09-05 LANE: Claude (lane-other) mail: crypto+ai ok, oss rc=124
    recorded as status=other, worst-status collapse called Claude dead.

    Rows arrive oldest first. An ok run AFTER the last auth/quota row proves the
    token and the cap are fine again, so that older failure no longer pages.
    Without this, the 2026-09-27 04:23 Claude QUOTA would page LANE: Claude for
    the whole 60h window, including after Tuesday's tick ran clean. `skipped`
    does not count as recovery: a skip-if-fed tick never called the CLI.
    """
    rows = list(rows)
    if not rows:
        return None
    statuses = [(r[0] or "").strip().lower() for r in rows]
    opps = sum((r[1] or 0) for r in rows)
    last_lane_wide = max((i for i, s in enumerate(statuses) if s in ("auth", "quota")), default=-1)
    if last_lane_wide >= 0 and "ok" in statuses[last_lane_wide + 1:]:
        statuses = statuses[last_lane_wide + 1:]
    if any(s == "auth" for s in statuses):
        status = "auth"
    elif any(s == "quota" for s in statuses):
        status = "quota"
    elif any(s in _LANE_ALIVE for s in statuses):
        status = "ok" if "ok" in statuses else "skipped"
    else:
        status = max(statuses, key=_severity)
    return status, opps


def summarize_trend(rows):
    """Per-wire yield habit from (wire, day, daily_total) triples — one per wire per prior day.

    A single alert cannot tell "thin day" from "this wire is drying up"; the silence window
    spans one Claude tick and has no memory. The median says what this wire normally returns, and the zero
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


def _auth_remedy():
    """Token-rotation advice for the lane(s) this heartbeat is watching."""
    sources = watch_sources()
    bits = []
    if "claude-code" in sources:
        bits.append(
            "If the Claude lane failed AUTH: re-run `claude setup-token` and update "
            "CLAUDE_CODE_OAUTH_TOKEN on the scout service."
        )
    if "grok-scout" in sources or "grok-build" in sources:
        bits.append(
            "If the Grok lane failed AUTH: refresh GROK_AUTH_JSON from `grok login` "
            "(contents of ~/.grok/auth.json) on the grok-scout service, or set XAI_API_KEY."
        )
    if not bits:
        bits.append("a run failed AUTH — rotate the credentials for this scout lane.")
    if len(bits) == 1 and "claude-code" in sources and "grok-scout" not in sources:
        return (
            "a run failed AUTH — the claude token was rejected. Re-run "
            "`claude setup-token` and update CLAUDE_CODE_OAUTH_TOKEN on the scout service."
        )
    grok_only = (("grok-scout" in sources or "grok-build" in sources)
                 and "claude-code" not in sources)
    if len(bits) == 1 and grok_only:
        return (
            "a run failed AUTH — Grok Build credentials were rejected. Refresh "
            "GROK_AUTH_JSON from `grok login` (contents of ~/.grok/auth.json) on the "
            "grok-scout service, or set XAI_API_KEY."
        )
    return "a run failed AUTH. " + " ".join(bits)


def diagnose_wire(wire, count, run, trend=None):
    """Explain one wire's delivery, given its queue row count and its collapsed scout_runs rows.

    `run` is None (no run recorded in the window) or a (status, opportunity_count) tuple
    — optionally a third found_count — as returned by collapse_runs(). `trend` is an
    optional Trend giving the wire's prior habit.

    `count` is across every scan_source this heartbeat watches. After Grok existed, a Claude
    saturation zero must not page if the other lane already fed the wire.
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
    found = run[2] if len(run) >= 3 else None

    if status == "auth":
        return Diagnosis(wire, True, "auth", _auth_remedy())
    if status == "quota":
        return Diagnosis(wire, True, "quota",
                         "a run hit the Max / SuperGrok usage cap (QUOTA) and produced nothing.")
    if status == "timeout":
        return Diagnosis(wire, True, "timeout",
                         "a run hit the producer wall-clock cap (TIMEOUT) and nothing usable "
                         "was salvaged. The hunt ran past SCOUT_PRODUCER_TIMEOUT.")
    if status == "skipped":
        return Diagnosis(wire, True, "zero-yield",
                         "the scout skipped this wire (the other lane had just fed it) and "
                         "nothing from either lane is in the queue. Not a crash.")
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
    if found:
        return Diagnosis(wire, True, "saturation",
                         f"the scout ran cleanly and found {found} "
                         f"{'candidate' if found == 1 else 'candidates'}, but every one was already "
                         "in the catalog (dedup emptied the batch). Saturated, not a thin day. "
                         "No action needed unless it repeats." + _trend_text(trend))
    return Diagnosis(wire, True, "zero-yield",
                     "the scout ran cleanly and found nothing new — either a thin day, or every "
                     "find was already in the catalog (dedup emptied the batch). Not a crash. "
                     "No action needed unless it repeats." + _trend_text(trend))


def source_for_run_id(run_id):
    """Map a scout_runs.run_id (or a fixture source name) back to a watched scan_source."""
    if not run_id:
        return None
    if run_id in _RUN_ID_PREFIX:
        return run_id
    for src in watch_sources():
        if str(run_id).startswith(run_id_prefix(src)):
            return src
    return None


def diagnose_lane(source, run):
    """Is this producer lane alive, even if the other lane already fed the wires?

    `run` is None (no ledger row for this prefix) or a collapse_runs() tuple.
    A skip-if-fed tick is alive. AUTH/QUOTA/no-run still page — that is the
    2026-08-27 hole: Claude AUTH on oss was invisible because Grok had just
    landed five oss rows. A timeout/other on one wire next to an ok tick
    is alive — collapse_lane() already folded that to ok.
    """
    label = _LANE_LABEL.get(source, source)
    if run is None:
        return Diagnosis(source, True, "lane-dead",
                         f"{label} wrote no scout_runs row in the window — that lane's cron "
                         "did not run (or died before the ledger write). The other lane may "
                         "still be feeding the Wire Room. Check that service's logs.")
    status = (run[0] or "").strip().lower()
    if status in ("ok", "skipped"):
        return Diagnosis(source, False, "alive",
                         f"{label} ran (status={status})")
    if status == "auth":
        return Diagnosis(source, True, "lane-auth",
                         f"{label} failed AUTH. {_auth_remedy()}")
    if status == "quota":
        return Diagnosis(source, True, "lane-quota",
                         f"{label} hit the Max / SuperGrok usage cap (QUOTA).")
    if status == "timeout":
        return Diagnosis(source, True, "lane-timeout",
                         f"{label} hit the producer wall-clock cap (TIMEOUT) and nothing "
                         "usable was salvaged.")
    if status in _LANE_TICK_MISS:
        return Diagnosis(source, True, f"lane-{status}",
                         f"{label} wrote no successful tick in the window "
                         f"(status='{status}'). Often a wall-clock kill recorded as "
                         f"'other' before TIMEOUT was a ledger class. See that "
                         f"service's logs and its scout_runs rows.")
    return Diagnosis(source, True, f"lane-{status or 'unknown'}",
                     f"{label} failed with status '{status or 'unknown'}'. "
                     "See that service's logs and its scout_runs rows.")


def _fetch(dsn, hours, wires):
    """Return (counts, runs, trends, lanes).

    counts/runs/trends judge wire-feed (a wire is silent only if NEITHER lane
    landed rows). lanes is per-producer: None means "skip lane diagnosis"
    (hermetic fixtures that predate this query); a dict is source → collapsed
    run or None (no row → that lane is dead even when the other fed the queue).

    Each query carries an /* hb:<name> */ marker so bin/test-heartbeat.sh's
    psycopg2 stub can tell two scout_runs reads apart.
    """
    import psycopg2

    sources = watch_sources()
    likes = [run_id_prefix(s) + "%" for s in sources]
    conn = psycopg2.connect(dsn)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "/* hb:funnel */ SELECT 1 FROM information_schema.columns "
                "WHERE table_schema = 'public' AND table_name = 'scout_runs' "
                "AND column_name = 'found_count'",
            )
            has_funnel = bool(cur.fetchall())
        with conn.cursor() as cur:
            cur.execute(
                "/* hb:counts */ SELECT wire, count(*) FROM scan_entries "
                "WHERE scan_source = ANY(%s) AND created_at > now() - (%s || ' hours')::interval "
                "GROUP BY wire",
                (sources, str(hours)),
            )
            counts = {w: n for w, n in cur.fetchall() if w in wires}
        with conn.cursor() as cur:
            # EVERY run in the window we're judging, not just the newest — a wire runs once per
            # prompt variant per tick, and both lanes can tick inside 60h. "No rows" still
            # means "no run happened in the window" for the watched prefixes.
            cols = "wire, status, opportunity_count" + (", found_count" if has_funnel else "")
            cur.execute(
                f"/* hb:runs */ SELECT {cols} FROM scout_runs "
                "WHERE created_at > now() - (%s || ' hours')::interval "
                "AND run_id LIKE ANY(%s) "
                "ORDER BY wire, created_at",
                (str(hours), likes),
            )
            grouped = {}
            for row in cur.fetchall():
                w, s, n = row[0], row[1], row[2]
                if w not in wires:
                    continue
                found = row[3] if has_funnel and len(row) > 3 else None
                grouped.setdefault(w, []).append((s, n, found) if found is not None else (s, n))
            runs = {w: collapse_runs(rows) for w, rows in grouped.items()}
        with conn.cursor() as cur:
            # One row per wire per prior run-day. Bounded to clean runs: a failed run's 0 says
            # something about the scout, not about how much the wire normally yields. Ends where
            # the judged window begins, so today's silence can't flatten its own baseline.
            cur.execute(
                "/* hb:trend */ SELECT wire, (created_at AT TIME ZONE 'UTC')::date AS day, "
                "sum(opportunity_count) FROM scout_runs "
                "WHERE status IN ('ok', 'skipped') AND created_at > now() - interval '30 days' "
                "AND created_at <= now() - (%s || ' hours')::interval "
                "AND run_id LIKE ANY(%s) "
                "GROUP BY wire, day",
                (str(hours), likes),
            )
            trends = summarize_trend([(w, d, n) for w, d, n in cur.fetchall() if w in wires])
        with conn.cursor() as cur:
            cur.execute(
                "/* hb:lanes */ SELECT run_id, status, opportunity_count FROM scout_runs "
                "WHERE created_at > now() - (%s || ' hours')::interval "
                "AND run_id LIKE ANY(%s) "
                "ORDER BY created_at",
                (str(hours), likes),
            )
            raw_lanes = list(cur.fetchall())
            if any((r[0] or "") == "__skip_lanes__" for r in raw_lanes):
                lanes = None
            else:
                by_src = {}
                for run_id, s, n in raw_lanes:
                    src = source_for_run_id(run_id)
                    if src:
                        by_src.setdefault(src, []).append((s, n))
                lanes = {src: collapse_lane(by_src.get(src) or []) for src in sources}
    finally:
        conn.close()
    return counts, runs, trends, lanes


def main():
    dsn = os.environ.get("DATABASE_URL", "")
    hours = float(os.environ.get("SCOUT_SILENCE_HOURS", "60"))
    wires = os.environ.get("SCOUT_WIRES", "crypto ai oss").split()
    sources = watch_sources()
    if not dsn:
        print("heartbeat: DATABASE_URL is required", file=sys.stderr)
        return 2
    try:
        import psycopg2  # noqa: F401
    except ImportError:
        print("heartbeat: psycopg2 is required (add to requirements.txt)", file=sys.stderr)
        return 2

    try:
        counts, runs, trends, lanes = _fetch(dsn, hours, set(wires))
    except Exception as e:
        # The heartbeat couldn't read the DB, so it can't rule silence in OR out. Fail loudly
        # (rc=2 -> Railway's crash mail) rather than staying quiet and looking healthy.
        print(f"heartbeat: DB query failed — cannot judge silence: {e}", file=sys.stderr)
        return 2

    results = [diagnose_wire(w, counts.get(w, 0), runs.get(w), trends.get(w)) for w in wires]
    summary = " ".join(f"{d.wire}={counts.get(d.wire, 0)}" for d in results)
    silent = [d for d in results if d.silent]
    source_str = ", ".join(sources)
    dead_lanes = []
    if lanes is not None:
        dead_lanes = [d for s in sources
                      if (d := diagnose_lane(s, lanes.get(s))).silent]

    alert_rc = 0
    if not silent and not dead_lanes:
        print(f"heartbeat: ok — {summary} (last {hours:g}h, sources={source_str})")
    else:
        parts = []
        if silent:
            parts.append("SILENT: " + " ".join(d.wire for d in silent))
        if dead_lanes:
            parts.append("LANE: " + " ".join(_LANE_LABEL.get(d.wire, d.wire) for d in dead_lanes))
        headline = " · ".join(parts)
        causes = ", ".join(sorted({d.cause for d in silent + dead_lanes}))

        sections = []
        if silent:
            detail = "\n\n".join(f"{d.wire}: [{d.cause}] {d.text}" for d in silent)
            sections.append(
                f"No scout rows (scan_source in {source_str}) reached the Wire Room queue "
                f"for the above wire(s). Cause per wire, read from the scout_runs ledger:\n\n{detail}"
            )
        if dead_lanes:
            detail = "\n\n".join(
                f"{_LANE_LABEL.get(d.wire, d.wire)}: [{d.cause}] {d.text}" for d in dead_lanes
            )
            sections.append(
                "A producer lane is down or rejected even though the other lane may still "
                "be feeding the Wire Room:\n\n" + detail
            )
        body = f"{summary} — {headline} (last {hours:g}h)\n\n" + "\n\n".join(sections) + "\n"

        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        alert_rc = subprocess.run(
            [sys.executable, os.path.join(root, "lib", "notify.py"),
             f"⚠️ Grant Wire Scout {headline} ({causes}) — last {hours:g}h"],
            input=body, text=True,
        ).returncode

        print(f"heartbeat: ALERT — {summary} — {headline} ({causes}) (last {hours:g}h)",
              file=sys.stderr)
        if alert_rc != 0:
            # Nobody received the alert. Exit non-zero so Railway's "Deploy Crashed" mail — noise
            # when the alert DID go out — becomes the alert of last resort.
            print("heartbeat: alert delivery FAILED — exiting non-zero so the crash mail is the backstop",
                  file=sys.stderr)

    # Daily visibility mail. Independent of the dead-man's-switch, and muted
    # unless SCOUT_REVIEW_EMAIL=1 (digest.main returns 0 without sending).
    # Import here so a digest bug cannot prevent the silence check from running,
    # and so hermetic heartbeat tests can set SCOUT_DIGEST=0 and skip this path.
    digest_rc = 0
    try:
        import digest as _digest
        digest_rc = _digest.main()
    except Exception as e:
        print(f"heartbeat: digest crashed: {e}", file=sys.stderr)
        digest_rc = 1

    if alert_rc != 0:
        return 1
    if digest_rc == 2:
        # Digest could not read the DB after the heartbeat already did — treat as
        # a delivery/ops failure, not "the switch is broken" (that is rc=2 above).
        return 1
    if digest_rc != 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
