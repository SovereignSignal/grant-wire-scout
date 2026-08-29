#!/usr/bin/env python3
"""validate.py — enforce the opportunity schema on a run payload.

schemas/opportunity.schema.json is the contract. Until this stage existed it was
documentation only, so a bad classification / non-int fit_score / missing
deadline still POSTed to Wire Room. Invalid items move to rejected[]; the run
fails only when the top-level payload is unusable.

Usage: validate.py <opportunities.json>
"""
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

PRODUCERS = {"claude-code", "grok-build"}
VARIANTS = {"A", "B"}
WIRES = {"crypto", "ai", "oss"}
CLASSIFICATIONS = {"GRANT", "EXPIRED", "NEWS", "NOISE"}
REJECT_CLASS = {"EXPIRED", "NEWS", "NOISE", "DUPLICATE"}
DISCOVERED_VIA = {
    "web_search", "web_fetch", "source_list",
    "x_search", "x_keyword_search", "x_semantic_search",
}
REQUIRED_ITEM = (
    "name", "source_url", "wire", "amount", "deadline", "summary",
    "classification", "fit_score", "fit_reason", "evidence", "discovered_via",
)


def _url_ok(u) -> bool:
    try:
        p = urlparse(str(u or "").strip())
    except Exception:
        return False
    return p.scheme in ("http", "https") and bool(p.netloc)


def item_errors(o: dict) -> list[str]:
    errs = [f"missing {k}" for k in REQUIRED_ITEM if k not in o]
    if o.get("wire") not in WIRES:
        errs.append(f"wire {o.get('wire')!r}")
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
        errs = item_errors(o)
        if errs:
            rejected.append({
                "name": o.get("name"),
                "source_url": o.get("source_url"),
                "classification": "NOISE" if o.get("classification") not in REJECT_CLASS else o["classification"],
                "reason": "schema: " + "; ".join(errs),
            })
            dropped += 1
        else:
            kept.append(o)
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
