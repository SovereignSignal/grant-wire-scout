#!/usr/bin/env python3
"""submit.py — deliver a run's opportunities straight into the Wire Room queue.

POSTs the producer payload to wire-room-ops `POST /api/scan/submit` (internal-key auth).
The Wire Room's intake JSON parser reads the `opportunities` array verbatim, dedups against
seen_urls/seen_names, runs its Gate-2 classifier, and queues survivors for operator review —
so the scout is a first-class ingestion source (scan_source from SCOUT_SCAN_SOURCE,
default 'claude-code'; the Grok Build lane uses 'grok-scout'), no shared
filesystem with the Stringer required. This is what makes the scout host-agnostic.

Security (the internal key is a real credential, treat it like one):
  - INTERNAL_API_KEY is read from the ENVIRONMENT ONLY — never a CLI arg, so it can't
    leak into `ps`/argv or shell history.
  - Transport is forced to HTTPS with certificate verification (no plaintext key).
  - HTTP redirects are REFUSED, so the Authorization header is never replayed to another host.

Exits NON-ZERO on any delivery failure so the run wrapper can alert.

Usage: submit.py <opportunities.json> <wire> <variant> <scanDate> [api_base]
       (api_base falls back to $WIRE_ROOM_API; INTERNAL_API_KEY is env-only)
"""
import json
import os
import ssl
import sys
import time
import urllib.request
import urllib.error
from urllib.parse import urlparse

import validate

DEFAULT_SOURCE = "claude-code"  # heartbeat watches this unless SCOUT_SCAN_SOURCE is set

# Retry only transient delivery failures (rate-limit / gateway / network). Permanent 4xx
# (400/401/403/404) are NOT retried — fail fast so the alert is actionable.
TRANSIENT_HTTP = {429, 500, 502, 503, 504}
MAX_ATTEMPTS = 3


class _RefuseRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow redirects. urllib re-sends request headers (incl. Authorization) on a
    3xx, so a redirect to another host would leak the internal key. The submit endpoint
    never legitimately redirects, so we treat any 3xx as a delivery failure."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, f"refusing redirect to {newurl!r}", headers, fp)


def opportunities_for_submit(opps):
    """Items the Wire Room should receive.

    Each kept object has integer `area` 1-6. Open programs (area 3) are GRANT;
    every other area is NEWS so grants.watch does not treat it as an open program.
    """
    if not isinstance(opps, list):
        return []
    kept = []
    for o in opps:
        if not isinstance(o, dict):
            continue
        item, reason = validate.prepare_opportunity(o)
        if item is None:
            print(f"submit: dropping {o.get('name')!r}: {reason}", file=sys.stderr)
            continue
        errs = validate.item_errors(item)
        if errs:
            print(f"submit: dropping {o.get('name')!r}: {'; '.join(errs)}", file=sys.stderr)
            continue
        kept.append(item)
    return kept


def build_submission_body(opps, wire, variant, scan_date, source):
    """JSON body for POST /api/scan/submit. rawText is the opportunities array."""
    delivered = opportunities_for_submit(opps)
    return {
        "wire": wire,
        "promptVariant": variant,            # 'A' | 'B'
        "scanDate": scan_date,               # YYYY-MM-DD
        "source": source,
        "rawText": json.dumps({"opportunities": delivered}),
    }, delivered


def main(opps_path, wire, variant, scan_date, api_base=None):
    api_base = (api_base or os.environ.get("WIRE_ROOM_API", "")).rstrip("/")
    internal_key = os.environ.get("INTERNAL_API_KEY", "")  # env-only, never argv
    if not api_base or not internal_key:
        print("submit: WIRE_ROOM_API (arg or env) and INTERNAL_API_KEY (env) are required", file=sys.stderr)
        return 2

    parsed = urlparse(api_base)
    is_local = (parsed.hostname or "") in ("localhost", "127.0.0.1", "::1")
    if parsed.scheme != "https" and not is_local:
        print(f"submit: refusing to send the internal key over '{parsed.scheme or 'unknown'}://' — "
              f"WIRE_ROOM_API must be https:// (got {api_base})", file=sys.stderr)
        return 2

    payload_obj = json.load(open(opps_path))
    opps = payload_obj.get("opportunities", [])
    if not opps:
        print(f"submit: no opportunities in {opps_path} — nothing to deliver (not an error)")
        return 0

    source = os.environ.get("SCOUT_SCAN_SOURCE", DEFAULT_SOURCE)
    body_obj, opps = build_submission_body(opps, wire, variant, scan_date, source)
    if not opps:
        print(f"submit: no area 1-6 opportunities in {opps_path} — nothing to deliver (not an error)")
        return 0
    body = json.dumps(body_obj).encode()

    req = urllib.request.Request(
        f"{api_base}/api/scan/submit",
        data=body,
        headers={
            "Authorization": f"Bearer {internal_key}",
            "Content-Type": "application/json",
            "User-Agent": "grant-wire-scout/1.0",  # avoid edge/WAF 403s on the default urllib UA
        },
        method="POST",
    )
    # cert-verifying TLS + no redirect following (the key never leaves the intended host)
    opener = urllib.request.build_opener(
        _RefuseRedirect,
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )

    backoff = 2  # seconds; doubles each retry -> 2s, then 4s
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with opener.open(req, timeout=60) as r:
                status = r.status
                raw_body = r.read()
            # A 2xx is a delivery. If the body is not JSON (edge/proxy page, empty
            # body) the batch still landed — reporting "could not reach" here made the
            # wrapper page DELIVERY and the ledger record a failure for rows that were
            # in the queue, which the heartbeat then read as lost-in-delivery.
            try:
                resp = json.loads(raw_body)
            except ValueError:
                resp = {"summary": f"HTTP {status}, non-JSON body ({len(raw_body)} bytes)"}
            break
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="ignore")[:300]
            if e.code in TRANSIENT_HTTP and attempt < MAX_ATTEMPTS:
                print(f"submit: transient HTTP {e.code} from Wire Room "
                      f"(attempt {attempt}/{MAX_ATTEMPTS}), retrying in {backoff}s: {detail}", file=sys.stderr)
                time.sleep(backoff)
                backoff *= 2
                continue
            print(f"submit: Wire Room rejected the batch (HTTP {e.code}): {detail}", file=sys.stderr)
            return 1
        except urllib.error.URLError as e:  # network/timeout/TLS/etc. (non-HTTP) — transient
            if attempt < MAX_ATTEMPTS:
                print(f"submit: could not reach the Wire Room "
                      f"(attempt {attempt}/{MAX_ATTEMPTS}), retrying in {backoff}s: {e}", file=sys.stderr)
                time.sleep(backoff)
                backoff *= 2
                continue
            print(f"submit: could not reach the Wire Room at {api_base}: {e}", file=sys.stderr)
            return 1
        except Exception as e:
            print(f"submit: could not reach the Wire Room at {api_base}: {e}", file=sys.stderr)
            return 1

    n = len(opps)
    print(f"submit: delivered {n} opportunit{'y' if n == 1 else 'ies'} to the Wire Room queue "
          f"({wire}/{variant}) — {resp.get('summary', resp)}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 5:
        raise SystemExit("usage: submit.py <opportunities.json> <wire> <variant> <scanDate> [api_base]")
    sys.exit(main(*sys.argv[1:]))
