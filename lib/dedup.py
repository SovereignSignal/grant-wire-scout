#!/usr/bin/env python3
"""dedup.py — drop opportunities whose source_url is already known to Wire Room.

Queries GET /api/scan/seen-urls?wire=<wire> (wire-room-ops, INTERNAL_API_KEY auth)
for the normalized-URL set, then removes any producer opportunity whose normalized
URL is present. Writes the filtered set back in place.

Normalization matches Wire Room's (utils/url.ts normalizeUrl): lowercased host,
stripped scheme/www/trailing slash, dropped query/fragment.

Usage: dedup.py <opportunities.json> <wire> <api_base> <internal_api_key>
"""
import json
import re
import sys
import urllib.parse
from pathlib import Path


def normalize_url(u: str) -> str:
    try:
        p = urllib.parse.urlparse(u.strip().lower())
    except Exception:
        return ""
    if not p.netloc:
        return ""
    host = p.netloc.removeprefix("www.")
    path = p.path.rstrip("/")
    return f"{host}{path}"


def fetch_seen(api_base: str, wire: str, key: str) -> set[str]:
    import urllib.request
    url = f"{api_base.rstrip('/')}/api/scan/seen-urls?wire={urllib.parse.quote(wire)}&limit=500"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    seen = data.get("urls") or data.get("items") or []
    out = set()
    for row in seen:
        u = row.get("normalized_url") or row.get("url") or ""
        if u:
            out.add(normalize_url(u))
    return out


def main(opp_path: str, wire: str, api_base: str, key: str) -> int:
    payload = json.loads(Path(opp_path).read_text())
    opps = payload.get("opportunities", [])
    seen = fetch_seen(api_base, wire, key)
    kept, dropped = [], []
    for o in opps:
        if normalize_url(o.get("source_url", "")) in seen:
            dropped.append({"name": o.get("name"), "source_url": o.get("source_url"),
                            "classification": "DUPLICATE", "reason": "already in Wire Room seen-urls"})
        else:
            kept.append(o)
    payload["opportunities"] = kept
    payload.setdefault("rejected", []).extend(dropped)
    Path(opp_path).write_text(json.dumps(payload, indent=2))
    print(f"[dedup] kept {len(kept)}, dropped {len(dropped)} (seen set size {len(seen)})")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit("usage: dedup.py <opportunities.json> <wire> <api_base> <internal_api_key>")
    sys.exit(main(*sys.argv[1:]))
