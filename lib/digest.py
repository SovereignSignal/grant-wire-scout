#!/usr/bin/env python3
"""digest.py — daily visibility email for what the scout found, queued, and spent.

The heartbeat is exception-only (silence = healthy). That left operators with no
picture of a working day: which grants landed, which models ran, how much Max /
SuperGrok quota the week and month have used. This fills that gap.

Runs as part of the heartbeat cron (14:00 UTC) and as `python3 lib/digest.py`.
Same Resend / webhook path as alerts, but it does NOT write scout_alerts — a
healthy digest is not an incident.

Env (same as heartbeat, plus):
  DATABASE_URL, RESEND_API_KEY, NOTIFICATION_EMAIL, ALERT_FROM
  SCOUT_WIRES, SCOUT_SCAN_SOURCES / SCOUT_SCAN_SOURCE
  SCOUT_DIGEST          default on; 0/false/off disables
  SCOUT_DIGEST_HOURS    lookback for "today" (default 26 — covers yesterday's
                        14:00 send through this morning's Claude/Grok tick)
  WIRE_ROOM_UI          optional; if set, each queued name links to
                        {WIRE_ROOM_UI}/queue?entry={id}

EXIT:
  0  sent, or digest disabled
  1  send failed
  2  could not read the DB
"""
from __future__ import annotations

import html
import os
import sys
from collections import namedtuple
from datetime import datetime, timezone

# Imported for source/prefix helpers only. heartbeat imports digest inside main()
# so this is not circular at module load.
import heartbeat as hb
import notify

QueueItem = namedtuple(
    "QueueItem",
    "id name wire amount deadline status quality scan_source source_url created_at",
)
RunRow = namedtuple(
    "RunRow",
    "run_id wire variant model status opportunity_count found_count "
    "dedup_dropped cost_usd duration_ms created_at",
)
ModelSpend = namedtuple(
    "ModelSpend",
    "model runs_today cost_today runs_7d cost_7d runs_30d cost_30d runs_mtd cost_mtd",
)

_MAX_QUEUE_ITEMS = 40
_LANE = {
    "claude-code": "Claude",
    "grok-scout": "Grok",
    "grok-build": "Grok Build",
}


def enabled():
    raw = (os.environ.get("SCOUT_DIGEST") or "1").strip().lower()
    return raw not in ("0", "false", "off", "no")


def digest_hours():
    try:
        return float(os.environ.get("SCOUT_DIGEST_HOURS", "26"))
    except ValueError:
        return 26.0


def _money(n):
    if n is None:
        return "n/a"
    try:
        return f"${float(n):,.2f}"
    except (TypeError, ValueError):
        return "n/a"


def _int(n):
    if n is None:
        return 0
    try:
        return int(n)
    except (TypeError, ValueError):
        return 0


def _lane(source):
    return _LANE.get(source, source or "?")


def _model_label(model):
    return (model or "").strip() or "(unrecorded)"


def _when_utc():
    return datetime.now(timezone.utc)


def _dateline(now=None):
    now = now or _when_utc()
    return now.strftime("%a %-d %b %Y").upper(), now.strftime("%-d %b")


def fetch(dsn, hours, sources):
    """Return (queue_items, runs, spend).

    Each query is tagged /* digest:<name> */ so the hermetic stub can dispatch
    without guessing from table names (scout_runs is read twice).
    """
    import psycopg2

    likes = [hb.run_id_prefix(s) + "%" for s in sources]
    conn = psycopg2.connect(dsn)
    try:
        with conn.cursor() as cur:
            cur.execute(
                "/* digest:funnel */ SELECT 1 FROM information_schema.columns "
                "WHERE table_schema = 'public' AND table_name = 'scout_runs' "
                "AND column_name = 'found_count'",
            )
            has_funnel = bool(cur.fetchall())
        with conn.cursor() as cur:
            cur.execute(
                "/* digest:queue */ SELECT id, name, wire, amount, deadline, status, "
                "quality_score, scan_source, source_url, created_at "
                "FROM scan_entries "
                "WHERE scan_source = ANY(%s) "
                "AND created_at > now() - (%s || ' hours')::interval "
                "ORDER BY wire, created_at DESC",
                (sources, str(hours)),
            )
            queue = [QueueItem(*row) for row in cur.fetchall()]
        with conn.cursor() as cur:
            if has_funnel:
                cur.execute(
                    "/* digest:runs */ SELECT run_id, wire, variant, model, status, "
                    "opportunity_count, found_count, dedup_dropped, cost_usd, "
                    "duration_ms, created_at FROM scout_runs "
                    "WHERE created_at > now() - (%s || ' hours')::interval "
                    "AND run_id LIKE ANY(%s) "
                    "ORDER BY created_at",
                    (str(hours), likes),
                )
                runs = [RunRow(*row) for row in cur.fetchall()]
            else:
                cur.execute(
                    "/* digest:runs */ SELECT run_id, wire, variant, model, status, "
                    "opportunity_count, cost_usd, duration_ms, created_at "
                    "FROM scout_runs "
                    "WHERE created_at > now() - (%s || ' hours')::interval "
                    "AND run_id LIKE ANY(%s) "
                    "ORDER BY created_at",
                    (str(hours), likes),
                )
                runs = [
                    RunRow(rid, wire, var, model, status, opps, None, None,
                           cost, dur, created)
                    for rid, wire, var, model, status, opps, cost, dur, created
                    in cur.fetchall()
                ]
        with conn.cursor() as cur:
            cur.execute(
                "/* digest:spend */ SELECT "
                "coalesce(nullif(trim(model), ''), '(unrecorded)') AS model, "
                "count(*) FILTER (WHERE created_at > now() - (%s || ' hours')::interval), "
                "sum(cost_usd) FILTER (WHERE created_at > now() - (%s || ' hours')::interval), "
                "count(*) FILTER (WHERE created_at > now() - interval '7 days'), "
                "sum(cost_usd) FILTER (WHERE created_at > now() - interval '7 days'), "
                "count(*) FILTER (WHERE created_at > now() - interval '30 days'), "
                "sum(cost_usd) FILTER (WHERE created_at > now() - interval '30 days'), "
                "count(*) FILTER (WHERE created_at >= date_trunc('month', timezone('UTC', now()))), "
                "sum(cost_usd) FILTER (WHERE created_at >= date_trunc('month', timezone('UTC', now()))) "
                "FROM scout_runs "
                "WHERE created_at > now() - interval '31 days' "
                "AND run_id LIKE ANY(%s) "
                "GROUP BY 1 "
                "ORDER BY 7 DESC NULLS LAST, 6 DESC",
                (str(hours), str(hours), likes),
            )
            spend = [ModelSpend(*row) for row in cur.fetchall()]
    finally:
        conn.close()
    return queue, runs, spend


def _sum_cost(rows, attr):
    vals = [getattr(r, attr) for r in rows if getattr(r, attr) is not None]
    if not vals:
        # Distinguish "no $ reported" from "$0.00".
        if any(getattr(r, attr.replace("cost_", "runs_")) for r in rows):
            return None
        return 0.0
    return float(sum(vals))


def _sum_runs(rows, attr):
    return sum(_int(getattr(r, attr)) for r in rows)


def _runs_label(n):
    n = _int(n)
    return f"{n} run" if n == 1 else f"{n} runs"


def subject_line(queue, runs, spend, now=None):
    _, short = _dateline(now)
    n = len(queue)
    today = _sum_cost(spend, "cost_today")
    queued = f"{n} queued" if n else "nothing queued"
    if today is None:
        money = "quota n/a"
    else:
        money = f"{_money(today)} today"
    failed = [r for r in runs if (r.status or "").lower() not in ("ok", "skipped", "")]
    if failed:
        kinds = sorted({(r.status or "failed").lower() for r in failed})
        return f"Scout · {short} — {queued} · {', '.join(kinds)}"
    return f"Scout · {short} — {queued} · {money}"


def _duration(ms):
    if not ms:
        return ""
    try:
        sec = int(ms) / 1000
    except (TypeError, ValueError):
        return ""
    if sec < 90:
        return f"{sec:.0f}s"
    return f"{sec / 60:.0f}m"


def _run_funnel(run):
    kept = _int(run.opportunity_count)
    found = run.found_count
    dropped = run.dedup_dropped
    if found is not None:
        bit = f"found {found} → submitted {kept}"
        if dropped:
            bit += f" ({dropped} already known)"
        elif found and not kept:
            bit += " (all already known)"
        return bit
    return f"submitted {kept}"


def _item_line(item):
    bits = [item.wire or "?", _lane(item.scan_source)]
    if item.amount:
        bits.append(str(item.amount))
    if item.deadline:
        bits.append(f"due {item.deadline}")
    if item.status:
        bits.append(item.status)
    if item.quality is not None:
        bits.append(f"q{item.quality}")
    return " · ".join(str(b) for b in bits if b)


def render_text(queue, runs, spend, hours, sources, now=None):
    now = now or _when_utc()
    stamp, _ = _dateline(now)
    found = sum(_int(r.found_count) if r.found_count is not None else _int(r.opportunity_count)
                for r in runs)
    submitted = sum(_int(r.opportunity_count) for r in runs)
    queued = len(queue)
    today_cost = _sum_cost(spend, "cost_today")
    week_cost = _sum_cost(spend, "cost_7d")
    month_cost = _sum_cost(spend, "cost_30d")
    mtd_cost = _sum_cost(spend, "cost_mtd")
    month_name = now.strftime("%b")

    lines = [
        f"GRANT WIRE SCOUT  ·  {stamp}  ·  {now.strftime('%H:%M')} UTC",
        "",
        f"Last {hours:g}h  ·  sources: {', '.join(sources)}",
        f"Found {found}  ·  submitted {submitted}  ·  landed in queue {queued}"
        f"  ·  {_money(today_cost)} quota-equiv today",
        "",
    ]

    lines.append(f"ADDED TO THE QUEUE ({queued})")
    if not queue:
        if runs:
            lines.append("  Nothing new landed. The scout ran; every find was already")
            lines.append("  in the catalog, or the batch was empty after the currency gate.")
        else:
            lines.append("  No scout rows in this window — no producer tick landed.")
    else:
        shown = queue[:_MAX_QUEUE_ITEMS]
        by_wire = {}
        for item in shown:
            by_wire.setdefault(item.wire or "?", []).append(item)
        for wire, items in by_wire.items():
            lines.append(f"  {wire} ({len(items)})")
            for item in items:
                lines.append(f"    • {item.name or '(untitled)'}")
                lines.append(f"      {_item_line(item)}")
                if item.source_url:
                    lines.append(f"      {item.source_url}")
        extra = queued - len(shown)
        if extra > 0:
            lines.append(f"  …and {extra} more")
    lines.append("")

    lines.append(f"RUNS ({len(runs)})")
    if not runs:
        lines.append("  No scout_runs row in the window.")
    else:
        for r in runs:
            lane = _lane(hb.source_for_run_id(r.run_id) or r.run_id)
            dur = _duration(r.duration_ms)
            dur_bit = f"  {dur}" if dur else ""
            cost = _money(r.cost_usd) if r.cost_usd is not None else "n/a"
            lines.append(
                f"  {lane}  {r.wire or '?'} / {r.variant or '?'}  "
                f"{_model_label(r.model)}  {r.status or '?'}  "
                f"{_run_funnel(r)}  {cost}{dur_bit}"
            )
    lines.append("")

    today_models = [s for s in spend if _int(s.runs_today)]
    lines.append("MODELS USED (this window)")
    if not today_models:
        lines.append("  None recorded.")
    else:
        for s in today_models:
            lines.append(
                f"  {_model_label(s.model)}  ·  { _int(s.runs_today) } run"
                f"{'' if _int(s.runs_today) == 1 else 's'}  ·  {_money(s.cost_today)}"
            )
    lines.append("")

    lines.append("CONSUMPTION  (quota-equivalent — Max / SuperGrok, not a bill)")
    lines.append(f"  Today     {_money(today_cost)}   ({_runs_label(_sum_runs(spend, 'runs_today'))})")
    lines.append(f"  Week      {_money(week_cost)}   (last 7 days, {_runs_label(_sum_runs(spend, 'runs_7d'))})")
    lines.append(f"  Month     {_money(month_cost)}   (last 30 days, {_runs_label(_sum_runs(spend, 'runs_30d'))})")
    lines.append(f"  {month_name} MTD   {_money(mtd_cost)}   ({_runs_label(_sum_runs(spend, 'runs_mtd'))})")
    if spend:
        lines.append("  By model (week / month / MTD)")
        for s in spend:
            lines.append(
                f"    {_model_label(s.model):<22}  "
                f"{_money(s.cost_7d)} / {_money(s.cost_30d)} / {_money(s.cost_mtd)}   "
                f"({_int(s.runs_7d)} / {_int(s.runs_30d)} / {_int(s.runs_mtd)} runs)"
            )
        if any(s.cost_7d is None and _int(s.runs_7d) for s in spend):
            lines.append("  n/a = that CLI did not report a $ equivalent (typical for SuperGrok).")
    lines.append("")
    lines.append("Exception alerts still fire separately if a lane dies or a wire goes silent.")
    lines.append("")
    return "\n".join(lines)


def _ui_href(item_id):
    base = (os.environ.get("WIRE_ROOM_UI") or "").rstrip("/")
    if not base or item_id is None:
        return None
    return f"{base}/queue?entry={item_id}"


def render_html(queue, runs, spend, hours, sources, now=None):
    """Email-safe HTML twin of render_text. Tables, no external CSS."""
    now = now or _when_utc()
    stamp, _ = _dateline(now)
    found = sum(_int(r.found_count) if r.found_count is not None else _int(r.opportunity_count)
                for r in runs)
    submitted = sum(_int(r.opportunity_count) for r in runs)
    queued = len(queue)
    today_cost = _sum_cost(spend, "cost_today")
    week_cost = _sum_cost(spend, "cost_7d")
    month_cost = _sum_cost(spend, "cost_30d")
    mtd_cost = _sum_cost(spend, "cost_mtd")
    month_name = now.strftime("%b")

    def esc(s):
        return html.escape("" if s is None else str(s))

    def cell(s, extra=""):
        return f'<td style="padding:4px 10px 4px 0;vertical-align:top;{extra}">{s}</td>'

    rows = []
    rows.append(
        f'<p style="font:14px/1.4 -apple-system,Helvetica,Arial,sans-serif;margin:0 0 12px">'
        f'<b>GRANT WIRE SCOUT</b> &nbsp; {esc(stamp)} &nbsp; {esc(now.strftime("%H:%M"))} UTC<br>'
        f'<span style="color:#555">Last {hours:g}h · {esc(", ".join(sources))} · '
        f'found {found} · submitted {submitted} · queued {queued} · '
        f'{esc(_money(today_cost))} today</span></p>'
    )

    rows.append('<h3 style="font:14px/1.3 -apple-system,Helvetica,Arial,sans-serif;margin:16px 0 8px">'
                f'Added to the queue ({queued})</h3>')
    if not queue:
        if runs:
            rows.append('<p style="font:13px/1.4 -apple-system,Helvetica,Arial,sans-serif;color:#555">'
                        'Nothing new landed. The scout ran; finds were already in the catalog '
                        'or the batch was empty after the currency gate.</p>')
        else:
            rows.append('<p style="font:13px/1.4 -apple-system,Helvetica,Arial,sans-serif;color:#555">'
                        'No scout rows in this window.</p>')
    else:
        # One stacked cell per item, never a name/meta column pair: `amount` is free text
        # from the model and can run long ("not specified (five separate RFAs: ...)"), and a
        # non-wrapping meta column let one such row push the table past the mail viewport
        # and squeeze every title to one word per line (1 Sep 2026 digest).
        rows.append('<table style="font:13px/1.4 -apple-system,Helvetica,Arial,sans-serif;'
                    'border-collapse:collapse;width:100%">')
        for item in queue[:_MAX_QUEUE_ITEMS]:
            href = _ui_href(item.id)
            name = esc(item.name or "(untitled)")
            title = f'<a href="{esc(href)}">{name}</a>' if href else name
            if item.source_url:
                title += (f' &nbsp; <a href="{esc(item.source_url)}" '
                          f'style="color:#666;font-size:12px">source</a>')
            meta = esc(_item_line(item))
            rows.append('<tr><td style="padding:6px 0;vertical-align:top;border-bottom:1px solid #eee">'
                        f'{title}<br><span style="color:#555;font-size:12px">{meta}</span></td></tr>')
        rows.append('</table>')
        extra = queued - min(queued, _MAX_QUEUE_ITEMS)
        if extra > 0:
            rows.append(f'<p style="font:12px;color:#666">…and {extra} more</p>')

    rows.append('<h3 style="font:14px/1.3 -apple-system,Helvetica,Arial,sans-serif;margin:16px 0 8px">'
                f'Runs ({len(runs)})</h3>')
    if runs:
        rows.append('<table style="font:13px/1.4 -apple-system,Helvetica,Arial,sans-serif;border-collapse:collapse">')
        for r in runs:
            lane = esc(_lane(hb.source_for_run_id(r.run_id) or r.run_id))
            cost = esc(_money(r.cost_usd) if r.cost_usd is not None else "n/a")
            rows.append(
                "<tr>"
                + cell(f"{lane} {esc(r.wire)}/{esc(r.variant)}")
                + cell(esc(_model_label(r.model)))
                + cell(esc(r.status))
                + cell(esc(_run_funnel(r)))
                + cell(cost)
                + cell(esc(_duration(r.duration_ms)))
                + "</tr>"
            )
        rows.append('</table>')
    else:
        rows.append('<p style="font:13px;color:#555">No scout_runs row in the window.</p>')

    today_models = [s for s in spend if _int(s.runs_today)]
    rows.append('<h3 style="font:14px/1.3 -apple-system,Helvetica,Arial,sans-serif;margin:16px 0 8px">'
                'Models used</h3>')
    if today_models:
        rows.append('<table style="font:13px/1.4 -apple-system,Helvetica,Arial,sans-serif;border-collapse:collapse">')
        for s in today_models:
            rows.append(
                "<tr>"
                + cell(esc(_model_label(s.model)))
                + cell(f"{_int(s.runs_today)} run{'s' if _int(s.runs_today) != 1 else ''}")
                + cell(esc(_money(s.cost_today)))
                + "</tr>"
            )
        rows.append('</table>')
    else:
        rows.append('<p style="font:13px;color:#555">None recorded.</p>')

    rows.append('<h3 style="font:14px/1.3 -apple-system,Helvetica,Arial,sans-serif;margin:16px 0 8px">'
                'Consumption <span style="font-weight:normal;color:#666">'
                '(quota-equivalent — not a bill)</span></h3>')
    rows.append('<table style="font:13px/1.4 -apple-system,Helvetica,Arial,sans-serif;border-collapse:collapse">')
    rows.append(f'<tr>{cell("Today")}{cell(esc(_money(today_cost)))}'
                f'{cell(esc(_runs_label(_sum_runs(spend, "runs_today"))))}</tr>')
    rows.append(f'<tr>{cell("Week (7d)")}{cell(esc(_money(week_cost)))}'
                f'{cell(esc(_runs_label(_sum_runs(spend, "runs_7d"))))}</tr>')
    rows.append(f'<tr>{cell("Month (30d)")}{cell(esc(_money(month_cost)))}'
                f'{cell(esc(_runs_label(_sum_runs(spend, "runs_30d"))))}</tr>')
    rows.append(f'<tr>{cell(esc(month_name) + " MTD")}{cell(esc(_money(mtd_cost)))}'
                f'{cell(esc(_runs_label(_sum_runs(spend, "runs_mtd"))))}</tr>')
    rows.append('</table>')
    if spend:
        rows.append('<p style="font:12px;color:#555;margin:10px 0 4px">By model — week / month / MTD</p>')
        rows.append('<table style="font:13px/1.4 -apple-system,Helvetica,Arial,sans-serif;border-collapse:collapse">')
        for s in spend:
            rows.append(
                "<tr>"
                + cell(esc(_model_label(s.model)))
                + cell(esc(f"{_money(s.cost_7d)} / {_money(s.cost_30d)} / {_money(s.cost_mtd)}"))
                + cell(esc(f"{_int(s.runs_7d)} / {_int(s.runs_30d)} / {_int(s.runs_mtd)} runs"))
                + "</tr>"
            )
        rows.append('</table>')

    rows.append('<p style="font:12px;color:#888;margin-top:16px">'
                'Exception alerts still fire separately if a lane dies or a wire goes silent.</p>')
    return "".join(rows)


def build(queue, runs, spend, hours, sources, now=None):
    return (
        subject_line(queue, runs, spend, now=now),
        render_text(queue, runs, spend, hours, sources, now=now),
        render_html(queue, runs, spend, hours, sources, now=now),
    )


def main():
    if not enabled():
        print("digest: disabled (SCOUT_DIGEST=0)")
        return 0
    dsn = os.environ.get("DATABASE_URL", "")
    if not dsn:
        print("digest: DATABASE_URL is required", file=sys.stderr)
        return 2
    try:
        import psycopg2  # noqa: F401
    except ImportError:
        print("digest: psycopg2 is required", file=sys.stderr)
        return 2

    hours = digest_hours()
    sources = hb.watch_sources()
    try:
        queue, runs, spend = fetch(dsn, hours, sources)
    except Exception as e:
        print(f"digest: DB query failed: {e}", file=sys.stderr)
        return 2

    subject, text, html_body = build(queue, runs, spend, hours, sources)
    rc = notify.send(subject, text, html=html_body, record=False)
    if rc == 0:
        print(f"digest: sent — {subject}")
    else:
        print(f"digest: send failed — {subject}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
