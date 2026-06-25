#!/usr/bin/env python3
"""classify_failure.py — read a run's raw.json and classify a failure for alerting.

Prints exactly one token: AUTH | QUOTA | EMPTY | OTHER. Best-effort and conservative —
defaults to OTHER. Used by run-scout.sh to pick the right alert subject so an expired
OAuth token reads as 'AUTH', not a generic failure.

Usage: classify_failure.py <raw.json>
"""
import json
import sys


def classify(raw_path):
    try:
        d = json.load(open(raw_path))
    except Exception:
        return "OTHER"
    if not isinstance(d, dict):
        return "OTHER"

    blob = " ".join(str(d.get(k) or "") for k in ("api_error_status", "result", "subtype", "error")).lower()
    if any(s in blob for s in ("401", "403", "unauthor", "forbidden", "oauth", "token", "authentication", "credential", "setup-token", "login")):
        return "AUTH"
    if any(s in blob for s in ("429", "rate limit", "rate_limit", "usage limit", "quota", "overloaded", "capacity", "exceeded")):
        return "QUOTA"
    if d.get("is_error"):
        return "OTHER"
    # exited non-zero but no error envelope and nothing usable produced → empty/parse failure
    if not (d.get("result") or d.get("opportunities")):
        return "EMPTY"
    return "OTHER"


if __name__ == "__main__":
    print(classify(sys.argv[1] if len(sys.argv) > 1 else ""))
