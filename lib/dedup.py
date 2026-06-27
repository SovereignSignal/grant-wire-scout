#!/usr/bin/env python3
"""dedup.py — drop opportunities whose source_url is already known to Wire Room.

Queries GET /api/scan/seen-urls?wire=<wire> (wire-room-ops, INTERNAL_API_KEY auth)
for the normalized-URL set, then removes any producer opportunity whose normalized
URL is present. Writes the filtered set back in place.

Normalization matches Wire Room's (utils/url.ts normalizeUrl): lowercased host,
stripped scheme/www/trailing slash, dropped query/fragment.

Security (the internal key is a real credential, treat it like one):
  - INTERNAL_API_KEY is read from the ENVIRONMENT ONLY — never a CLI arg, so it can't
    leak into `ps`/argv or shell history.
  - Transport is forced to HTTPS with certificate verification (no plaintext key).
  - HTTP redirects are REFUSED, so the Authorization header is never replayed to another host.

Usage: dedup.py <opportunities.json> <wire> [api_base]
       (api_base falls back to $WIRE_ROOM_API; INTERNAL_API_KEY is env-only)
"""
import json
import os
import re
import ssl
import sys
import urllib.parse
import urllib.request
import urllib.error
from pathlib import Path
from urllib.parse import urlparse


class _RefuseRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow redirects. urllib re-sends request headers (incl. Authorization) on a
    3xx, so a redirect to another host would leak the internal key. The seen-urls endpoint
    never legitimately redirects, so we treat any 3xx as a fetch failure."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, f"refusing redirect to {newurl!r}", headers, fp)


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
    url = f"{api_base.rstrip('/')}/api/scan/seen-urls?wire={urllib.parse.quote(wire)}&limit=500"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
    # cert-verifying TLS + no redirect following (the key never leaves the intended host)
    opener = urllib.request.build_opener(
        _RefuseRedirect,
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )
    with opener.open(req, timeout=30) as r:
        data = json.load(r)
    seen = data.get("urls") or data.get("items") or []
    out = set()
    for row in seen:
        u = row.get("normalized_url") or row.get("url") or ""
        if u:
            out.add(normalize_url(u))
    return out


def main(opp_path: str, wire: str, api_base: str = None) -> int:
    api_base = (api_base or os.environ.get("WIRE_ROOM_API", "")).rstrip("/")
    key = os.environ.get("INTERNAL_API_KEY", "")  # env-only, never argv
    if not api_base or not key:
        print("dedup: WIRE_ROOM_API (arg or env) and INTERNAL_API_KEY (env) are required", file=sys.stderr)
        return 2

    parsed = urlparse(api_base)
    is_local = (parsed.hostname or "") in ("localhost", "127.0.0.1", "::1")
    if parsed.scheme != "https" and not is_local:
        print(f"dedup: refusing to send the internal key over '{parsed.scheme or 'unknown'}://' — "
              f"WIRE_ROOM_API must be https:// (got {api_base})", file=sys.stderr)
        return 2

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
    if len(sys.argv) < 3:
        raise SystemExit("usage: dedup.py <opportunities.json> <wire> [api_base]  (INTERNAL_API_KEY is env-only)")
    sys.exit(main(*sys.argv[1:]))
