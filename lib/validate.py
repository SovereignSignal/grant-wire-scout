#!/usr/bin/env python3
"""validate.py — enforce the opportunity schema on a run payload.

schemas/opportunity.schema.json is the contract. Until this stage existed it was
documentation only, so a bad classification / non-int fit_score / missing
deadline still POSTed to Wire Room. Invalid items move to rejected[]; the run
fails only when the top-level payload is unusable.

The submit gate is stricter than the schema: a row is kept only when someone
can apply to it now (open window, future deadline or rolling intake, and a
clear way to apply). Award or results announcements, budget or policy news,
and closed or past calls are rejected here so they never reach Wire Room.

Usage: validate.py <opportunities.json>
"""
import datetime
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

PRODUCERS = {"claude-code", "grok-build"}
VARIANTS = {"A", "B"}
WIRES = {"crypto", "ai", "oss"}
CLASSIFICATIONS = {"GRANT", "EXPIRED", "NEWS", "NOISE"}
REJECT_CLASS = {"EXPIRED", "NEWS", "NOISE", "DUPLICATE"}
# Wire areas 1-6 are recognized so a mislabeled row can be rejected by name.
# Only area 3 is submitted: an open call someone can apply to now. Areas 1, 2,
# 4, 5, and 6 (budget or policy news, awards, non-application incentives,
# commentary, tools) are dropped before they reach Wire Room.
WIRE_AREAS = {1, 2, 3, 4, 5, 6}
OPEN_PROGRAM_AREA = 3
# Exact deadline tokens that mean intake is still open. "unknown" and "none" are not.
ROLLING_DEADLINES = {"rolling", "rolling intake", "continuous", "ongoing"}
_DATE = re.compile(r"^(\d{4}-\d{2}-\d{2})")
# A way to apply has to be visible on the row, not implied by the word "grant".
_APPLY_TEXT = (
    "apply", "submit", "rfp", "request for proposal", "call for",
    "proposal", "how to apply", "intake",
)
_APPLY_PATH = {
    "apply", "application", "applications", "submit", "submission", "submissions",
    "rfp", "rfps", "proposal", "proposals", "cfp", "call", "calls",
    "intake", "register", "form",
}
_RESULTS_PATH = {"results", "recipients", "winners", "awardees"}
_RESULT_PHRASES = (
    "recipients announced", "winners announced", "results announced",
    "awards announced", "have been awarded", "has been awarded",
    "were awarded", "was awarded", "announced the recipients",
    "announced the winners", "announced the awards", "round results",
    "grant results", "selected the recipients", "were selected", "was selected",
)
_BUDGET_PHRASES = (
    "budget proposal", "budget announcement", "policy update",
    "policy announcement", "treasury vote", "governance vote",
    "passed a budget", "approved a budget", "approved the budget",
)
_CLOSED_PHRASES = (
    "applications are closed", "applications closed",
    "application window has closed", "call is closed", "call has closed",
    "no longer accepting", "deadline has passed", "submissions are closed",
    "submissions closed", "this round is closed", "round is closed",
)
DISCOVERED_VIA = {
    "web_search", "web_fetch", "source_list",
    "x_search", "x_keyword_search", "x_semantic_search",
}
REQUIRED_ITEM = (
    "name", "source_url", "wire", "amount", "deadline", "summary",
    "area", "classification", "fit_score", "fit_reason", "evidence", "discovered_via",
)


def _url_ok(u) -> bool:
    try:
        p = urlparse(str(u or "").strip())
    except Exception:
        return False
    return p.scheme in ("http", "https") and bool(p.netloc)


def coerce_area(value):
    """Return 1-6, 'out', or None. Numeric strings and 'area 3' count; bools do not."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        if value in WIRE_AREAS:
            return value
        if value == 0:
            return "out"
        return None
    if isinstance(value, float) and value == int(value):
        return coerce_area(int(value))
    if isinstance(value, str):
        s = value.strip().lower()
        if s in {"out", "outside"}:
            return "out"
        if s.isdigit():
            return coerce_area(int(s))
        if len(s) > 5 and s.startswith("area ") and s[5:].strip().isdigit():
            return coerce_area(int(s[5:].strip()))
    return None


def _utc_today():
    return datetime.datetime.now(datetime.timezone.utc).date()


def _words(item: dict) -> str:
    return " ".join(str(item.get(k) or "") for k in ("name", "summary")).lower()


def _path_segments(url) -> list[str]:
    try:
        path = urlparse(str(url or "")).path.lower()
    except Exception:
        return []
    return [s for s in path.split("/") if s]


def _deadline_status(deadline, today) -> str:
    """'rolling', 'future' (today or later), 'past', or 'missing'."""
    raw = " ".join(str(deadline or "").split()).lower()
    if raw in ROLLING_DEADLINES:
        return "rolling"
    match = _DATE.match(raw)
    if not match:
        return "missing"
    try:
        day = datetime.date.fromisoformat(match.group(1))
    except ValueError:
        return "missing"
    if day < today:
        return "past"
    return "future"


def _has_apply_path(item: dict) -> bool:
    """True when the row says how to apply, in the text or in the URL path."""
    blob = " ".join(str(item.get(k) or "") for k in ("name", "summary", "source_url")).lower()
    if any(cue in blob for cue in _APPLY_TEXT):
        return True
    return any(seg in _APPLY_PATH or seg.startswith("apply") for seg in _path_segments(item.get("source_url")))


def open_call_rejection(item: dict, today=None) -> str | None:
    """Why this row is not an open call, or None when someone can apply now.

    `today` is injectable for tests. Production uses the UTC date.
    """
    if today is None:
        today = _utc_today()
    area = item.get("area")
    if area == 2:
        return "award or results announcement (area 2) is not an open call"
    if area == 1:
        return "budget or policy news (area 1) is not an open call"
    if area != OPEN_PROGRAM_AREA:
        return f"area {area} is not an open call someone can apply to now"
    text = _words(item)
    if any(phrase in text for phrase in _RESULT_PHRASES):
        return "award or results announcement"
    if any(seg in _RESULTS_PATH for seg in _path_segments(item.get("source_url"))):
        return "award or results announcement"
    if any(phrase in text for phrase in _BUDGET_PHRASES):
        return "budget or policy news"
    if any(phrase in text for phrase in _CLOSED_PHRASES):
        return "closed or past call"
    status = _deadline_status(item.get("deadline"), today)
    if status == "past":
        return f"closed or past call: deadline {item.get('deadline')} is before {today.isoformat()}"
    if status != "future" and status != "rolling":
        return "no future deadline or rolling intake"
    if not _has_apply_path(item):
        return "no clear way to apply"
    return None


def _reject_classification(reason, original) -> str:
    text = (reason or "").lower()
    if "closed" in text or "past call" in text:
        return "EXPIRED"
    if any(word in text for word in ("award", "result", "budget", "policy")):
        return "NEWS"
    if original in REJECT_CLASS:
        return original
    return "NOISE"


def prepare_opportunity(o: dict) -> tuple[dict | None, str | None]:
    """Normalize one opportunity for the wire.

    A kept row is an open call: area 3, classification GRANT, a deadline that
    has not passed (or rolling intake), and a stated way to apply. Award or
    results announcements, budget or policy news, and closed calls are
    rejected. Returns (item, None) to keep or (None, reason) to reject.
    """
    if not isinstance(o, dict):
        return None, "not an object"
    item = dict(o)
    area = coerce_area(item.get("area"))
    if area == "out":
        return None, "area out: OUT list is rejected"
    if area is None:
        return None, f"area {item.get('area')!r} is not 1-6"
    item["area"] = area
    cls = item.get("classification")
    if area == OPEN_PROGRAM_AREA and cls in ("EXPIRED", "NOISE"):
        return None, f"open program (area 3) classified {cls}"
    if area != OPEN_PROGRAM_AREA and cls == "NOISE":
        return None, "classification NOISE"
    reason = open_call_rejection(item)
    if reason:
        return None, reason
    item["classification"] = "GRANT"
    return item, None


def item_errors(o: dict) -> list[str]:
    errs = [f"missing {k}" for k in REQUIRED_ITEM if k not in o]
    if o.get("wire") not in WIRES:
        errs.append(f"wire {o.get('wire')!r}")
    area = o.get("area")
    if isinstance(area, bool) or area not in WIRE_AREAS:
        errs.append(f"area {area!r}")
    elif area == OPEN_PROGRAM_AREA and o.get("classification") != "GRANT":
        errs.append("area 3 must be classified GRANT")
    elif area != OPEN_PROGRAM_AREA and o.get("classification") == "GRANT":
        errs.append("GRANT is only for open programs (area 3)")
    if o.get("classification") not in CLASSIFICATIONS:
        errs.append(f"classification {o.get('classification')!r}")
    if o.get("discovered_via") not in DISCOVERED_VIA:
        errs.append(f"discovered_via {o.get('discovered_via')!r}")
    score = o.get("fit_score")
    if not isinstance(score, int) or isinstance(score, bool) or not (0 <= score <= 100):
        errs.append(f"fit_score {score!r}")
    if not _url_ok(o.get("source_url")):
        errs.append(f"source_url {o.get('source_url')!r}")
    if not isinstance(o.get("evidence"), list):
        errs.append("evidence must be an array")
    for s in ("name", "amount", "deadline", "summary", "fit_reason"):
        if k := o.get(s):
            if not isinstance(k, str) or not k.strip():
                errs.append(f"{s} empty")
        elif s in o:
            errs.append(f"{s} empty")
    return errs


def validate_payload(payload: dict) -> dict:
    """Mutate payload: drop invalid opportunities into rejected[]. Return it."""
    if not isinstance(payload, dict):
        raise ValueError("payload is not an object")
    missing = [k for k in ("producer", "variant", "wire", "opportunities") if k not in payload]
    if missing:
        raise ValueError(f"payload missing required key(s): {', '.join(missing)}")
    if payload.get("producer") not in PRODUCERS:
        raise ValueError(f"producer {payload.get('producer')!r} not in {sorted(PRODUCERS)}")
    if payload.get("variant") not in VARIANTS:
        raise ValueError(f"variant {payload.get('variant')!r} not in {sorted(VARIANTS)}")
    if payload.get("wire") not in WIRES:
        raise ValueError(f"wire {payload.get('wire')!r} not in {sorted(WIRES)}")
    if not isinstance(payload.get("opportunities"), list):
        raise ValueError("opportunities must be an array")

    kept, rejected = [], list(payload.get("rejected") or [])
    dropped = 0
    for o in payload["opportunities"]:
        if not isinstance(o, dict):
            dropped += 1
            continue
        item, reason = prepare_opportunity(o)
        if item is None:
            rejected.append({
                "name": o.get("name"),
                "source_url": o.get("source_url"),
                "classification": _reject_classification(reason, o.get("classification")),
                "reason": reason,
            })
            dropped += 1
            continue
        if item.get("classification") != o.get("classification"):
            print(
                f"[validate] {item.get('name')!r}: classification {o.get('classification')!r} "
                f"-> {item['classification']!r} (area {item.get('area')})",
                file=sys.stderr,
            )
        errs = item_errors(item)
        if errs:
            rejected.append({
                "name": item.get("name"),
                "source_url": item.get("source_url"),
                "classification": "NOISE" if item.get("classification") not in REJECT_CLASS else item["classification"],
                "reason": "schema: " + "; ".join(errs),
            })
            dropped += 1
        else:
            kept.append(item)
    payload["opportunities"] = kept
    payload["rejected"] = rejected
    if dropped:
        print(f"[validate] moved {dropped} invalid opportunit{'y' if dropped == 1 else 'ies'} to rejected",
              file=sys.stderr)
    return payload


def drop_unverified(payload: dict) -> dict:
    """Move unverified / fetch_failed items to rejected. partial is kept."""
    kept, rejected = [], list(payload.get("rejected") or [])
    dropped = 0
    for o in payload.get("opportunities") or []:
        status = (o.get("verification") or {}).get("status")
        if status in ("unverified", "fetch_failed"):
            rejected.append({
                "name": o.get("name"),
                "source_url": o.get("source_url"),
                "classification": "NOISE",
                "reason": f"SCOUT_REQUIRE_VERIFIED: verification.status={status}",
            })
            dropped += 1
        else:
            kept.append(o)
    payload["opportunities"] = kept
    payload["rejected"] = rejected
    if dropped:
        print(f"[validate] REQUIRE_VERIFIED dropped {dropped} unverified/fetch_failed",
              file=sys.stderr)
    return payload


def main(opp_path: str) -> int:
    path = Path(opp_path)
    payload = json.loads(path.read_text())
    payload = validate_payload(payload)
    path.write_text(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate.py <opportunities.json>")
    sys.exit(main(sys.argv[1]))
