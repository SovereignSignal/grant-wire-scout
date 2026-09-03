#!/usr/bin/env python3
"""url_gate.py — reject finds whose source_url the Wire Room would silently archive.

The Wire Room's intake runs `isUsefulUrl` (wire-room-ops src/services/intake.ts) as Gate 1,
BEFORE dedup: an entry whose source_url has no meaningful path is set to
status='archived', metadata.archived_reason='no_source_url', unscored and unread. Because
it is archived before dedup, its URL never reaches seen_urls, so the producer re-finds the
same program on the next run, forever.

That cost the Claude lane 39 finds in the 30 days to 2026-09-03 and the Grok lane 11 —
Prototype Fund, FLOSS/fund, Stellar SCF, Scroll, dYdX, XRPL Commons, Snorkel three times.
Every one of the 37 finds the operator approved in that window had a deep URL.

Running the same rule here turns a silent downstream archive into a visible rejection in
the run's own report, with the URL kept for triage.

This mirrors isUsefulUrl deliberately. wire-room-ops is the source of truth; if that rule
changes, change this one to match — a gate that is stricter than intake would drop finds
the Wire Room would have accepted.

Usage: url_gate.py <opportunities.json>
EXIT: 0 filtered (even if nothing was dropped); 2 could not read/write the payload.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import urlparse

# Path segments that carry no program identity, so a URL made only of them is a front door.
_GENERIC_SEGMENTS = {"en", "es", "fr", "de", "ja", "ko", "zh", "about", "blog", "home", "index"}
# Values models emit when they have no real URL.
_PLACEHOLDERS = {"", "todo", "tbd", "n/a", "na", "none", "null", "unknown",
                 "example.com", "placeholder", "...", "#"}


def is_useful_url(url) -> bool:
    """True when the Wire Room's Gate 1 would accept this URL."""
    raw = str(url or "").strip()
    if raw.lower() in _PLACEHOLDERS:
        return False
    try:
        u = urlparse(raw)
    except ValueError:
        return False
    if u.scheme not in ("http", "https") or not u.netloc:
        return False

    host = u.netloc.lower().split("@")[-1].split(":")[0]
    if host.startswith("www."):
        host = host[4:]
    if not host or host == "www" or "." not in host:
        return False

    if host in ("x.com", "twitter.com"):
        parts = [s for s in u.path.split("/") if s]
        # /status/<id> or /i/status/<id> — real tweet ids are 18-20 digits.
        if "status" in parts:
            i = parts.index("status")
            tid = parts[i + 1] if len(parts) > i + 1 else ""
            return tid.isdigit() and len(tid) >= 18
        # /i/<something-not-status> is a truncation, not a page.
        if parts[:1] == ["i"]:
            return False
        return True
    if host == "t.co":
        return True  # short links redirect to the real page

    segments = [s for s in u.path.split("/") if s and s.lower() not in _GENERIC_SEGMENTS]
    if not segments:
        return False
    # A lone segment that is itself a placeholder is not a program page.
    return not (len(segments) == 1 and segments[0].lower() in _PLACEHOLDERS)


def main(path: str) -> int:
    p = Path(path)
    try:
        payload = json.loads(p.read_text())
    except Exception as e:
        print(f"url_gate: cannot read {path}: {e}", file=sys.stderr)
        return 2

    opps = payload.get("opportunities") or []
    kept, dropped = [], []
    for o in opps:
        url = o.get("source_url", "")
        if is_useful_url(url):
            kept.append(o)
        else:
            dropped.append({
                "name": o.get("name"),
                "source_url": url,
                "classification": "NOISE",
                "reason": ("source_url is not a canonical program page (needs a real path, "
                           "not a bare domain root or a locale/about/blog-only path) — the "
                           "Wire Room archives these unread"),
            })

    payload["opportunities"] = kept
    payload.setdefault("rejected", []).extend(dropped)
    payload["url_gate"] = {"checked": len(opps), "kept": len(kept), "dropped": len(dropped)}

    try:
        p.write_text(json.dumps(payload, indent=2))
    except Exception as e:
        print(f"url_gate: cannot write {path}: {e}", file=sys.stderr)
        return 2

    print(f"[url-gate] kept {len(kept)}, dropped {len(dropped)} (no canonical program URL)")
    for d in dropped:
        print(f"[url-gate]   drop: {d['name']} <{d['source_url']}>")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: url_gate.py <opportunities.json>")
    sys.exit(main(sys.argv[1]))
