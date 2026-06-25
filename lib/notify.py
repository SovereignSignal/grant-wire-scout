#!/usr/bin/env python3
"""notify.py — send an ops alert email via Resend. Shared by run-scout.sh and heartbeat.py.

Exception-only alerting: callers invoke this only when something is wrong, so an email
arriving IS the signal (silence = healthy), mirroring the clawbytes ops pattern.

Env (all required): RESEND_API_KEY (env-only — a real credential), NOTIFICATION_EMAIL
(recipient — the same address wire-room-ops alerts to), ALERT_FROM (a Resend-verified
sender, e.g. "Grant Wire Scout <scout@yourdomain.tld>").

Usage: notify.py <subject> [body]   (body also read from stdin if not given as arg 2)
"""
import json
import os
import ssl
import sys
import urllib.request


def send(subject, body):
    key = os.environ.get("RESEND_API_KEY", "")          # env-only credential
    to = os.environ.get("NOTIFICATION_EMAIL", "")
    frm = os.environ.get("ALERT_FROM", "")
    if not (key and to and frm):
        print("notify: RESEND_API_KEY, NOTIFICATION_EMAIL, and ALERT_FROM are all required", file=sys.stderr)
        return 2

    payload = json.dumps({
        "from": frm,
        "to": [to],
        "subject": subject,
        "text": body or subject,
    }).encode()
    req = urllib.request.Request(
        "https://api.resend.com/emails",
        data=payload,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30, context=ssl.create_default_context()):
            pass
    except Exception as e:
        print(f"notify: send failed: {e}", file=sys.stderr)
        return 1
    print(f"notify: sent '{subject}' to {to}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: notify.py <subject> [body]")
    subj = sys.argv[1]
    text = sys.argv[2] if len(sys.argv) > 2 else (sys.stdin.read() if not sys.stdin.isatty() else "")
    sys.exit(send(subj, text))
