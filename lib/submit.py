#!/usr/bin/env python3
"""submit.py — deliver a run's opportunities straight into the Wire Room queue.

POSTs the producer payload to wire-room-ops `POST /api/scan/submit` (internal-key auth).
The Wire Room's intake JSON parser reads the `opportunities` array verbatim, dedups against
seen_urls/seen_names, runs its Gate-2 classifier, and queues survivors for operator review —
so the scout is a first-class ingestion source (scan_source='claude-code'), no shared
filesystem with the Stringer required. This is what makes the scout host-agnostic (Railway,
a box, anywhere with network + the internal key).

Exits NON-ZERO on any delivery failure so the run wrapper can alert.

Usage: submit.py <opportunities.json> <wire> <variant> <scanDate> [api_base] [internal_key]
       (api_base / internal_key fall back to $WIRE_ROOM_API / $INTERNAL_API_KEY)
"""
import json
import os
import sys
import urllib.request
import urllib.error

SOURCE = "claude-code"  # becomes scan_source; the heartbeat watches this exact value


def main(opps_path, wire, variant, scan_date, api_base=None, internal_key=None):
    api_base = (api_base or os.environ.get("WIRE_ROOM_API", "")).rstrip("/")
    internal_key = internal_key or os.environ.get("INTERNAL_API_KEY", "")
    if not api_base or not internal_key:
        print("submit: WIRE_ROOM_API and INTERNAL_API_KEY are required (arg or env)", file=sys.stderr)
        return 2

    payload_obj = json.load(open(opps_path))
    opps = payload_obj.get("opportunities", [])
    if not opps:
        print(f"submit: no opportunities in {opps_path} — nothing to deliver (not an error)")
        return 0

    # The Wire Room re-parses rawText; its JSON strategy reads `.opportunities` and
    # re-classifies server-side, so we hand it the opportunities verbatim.
    body = json.dumps({
        "wire": wire,
        "promptVariant": variant,            # 'A' | 'B'
        "scanDate": scan_date,               # YYYY-MM-DD
        "source": SOURCE,
        "rawText": json.dumps({"opportunities": opps}),
    }).encode()

    req = urllib.request.Request(
        f"{api_base}/api/scan/submit",
        data=body,
        headers={"Authorization": f"Bearer {internal_key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="ignore")[:300]
        print(f"submit: Wire Room rejected the batch (HTTP {e.code}): {detail}", file=sys.stderr)
        return 1
    except Exception as e:  # network/timeout/etc.
        print(f"submit: could not reach the Wire Room at {api_base}: {e}", file=sys.stderr)
        return 1

    n = len(opps)
    print(f"submit: delivered {n} opportunit{'y' if n == 1 else 'ies'} to the Wire Room queue "
          f"({wire}/{variant}) — {resp.get('summary', resp)}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 5:
        raise SystemExit("usage: submit.py <opportunities.json> <wire> <variant> <scanDate> [api_base] [internal_key]")
    sys.exit(main(*sys.argv[1:]))
