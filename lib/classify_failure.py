#!/usr/bin/env python3
"""classify_failure.py — read a run's raw.json and classify a failure for alerting.

Prints exactly one token: AUTH | QUOTA | EMPTY | TIMEOUT | OTHER. Best-effort and
conservative — defaults to OTHER. Used by run-scout.sh to pick the right alert
subject so an expired OAuth token reads as 'AUTH', not a generic failure.

TIMEOUT is normally decided by the wrapper from rc=124 (raw.json is often empty
or truncated after a kill). This classifier still returns TIMEOUT when the
envelope itself says the run was killed / timed out.

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

    blob = " ".join(
        str(d.get(k) or "")
        for k in ("api_error_status", "result", "subtype", "error", "text", "stopReason", "message")
    ).lower()
    # QUOTA (genuine usage/rate signals) is checked BEFORE AUTH so a quota failure
    # wins even when its message also mentions tokens.
    if any(s in blob for s in (
        "429", "rate limit", "rate_limit", "usage limit", "quota", "overloaded", "capacity",
    )):
        return "QUOTA"
    # Output truncation (the model hit its output/context token ceiling → truncated,
    # unparseable JSON) is "no usable output" — NOT a billing cap and NOT an auth issue.
    # Route to EMPTY so the alert reads honestly instead of "Max usage cap hit".
    if any(s in blob for s in ("max tokens", "maximum output tokens", "context length", "token limit")):
        return "EMPTY"
    # AUTH matches only genuine authentication signals — never the bare word "token".
    if any(s in blob for s in (
        "401", "403", "unauthor", "forbidden", "oauth", "authentication", "credential",
        "setup-token", "invalid api key", "login",
        "invalid token", "expired token", "token expired",
        "xai_api_key", "not authenticated", "unauthenticated", "device-auth",
    )):
        return "AUTH"
    # Wall-clock / interrupt signals from the CLI envelope (not the wrapper's rc=124 —
    # run-scout.sh classifies that before calling us, because raw.json is often empty).
    if any(s in blob for s in ("timed out", "command timed out", "wall-clock", "killed by signal")):
        return "TIMEOUT"
    if d.get("is_error"):
        return "OTHER"
    # exited non-zero but no error envelope and nothing usable produced → empty/parse failure
    # Claude wraps the answer in `result`; Grok Build wraps it in `text`.
    if not (d.get("result") or d.get("opportunities") or d.get("text")):
        return "EMPTY"
    return "OTHER"


if __name__ == "__main__":
    print(classify(sys.argv[1] if len(sys.argv) > 1 else ""))
