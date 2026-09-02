#!/usr/bin/env python3
"""digest.py — the daily brief: what the scout found, what needs review, what it cost.

The heartbeat is exception-only (silence = healthy). That left operators with no
picture of a working day. This mail answers, in order: what landed and needs my
eyes (with the model's one-line description, the Wire Room's score and why, and
the deadline), what the Wire Room auto-archived and why (so a bad call is
visible), how deep the review queue is, how the last week's finds fared, and
one line each for runs and quota.

Runs as part of the heartbeat cron (14:00 UTC) and as `python3 lib/digest.py`.
Same Resend / webhook path as alerts, but it does NOT write scout_alerts — a
healthy digest is not an incident.

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
# What became of the scout's finds over the last 7 days, one row per status.
Outcome = namedtuple("Outcome", "status n")

_MAX_REVIEW_ITEMS = 40
_SOON_DAYS = 14
_DESC_CHARS = 240
_REASON_CHARS = 220
_AMOUNT_CHARS = 120
_LANE = {
    "claude-code": "Claude",
    "grok-scout": "Grok",
    "grok-build": "Grok",
}
_OK_STATUSES = ("ok", "skipped", "")
_FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"
_INK = "#1d1d1f"
_MUTED = "#6e6e73"
_RULE = "#d2d2d7"
_SOON = "#b45309"


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


# ---------------------------------------------------------------------- fetch

def fetch(dsn, hours, sources):
    """Return (queue_items, runs, spend, backlog, outcomes).

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
                "/* digest:outcomes */ SELECT status, count(*) FROM scan_entries "
                "WHERE scan_source = ANY(%s) "
                "AND created_at > now() - interval '7 days' "
                "GROUP BY status ORDER BY 2 DESC",
                (sources,),
            )
            outcomes = [Outcome(*row) for row in cur.fetchall()]
    finally:
        conn.close()
    return queue, runs, spend, backlog, outcomes


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


def _score_text(item):
    if item.quality is None:
        return "not scored yet"
    return f"score {_int(item.quality)}"


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


def _runs_lines(runs):
    """One line per lane: lane · model · per-wire funnel · status · cost · time."""
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


_OUTCOME_ORDER = ("approved", "declined", "archived", "duplicate", "waiting")


def _outcome_parts(outcomes):
    counts = {}
    for o in outcomes:
        s = (o.status or "").strip().lower()
        if s in ("deduped", "duplicate"):
            s = "duplicate"
        elif s == "queued":
            s = "waiting"
        counts[s] = counts.get(s, 0) + _int(o.n)
    ordered = [s for s in _OUTCOME_ORDER if s in counts]
    ordered += sorted(s for s in counts if s not in _OUTCOME_ORDER)
    return sum(counts.values()), [f"{counts[s]} {s}" for s in ordered]


def brief(queue, runs, spend, backlog, outcomes, hours, sources, now=None):
    now = now or _when_utc()
    today = now.date()
    stamp, short = _dateline(now)

    review = sorted((q for q in queue if (q.status or "").lower() == "queued"), key=_review_key)
    archived = [q for q in queue if (q.status or "").lower() == "archived"]
    handled = [q for q in queue if (q.status or "").lower() not in ("queued", "archived")]
    n_dup = sum(1 for q in handled if (q.status or "").lower() in ("duplicate", "deduped"))
    n_other = len(handled) - n_dup

    found = sum(_int(r.found_count) if r.found_count is not None else _int(r.opportunity_count)
                for r in runs)
    lanes, wires = [], []
    for r in runs:
        lane = _lane_for_run(r.run_id)
        if lane not in lanes:
            lanes.append(lane)
        if r.wire and r.wire not in wires:
            wires.append(r.wire)
    failed = sorted({(r.status or "failed").lower() for r in runs
                     if (r.status or "").lower() not in _OK_STATUSES})

    # subject
    if failed:
        subject = f"Scout · {short} · {', '.join(failed)}"
    elif review:
        subject = f"Scout · {short} · {len(review)} to review"
    else:
        subject = f"Scout · {short} · nothing to review"

    # headline
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

    # backlog
    total_wait = sum(_int(b.waiting) for b in backlog)
    if total_wait:
        parts = " · ".join(f"{b.wire or '?'} {_int(b.waiting)}" for b in backlog)
        oldest = [d for d in (_as_date(b.oldest) for b in backlog) if d]
        queue_line = f"{total_wait} waiting in the Wire Room ({parts})"
        if oldest:
            queue_line += f" · oldest {min(oldest).strftime('%-d %b')}"
    else:
        queue_line = "empty — nothing waiting in the Wire Room"

    # 7-day funnel
    n7, parts7 = _outcome_parts(outcomes)
    week_line = f"{n7} scout finds → {' · '.join(parts7)}" if n7 else "no scout finds"

    # quota
    today_models = [s for s in spend if _int(s.runs_today)]
    quota_line = (f"{_money(_sum_cost(spend, 'cost_today'))} today · "
                  f"{_money(_sum_cost(spend, 'cost_7d'))} last 7d · "
                  f"{_money(_sum_cost(spend, 'cost_mtd'))} {now.strftime('%b')} to date")
    by_model = None
    if len(today_models) > 1:
        by_model = " · ".join(f"{_model_label(s.model)} {_money(s.cost_today)}" for s in today_models)
    na_note = any(s.cost_7d is None and _int(s.runs_7d) for s in spend) or \
        any(s.cost_today is None and _int(s.runs_today) for s in spend)

    def card(item):
        due, soon = _due(item, today)
        meta = [item.wire or "?", _score_text(item)]
        if item.amount:
            meta.append(_clip(item.amount, _AMOUNT_CHARS))
        if due:
            meta.append(due)
        return {
            "id": item.id,
            "name": " ".join(str(item.name or "(untitled)").split()),
            "desc": _clip(item.description, _DESC_CHARS),
            "meta": meta,
            "soon": soon,
            "why": _clip(item.score_reason, _REASON_CHARS) if item.quality is not None else "",
            "url": item.source_url,
        }

    def archived_card(item):
        reason = item.classification_reason or item.score_reason or item.description
        return {
            "id": item.id,
            "name": " ".join(str(item.name or "(untitled)").split()),
            "meta": [item.wire or "?", _score_text(item)],
            "why": _clip(reason, _REASON_CHARS),
            "url": item.source_url,
        }

    def handled_card(item):
        return {
            "id": item.id,
            "name": " ".join(str(item.name or "(untitled)").split()),
            "meta": [item.wire or "?", (item.status or "?").lower()],
            "url": item.source_url,
        }

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
        "week_line": week_line,
        "runs_lines": _runs_lines(runs),
        "quota_line": quota_line,
        "by_model": by_model,
        "na_note": na_note,
        "ran": bool(runs),
    }


def subject_line(queue, runs, spend, backlog=(), outcomes=(), now=None):
    return brief(queue, runs, spend, list(backlog), list(outcomes), 26, [], now=now)["subject"]


# ------------------------------------------------------------------- renderers

def render_text(b):
    L = [f"SCOUT · {b['stamp'].upper()} · {b['clock']} UTC", b["headline"], ""]

    L.append(f"TO REVIEW ({b['review_total']})")
    if not b["review"]:
        L.append("  Nothing." if b["ran"] else "  No scout run in the window.")
    for c in b["review"]:
        L.append(f"  {c['name']}")
        if c["desc"]:
            L.append(f"  {c['desc']}")
        L.append("  " + " · ".join(c["meta"]))
        if c["why"]:
            L.append(f"  Score: {c['why']}")
        if c["url"]:
            L.append(f"  {c['url']}")
        L.append("")
    if b["review_more"]:
        L.append(f"  …and {b['review_more']} more")
        L.append("")
    if b["review"] and L[-1] != "":
        L.append("")

    if b["archived"]:
        L.append(f"AUTO-ARCHIVED ({len(b['archived'])})")
        for c in b["archived"]:
            L.append(f"  {c['name']}")
            L.append("  " + " · ".join(c["meta"]) + (f" · {c['why']}" if c["why"] else ""))
        L.append("")

    if b["handled"]:
        L.append(f"ALREADY HANDLED ({len(b['handled'])})")
        for c in b["handled"]:
            L.append(f"  {c['name']} · " + " · ".join(c["meta"]))
        L.append("")

    L.append(f"QUEUE  {b['queue_line']}")
    L.append(f"LAST 7 DAYS  {b['week_line']}")
    L.append("")

    if b["runs_lines"]:
        for i, line in enumerate(b["runs_lines"]):
            L.append(("Runs: " if i == 0 else "      ") + line)
    else:
        L.append("Runs: none in the window.")
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
    """Email-safe HTML twin of render_text. Stacked blocks only, no columns."""
    def esc(s):
        return html.escape("" if s is None else str(s))

    def p(text, size=15, color=_INK, margin="0", weight="normal", extra=""):
        return (f'<p style="margin:{margin};font:{weight} {size}px/1.45 {_FONT};'
                f'color:{color};{extra}">{text}</p>')

    def h(text):
        return p(esc(text), size=12, color=_MUTED, margin="26px 0 6px",
                 weight="600", extra="letter-spacing:.08em;text-transform:uppercase")

    def title(c):
        name = esc(c["name"])
        href = _ui_href(c["id"])
        t = f'<a href="{esc(href)}" style="color:{_INK};text-decoration:none">{name}</a>' if href else name
        if c.get("url"):
            t += (f' &nbsp;<a href="{esc(c["url"])}" style="color:{_MUTED};font-size:12px;'
                  f'font-weight:normal">source ↗</a>')
        return t

    def meta_html(c):
        bits = [esc(m) for m in c["meta"]]
        if c.get("soon"):
            bits = [f'<span style="color:{_SOON};font-weight:600">{m}</span>' if "soon" in m else m
                    for m in bits]
        return " · ".join(bits)

    def block(inner):
        return f'<div style="padding:12px 0;border-top:1px solid {_RULE}">{inner}</div>'

    out = [f'<div style="max-width:600px;margin:0 auto;padding:4px 0 16px;font-family:{_FONT}">']
    out.append(p(f"Scout · {esc(b['stamp'])} · {esc(b['clock'])} UTC", size=12, color=_MUTED,
                 weight="600", extra="letter-spacing:.08em;text-transform:uppercase"))
    out.append(p(esc(b["headline"]), size=17, margin="6px 0 0", weight="600"))

    out.append(h(f"To review ({b['review_total']})"))
    if not b["review"]:
        out.append(p("Nothing." if b["ran"] else "No scout run in the window.", color=_MUTED))
    for c in b["review"]:
        inner = p(title(c), weight="600")
        if c["desc"]:
            inner += p(esc(c["desc"]), margin="3px 0 4px")
        inner += p(meta_html(c), size=13, color=_MUTED)
        if c["why"]:
            inner += p(f'<span style="font-weight:600">Score:</span> {esc(c["why"])}',
                       size=13, color=_MUTED, margin="3px 0 0")
        out.append(block(inner))
    if b["review_more"]:
        out.append(p(f"…and {b['review_more']} more", size=13, color=_MUTED, margin="8px 0 0"))

    if b["archived"]:
        out.append(h(f"Auto-archived ({len(b['archived'])})"))
        for c in b["archived"]:
            inner = p(title(c), weight="600")
            why = esc(c["why"])
            inner += p(meta_html(c) + (f" · {why}" if why else ""), size=13, color=_MUTED, margin="2px 0 0")
            out.append(block(inner))

    if b["handled"]:
        out.append(h(f"Already handled ({len(b['handled'])})"))
        for c in b["handled"]:
            out.append(block(p(title(c) + f' <span style="color:{_MUTED};font-size:13px">· '
                               + meta_html(c) + "</span>")))

    out.append(h("Queue"))
    out.append(p(esc(b["queue_line"])))
    out.append(h("Last 7 days"))
    out.append(p(esc(b["week_line"])))

    out.append(f'<div style="margin-top:26px;padding-top:12px;border-top:1px solid {_RULE}">')
    if b["runs_lines"]:
        for i, line in enumerate(b["runs_lines"]):
            out.append(p(("<b>Runs:</b> " if i == 0 else "") + esc(line), size=13, color=_MUTED))
    else:
        out.append(p("<b>Runs:</b> none in the window.", size=13, color=_MUTED))
    out.append(p("<b>Quota-equiv</b> (not a bill): " + esc(b["quota_line"]), size=13, color=_MUTED,
                 margin="4px 0 0"))
    if b["by_model"]:
        out.append(p("By model today: " + esc(b["by_model"]), size=13, color=_MUTED, margin="4px 0 0"))
    if b["na_note"]:
        out.append(p("n/a = that CLI did not report a $ equivalent (typical for SuperGrok).",
                     size=12, color=_MUTED, margin="4px 0 0"))
    out.append(p("Exception alerts still fire separately if a lane dies or a wire goes silent.",
                 size=12, color=_MUTED, margin="14px 0 0"))
    out.append("</div></div>")
    return "".join(out)


def build(queue, runs, spend, backlog, outcomes, hours, sources, now=None):
    b = brief(queue, runs, spend, backlog, outcomes, hours, sources, now=now)
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
        queue, runs, spend, backlog, outcomes = fetch(dsn, hours, sources)
    except Exception as e:
        print(f"digest: DB query failed: {e}", file=sys.stderr)
        return 2

    subject, text, html_body = build(queue, runs, spend, backlog, outcomes, hours, sources)
    rc = notify.send(subject, text, html=html_body, record=False)
    if rc == 0:
        print(f"digest: sent — {subject}")
    else:
        print(f"digest: send failed — {subject}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
