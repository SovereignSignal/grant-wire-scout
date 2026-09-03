#!/usr/bin/env python3
"""digest.py — the daily scout brief, readable in two minutes.

The heartbeat is exception-only (silence = healthy). This mail is the picture of
a working day, in the order an operator needs it:

  1. one sentence: who scanned what, how many wait for review, how many were
     auto-archived or matched;
  2. two lines per find: name + wire · score · amount · deadline, then the
     Wire Room's score reason (or the description while a find is unscored);
  3. auto-archived finds with the reason, one line each, so a bad call is visible;
  4. the whole Wire Room backlog by wire;
  5. a Claude-vs-Grok scorecard over the last 7 days — runs, found, verdicts,
     approve rate, quota — so both lanes show every day even though they
     alternate weekdays;
  6. one line for today's runs and one for quota (today / month to date).

The Wire Room's own WireOps digest already carries summaries and deep links for
every queued entry; this mail does not repeat them. Same Resend / webhook path
as alerts, but it does NOT write scout_alerts — a healthy digest is not an incident.

Env (same as heartbeat, plus):
  DATABASE_URL, RESEND_API_KEY, NOTIFICATION_EMAIL, ALERT_FROM
  SCOUT_WIRES, SCOUT_SCAN_SOURCES / SCOUT_SCAN_SOURCE
  SCOUT_DIGEST          default on; 0/false/off disables
  SCOUT_DIGEST_HOURS    lookback for "today" (default 26 — covers yesterday's
                        14:00 send through this morning's Claude/Grok tick)
  WIRE_ROOM_UI          optional; if set, each title links to
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
from datetime import date, datetime, timezone

# Imported for source/prefix helpers only. heartbeat imports digest inside main()
# so this is not circular at module load.
import heartbeat as hb
import notify

QueueItem = namedtuple(
    "QueueItem",
    "id name wire amount deadline deadline_parsed status quality score_reason "
    "classification classification_reason description scan_source source_url created_at",
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
# Whole Wire Room queue (every source), one row per wire.
Backlog = namedtuple("Backlog", "wire waiting oldest")
# What became of each lane's finds over the last 7 days, one row per (lane, status).
Outcome = namedtuple("Outcome", "scan_source status n")
# Every scout run in the last 7 days, for the per-lane scorecard.
LaneRun = namedtuple("LaneRun", "run_id status opportunity_count found_count cost_usd")

_MAX_REVIEW_ITEMS = 15
_SOON_DAYS = 14
_LINE_CHARS = 160
_AMOUNT_CHARS = 80
_LANE = {
    "claude-code": "Claude",
    "grok-scout": "Grok",
    "grok-build": "Grok",
}
_OK_STATUSES = ("ok", "skipped", "")
_FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"
_INK = "#1d1d1f"
_BODY = "#515154"
_MUTED = "#6e6e73"
_RULE = "#e5e5ea"
_HAIR = "#ececf0"
_SOON = "#b45309"
_PAGE = "#f5f5f7"


def enabled():
    raw = (os.environ.get("SCOUT_DIGEST") or "1").strip().lower()
    return raw not in ("0", "false", "off", "no")


def digest_hours():
    try:
        return float(os.environ.get("SCOUT_DIGEST_HOURS", "26"))
    except ValueError:
        return 26.0


# ---------------------------------------------------------------- small helpers

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


def _lane_for_run(run_id):
    src = hb.source_for_run_id(run_id)
    if src in _LANE:
        return _LANE[src]
    rid = str(run_id or "")
    if rid.startswith("grok"):
        return "Grok"
    if rid.startswith("claude"):
        return "Claude"
    return src or rid or "?"


def _lane_for_source(source):
    return _LANE.get(source, source or "?")


def _model_label(model):
    return (model or "").strip() or "(unrecorded)"


def _when_utc():
    return datetime.now(timezone.utc)


def _dateline(now=None):
    now = now or _when_utc()
    return now.strftime("%a %-d %b %Y"), now.strftime("%-d %b")


def _as_date(v):
    if v is None or v == "":
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    try:
        return date.fromisoformat(str(v)[:10])
    except ValueError:
        return None


def _clip(s, n):
    s = " ".join(str(s or "").split())
    if len(s) <= n:
        return s
    cut = s[:n].rsplit(" ", 1)[0]
    return cut.rstrip(" ,;:(-") + "…"


def _plural(n, one, many=None):
    n = _int(n)
    return f"{n} {one if n == 1 else (many or one + 's')}"


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


def _ui_href(item_id):
    base = (os.environ.get("WIRE_ROOM_UI") or "").rstrip("/")
    if not base or item_id is None:
        return None
    return f"{base}/queue?entry={item_id}"


def _found(run):
    return _int(run.found_count) if run.found_count is not None else _int(run.opportunity_count)


# ---------------------------------------------------------------------- fetch

def fetch(dsn, hours, sources):
    """Return (queue_items, runs, spend, backlog, outcomes, lane_runs).

    Each query is tagged /* digest:<name> */ so the hermetic stub can dispatch
    without guessing from table names (scan_entries and scout_runs are each read
    more than once).
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
                "/* digest:queue */ SELECT id, name, wire, amount, deadline, deadline_parsed, "
                "status, quality_score, quality_breakdown->>'scoreReason', classification, "
                "classification_reason, description, scan_source, source_url, created_at "
                "FROM scan_entries "
                "WHERE scan_source = ANY(%s) "
                "AND created_at > now() - (%s || ' hours')::interval "
                "ORDER BY created_at DESC",
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
        with conn.cursor() as cur:
            # The whole queue, every source: this is what the operator sees in the
            # Wire Room, so it is the honest measure of "am I keeping up".
            cur.execute(
                "/* digest:backlog */ SELECT wire, count(*), min(created_at) "
                "FROM scan_entries WHERE status = 'queued' "
                "GROUP BY wire ORDER BY 2 DESC",
            )
            backlog = [Backlog(*row) for row in cur.fetchall()]
        with conn.cursor() as cur:
            cur.execute(
                "/* digest:outcomes */ SELECT scan_source, status, count(*) FROM scan_entries "
                "WHERE scan_source = ANY(%s) "
                "AND created_at > now() - interval '7 days' "
                "GROUP BY 1, 2 ORDER BY 1, 3 DESC",
                (sources,),
            )
            outcomes = [Outcome(*row) for row in cur.fetchall()]
        with conn.cursor() as cur:
            if has_funnel:
                cur.execute(
                    "/* digest:lane_runs */ SELECT run_id, status, opportunity_count, "
                    "found_count, cost_usd FROM scout_runs "
                    "WHERE created_at > now() - interval '7 days' "
                    "AND run_id LIKE ANY(%s)",
                    (likes,),
                )
                lane_runs = [LaneRun(*row) for row in cur.fetchall()]
            else:
                cur.execute(
                    "/* digest:lane_runs */ SELECT run_id, status, opportunity_count, "
                    "cost_usd FROM scout_runs "
                    "WHERE created_at > now() - interval '7 days' "
                    "AND run_id LIKE ANY(%s)",
                    (likes,),
                )
                lane_runs = [LaneRun(rid, status, opps, None, cost)
                             for rid, status, opps, cost in cur.fetchall()]
    finally:
        conn.close()
    return queue, runs, spend, backlog, outcomes, lane_runs


# ---------------------------------------------------------------------- brief
# One pass over the raw rows produces every string both renderers need, so the
# text and HTML twins cannot drift.

def _sum_cost(rows, attr):
    vals = [getattr(r, attr) for r in rows if getattr(r, attr) is not None]
    if not vals:
        # Distinguish "no $ reported" from "$0.00".
        if any(getattr(r, attr.replace("cost_", "runs_")) for r in rows):
            return None
        return 0.0
    return float(sum(vals))


def _due(item, today):
    """(text, soon) for the deadline, or (None, False)."""
    parsed = _as_date(item.deadline_parsed)
    if parsed:
        days = (parsed - today).days
        label = parsed.strftime("%-d %b")
        if days < 0:
            return f"due {label} (passed)", False
        if days == 0:
            return f"due {label} (today, soon)", True
        if days <= _SOON_DAYS:
            return f"due {label} ({_plural(days, 'day')}, soon)", True
        return f"due {label} ({_plural(days, 'day')})", False
    raw = " ".join(str(item.deadline or "").split())
    if not raw:
        return None, False
    if raw.lower() in ("rolling", "continuous", "ongoing", "open", "none"):
        return "rolling", False
    return f"due {raw}", False


def _review_key(item):
    unscored = item.quality is None
    parsed = _as_date(item.deadline_parsed)
    return (
        1 if unscored else 0,
        -_int(item.quality) if not unscored else 0,
        parsed or date.max,
    )


def _funnel_bit(run):
    kept = _int(run.opportunity_count)
    wire = run.wire or "?"
    found = run.found_count
    if found is None or _int(found) == kept:
        return f"{wire} {kept}"
    found = _int(found)
    dropped = _int(run.dedup_dropped)
    if kept == 0 and found:
        return f"{wire} 0 of {found} (all known)"
    if dropped:
        return f"{wire} {kept} of {found} ({dropped} known)"
    return f"{wire} {kept} of {found}"


def _today_lines(runs):
    """One line per lane that ran: lane · model · per-wire funnel · status · cost · time."""
    lanes = {}
    for r in runs:
        lanes.setdefault(_lane_for_run(r.run_id), []).append(r)
    out = []
    for lane, rows in lanes.items():
        models = []
        for r in rows:
            m = _model_label(r.model)
            if m not in models:
                models.append(m)
        failed = [r for r in rows if (r.status or "").lower() not in _OK_STATUSES]
        if failed:
            status = ", ".join(f"{r.wire or '?'} {(r.status or 'failed').lower()}" for r in failed)
        else:
            status = "all ok"
        costs = [r.cost_usd for r in rows if r.cost_usd is not None]
        cost = _money(sum(float(c) for c in costs)) if costs else "n/a"
        bits = [lane, "/".join(models), ", ".join(_funnel_bit(r) for r in rows), status, cost]
        dur = _duration(sum(_int(r.duration_ms) for r in rows))
        if dur:
            bits.append(dur)
        out.append(" · ".join(bits))
    return out


def _scorecard(sources, outcomes, lane_runs):
    """Per-lane 7-day rows, in watched-source order, then any lane seen only in data."""
    labels = []
    for s in sources:
        lab = _lane_for_source(s)
        if lab not in labels:
            labels.append(lab)
    data = {}

    def row(lab):
        if lab not in labels:
            labels.append(lab)
        return data.setdefault(lab, {"runs": 0, "ok": 0, "found": 0, "cost": [],
                                     "approved": 0, "declined": 0, "archived": 0,
                                     "duplicate": 0, "waiting": 0, "other": 0})

    for r in lane_runs:
        d = row(_lane_for_run(r.run_id))
        d["runs"] += 1
        if (r.status or "").lower() in _OK_STATUSES:
            d["ok"] += 1
        d["found"] += _found(r)
        if r.cost_usd is not None:
            d["cost"].append(float(r.cost_usd))
    for o in outcomes:
        d = row(_lane_for_source(o.scan_source))
        s = (o.status or "").strip().lower()
        if s in ("duplicate", "deduped"):
            d["duplicate"] += _int(o.n)
        elif s == "queued":
            d["waiting"] += _int(o.n)
        elif s in ("approved", "declined", "archived"):
            d[s] += _int(o.n)
        else:
            d["other"] += _int(o.n)

    rows = []
    for lab in labels:
        d = data.get(lab) or row(lab)
        decided = d["approved"] + d["declined"] + d["archived"] + d["duplicate"]
        rate = f"{round(100 * d['approved'] / decided)}%" if decided else "–"
        if d["cost"]:
            quota = _money(sum(d["cost"]))
        elif d["runs"]:
            quota = "n/a"
        else:
            quota = "–"
        failed = d["runs"] - d["ok"]
        rows.append({
            "lane": lab,
            "runs": str(d["runs"]),
            "found": str(d["found"]),
            "approved": str(d["approved"]),
            "declined": str(d["declined"]),
            "archived": str(d["archived"]),
            "waiting": str(d["waiting"]),
            "rate": rate,
            "quota": quota,
            "note": (f"{failed} failed" if failed else ("no runs" if not d["runs"] else "")),
        })
    return rows


_SCORE_COLS = (("lane", "lane"), ("runs", "runs"), ("found", "found"), ("approved", "approved"),
               ("declined", "declined"), ("archived", "archived"), ("waiting", "waiting"),
               ("rate", "approve"), ("quota", "quota"))


def brief(queue, runs, spend, backlog, outcomes, lane_runs, hours, sources, now=None):
    now = now or _when_utc()
    today = now.date()
    stamp, short = _dateline(now)

    review = sorted((q for q in queue if (q.status or "").lower() == "queued"), key=_review_key)
    archived = [q for q in queue if (q.status or "").lower() == "archived"]
    handled = [q for q in queue if (q.status or "").lower() not in ("queued", "archived")]
    n_dup = sum(1 for q in handled if (q.status or "").lower() in ("duplicate", "deduped"))
    n_other = len(handled) - n_dup

    found = sum(_found(r) for r in runs)
    lanes, wires = [], []
    for r in runs:
        lane = _lane_for_run(r.run_id)
        if lane not in lanes:
            lanes.append(lane)
        if r.wire and r.wire not in wires:
            wires.append(r.wire)
    failed = sorted({(r.status or "failed").lower() for r in runs
                     if (r.status or "").lower() not in _OK_STATUSES})

    if failed:
        subject = f"Scout · {short} · {', '.join(failed)}"
    elif review:
        subject = f"Scout · {short} · {len(review)} to review"
    else:
        subject = f"Scout · {short} · nothing to review"

    if runs:
        who = " and ".join(lanes) if lanes else "The scout"
        head = f"{who} scanned {', '.join(wires) if wires else 'the wires'} and found {found}."
        if review:
            head += f" {len(review)} waiting for your review."
        elif queue:
            head += " Nothing new is waiting for your review."
        else:
            head += (" Nothing new landed: every find was already in the catalog, "
                     "or the batch was empty after the currency gate.")
        if archived:
            head += f" {len(archived)} auto-archived."
        if n_dup:
            head += f" {_plural(n_dup, 'duplicate')}."
        if n_other:
            head += f" {n_other} already handled."
        if failed:
            head += f" Failures: {', '.join(failed)}."
    else:
        head = f"No scout run landed in the last {hours:g}h."

    total_wait = sum(_int(b.waiting) for b in backlog)
    if total_wait:
        parts = " · ".join(f"{b.wire or '?'} {_int(b.waiting)}" for b in backlog)
        oldest = [d for d in (_as_date(b.oldest) for b in backlog) if d]
        queue_line = f"{total_wait} waiting in the Wire Room ({parts})"
        if oldest:
            queue_line += f" · oldest {min(oldest).strftime('%-d %b')}"
    else:
        queue_line = "empty — nothing waiting in the Wire Room"

    today_models = [s for s in spend if _int(s.runs_today)]
    quota_line = (f"{_money(_sum_cost(spend, 'cost_today'))} today · "
                  f"{_money(_sum_cost(spend, 'cost_mtd'))} {now.strftime('%b')} to date")
    by_model = None
    if len(today_models) > 1:
        by_model = " · ".join(f"{_model_label(s.model)} {_money(s.cost_today)}" for s in today_models)
    scorecard = _scorecard(sources, outcomes, lane_runs)
    na_note = (any(s.cost_7d is None and _int(s.runs_7d) for s in spend)
               or any(s.cost_today is None and _int(s.runs_today) for s in spend)
               or any(r["quota"] == "n/a" for r in scorecard))

    def name_of(item):
        return " ".join(str(item.name or "(untitled)").split())

    def card(item):
        due, soon = _due(item, today)
        meta = [item.wire or "?", "unscored" if item.quality is None else str(_int(item.quality))]
        if item.amount:
            meta.append(_clip(item.amount, _AMOUNT_CHARS))
        if due:
            meta.append(due)
        # Scored: the Wire Room's reason is the useful line. Unscored: the model's
        # description is all there is. Never both — WireOps already sends summaries.
        line2 = item.score_reason if item.quality is not None else item.description
        return {"id": item.id, "name": name_of(item), "meta": meta, "soon": soon,
                "why": _clip(line2, _LINE_CHARS), "url": item.source_url}

    def archived_card(item):
        reason = item.classification_reason or item.score_reason or item.description
        return {"id": item.id, "name": name_of(item),
                "meta": [item.wire or "?", "unscored" if item.quality is None else str(_int(item.quality))],
                "why": _clip(reason, _LINE_CHARS), "url": item.source_url}

    def handled_card(item):
        return {"id": item.id, "name": name_of(item),
                "meta": [item.wire or "?", (item.status or "?").lower()], "why": "",
                "url": item.source_url}

    return {
        "stamp": stamp,
        "clock": now.strftime("%H:%M"),
        "subject": subject,
        "headline": head,
        "review": [card(q) for q in review[:_MAX_REVIEW_ITEMS]],
        "review_total": len(review),
        "review_more": max(0, len(review) - _MAX_REVIEW_ITEMS),
        "archived": [archived_card(q) for q in archived],
        "handled": [handled_card(q) for q in handled],
        "queue_line": queue_line,
        "scorecard": scorecard,
        "today_lines": _today_lines(runs),
        "quota_line": quota_line,
        "by_model": by_model,
        "na_note": na_note,
        "ran": bool(runs),
    }


# ------------------------------------------------------------------- renderers

def _text_table(rows):
    cols = [(key, head) for key, head in _SCORE_COLS]
    widths = {k: max(len(h), *(len(r[k]) for r in rows)) for k, h in cols} if rows else \
        {k: len(h) for k, h in cols}
    def fmt(vals):
        out = []
        for i, (k, _) in enumerate(cols):
            v = vals[k]
            out.append(v.ljust(widths[k]) if i == 0 else v.rjust(widths[k]))
        return "  ".join(out).rstrip()
    lines = [fmt({k: ("" if k == "lane" else h) for k, h in cols})]
    for r in rows:
        line = fmt(r)
        if r["note"]:
            line += f"  ({r['note']})"
        lines.append(line)
    return lines


def render_text(b):
    L = [f"SCOUT · {b['stamp'].upper()} · {b['clock']} UTC", b["headline"], ""]

    L.append(f"TO REVIEW ({b['review_total']})")
    if not b["review"]:
        L.append("  Nothing." if b["ran"] else "  No scout run in the window.")
    for c in b["review"]:
        first = f"  {c['name']} · " + " · ".join(c["meta"])
        if c["url"]:
            first += f" · {c['url']}"
        L.append(first)
        L.append(f"  {c['why']}" if c["why"] else "  (no description)")
    if b["review_more"]:
        L.append(f"  …and {b['review_more']} more in the queue")
    L.append("")

    if b["archived"]:
        L.append(f"AUTO-ARCHIVED ({len(b['archived'])})")
        for c in b["archived"]:
            L.append(f"  {c['name']} · " + " · ".join(c["meta"]) + (f" · {c['why']}" if c["why"] else ""))
        L.append("")

    if b["handled"]:
        L.append(f"ALREADY HANDLED ({len(b['handled'])})")
        for c in b["handled"]:
            L.append(f"  {c['name']} · " + " · ".join(c["meta"]))
        L.append("")

    L.append(f"QUEUE  {b['queue_line']}")
    L.append("")
    L.append("LANES · LAST 7 DAYS")
    L.extend("  " + line for line in _text_table(b["scorecard"]))
    L.append("  approve = approved ÷ decided (approved + declined + archived + duplicate)")
    L.append("")

    if b["today_lines"]:
        for i, line in enumerate(b["today_lines"]):
            L.append(("Today: " if i == 0 else "       ") + line)
    else:
        L.append("Today: no scout run in the window.")
    L.append(f"Quota-equiv (not a bill): {b['quota_line']}")
    if b["by_model"]:
        L.append(f"By model today: {b['by_model']}")
    if b["na_note"]:
        L.append("n/a = that CLI did not report a $ equivalent (typical for SuperGrok).")
    L.append("")
    L.append("Exception alerts still fire separately if a lane dies or a wire goes silent.")
    L.append("")
    return "\n".join(L)


def render_html(b):
    """Email-safe HTML twin of render_text.

    Stacked blocks only, no tables: a long free-text amount crushed a two-column
    layout on 1 Sep 2026, and a nine-column scorecard overflowed a phone.
    """
    def esc(s):
        return html.escape("" if s is None else str(s))

    def p(inner, size=15, color=_INK, margin="0", weight="400", lh="1.45", extra=""):
        return (f'<p style="margin:{margin};font:{weight} {size}px/{lh} {_FONT};'
                f'color:{color};{extra}">{inner}</p>')

    def label(text):
        return (f'<p style="margin:26px 0 4px;padding-bottom:6px;border-bottom:1px solid {_RULE};'
                f'font:600 11px/1.3 {_FONT};color:{_MUTED};letter-spacing:.1em;'
                f'text-transform:uppercase">{esc(text)}</p>')

    def title(c):
        name = esc(c["name"])
        href = _ui_href(c["id"])
        return (f'<a href="{esc(href)}" style="color:{_INK};text-decoration:none">{name}</a>'
                if href else name)

    def meta_html(c, strong_score=True):
        bits = []
        for i, m in enumerate(c["meta"]):
            t = esc(m)
            if i == 1 and strong_score and m != "unscored":
                t = f'<span style="color:{_INK};font-weight:600">{t}</span>'
            elif c.get("soon") and "soon" in m:
                t = f'<span style="color:{_SOON};font-weight:600">{t}</span>'
            bits.append(t)
        if c.get("url"):
            bits.append(f'<a href="{esc(c["url"])}" style="color:{_MUTED}">source</a>')
        return " · ".join(bits)

    def find_block(c, name_size=15):
        inner = (f'<div style="font:600 {name_size}px/1.4 {_FONT};color:{_INK}">{title(c)} '
                 f'<span style="font:400 13px/1.4 {_FONT};color:{_MUTED}">· {meta_html(c)}</span></div>')
        if c.get("why"):
            inner += f'<div style="margin-top:2px;font:400 13px/1.45 {_FONT};color:{_BODY}">{esc(c["why"])}</div>'
        return f'<div style="padding:9px 0;border-bottom:1px solid {_HAIR}">{inner}</div>'

    def one_liner(c):
        inner = (f'<span style="font:600 14px/1.45 {_FONT};color:{_INK}">{title(c)}</span> '
                 f'<span style="font:400 13px/1.45 {_FONT};color:{_MUTED}">· {meta_html(c, strong_score=False)}'
                 + (f' · {esc(c["why"])}' if c.get("why") else "") + "</span>")
        return f'<div style="padding:7px 0;border-bottom:1px solid {_HAIR}">{inner}</div>'

    out = [f'<div style="background:{_PAGE};padding:20px 10px;font-family:{_FONT}">',
           f'<div style="max-width:620px;margin:0 auto;background:#ffffff;border:1px solid {_RULE};'
           f'border-radius:12px;padding:22px 24px 18px">']
    out.append(p(f"Scout · {esc(b['stamp'])} · {esc(b['clock'])} UTC", size=11, color=_MUTED,
                 weight="600", extra="letter-spacing:.1em;text-transform:uppercase"))
    out.append(p(esc(b["headline"]), size=18, margin="8px 0 0", weight="600", lh="1.35"))

    out.append(label(f"To review ({b['review_total']})"))
    if not b["review"]:
        out.append(p("Nothing." if b["ran"] else "No scout run in the window.", color=_MUTED,
                     margin="8px 0 0"))
    for c in b["review"]:
        out.append(find_block(c))
    if b["review_more"]:
        out.append(p(f"…and {b['review_more']} more in the queue", size=13, color=_MUTED, margin="8px 0 0"))

    if b["archived"]:
        out.append(label(f"Auto-archived ({len(b['archived'])})"))
        for c in b["archived"]:
            out.append(one_liner(c))

    if b["handled"]:
        out.append(label(f"Already handled ({len(b['handled'])})"))
        for c in b["handled"]:
            out.append(one_liner(c))

    out.append(label("Queue"))
    out.append(p(esc(b["queue_line"]), margin="8px 0 0"))

    out.append(label("Lanes · last 7 days"))
    # Stacked rows, not a grid: nine numeric columns overflow a phone and push the
    # whole card past the viewport. Two lanes read fine as two short lines each.
    for r in b["scorecard"]:
        lane = esc(r["lane"])
        if r["note"]:
            lane += f' <span style="font-weight:400;color:{_MUTED}">({esc(r["note"])})</span>'
        head = (f'<span style="font:600 15px/1.4 {_FONT};color:{_INK}">{lane}</span> '
                f'<span style="font:400 13px/1.4 {_FONT};color:{_MUTED}">· '
                f'<span style="color:{_INK};font-weight:600">{esc(r["rate"])}</span> approve · '
                f'<span style="color:{_INK};font-weight:600">{esc(r["quota"])}</span> quota · '
                f'{esc(r["runs"])} runs · {esc(r["found"])} found</span>')
        verdicts = (f'{esc(r["approved"])} approved · {esc(r["declined"])} declined · '
                    f'{esc(r["archived"])} archived · {esc(r["waiting"])} waiting')
        out.append(f'<div style="padding:8px 0;border-bottom:1px solid {_HAIR}">{head}'
                   f'<div style="margin-top:1px;font:400 13px/1.45 {_FONT};color:{_BODY}">{verdicts}</div></div>')
    out.append(p("approve = approved ÷ decided (approved + declined + archived + duplicate)",
                 size=12, color=_MUTED, margin="6px 0 0"))

    out.append(f'<div style="margin-top:24px;padding-top:12px;border-top:1px solid {_RULE}">')
    if b["today_lines"]:
        for i, line in enumerate(b["today_lines"]):
            out.append(p(("<b>Today:</b> " if i == 0 else "") + esc(line), size=13, color=_MUTED))
    else:
        out.append(p("<b>Today:</b> no scout run in the window.", size=13, color=_MUTED))
    out.append(p("<b>Quota-equiv</b> (not a bill): " + esc(b["quota_line"]), size=13, color=_MUTED,
                 margin="4px 0 0"))
    if b["by_model"]:
        out.append(p("By model today: " + esc(b["by_model"]), size=13, color=_MUTED, margin="4px 0 0"))
    if b["na_note"]:
        out.append(p("n/a = that CLI did not report a $ equivalent (typical for SuperGrok).",
                     size=12, color=_MUTED, margin="4px 0 0"))
    out.append(p("Exception alerts still fire separately if a lane dies or a wire goes silent.",
                 size=12, color=_MUTED, margin="14px 0 0"))
    out.append("</div></div></div>")
    return "".join(out)


def build(queue, runs, spend, backlog, outcomes, lane_runs, hours, sources, now=None):
    b = brief(queue, runs, spend, backlog, outcomes, lane_runs, hours, sources, now=now)
    return b["subject"], render_text(b), render_html(b)


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
        queue, runs, spend, backlog, outcomes, lane_runs = fetch(dsn, hours, sources)
    except Exception as e:
        print(f"digest: DB query failed: {e}", file=sys.stderr)
        return 2

    subject, text, html_body = build(queue, runs, spend, backlog, outcomes, lane_runs, hours, sources)
    rc = notify.send(subject, text, html=html_body, record=False)
    if rc == 0:
        print(f"digest: sent — {subject}")
    else:
        print(f"digest: send failed — {subject}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
