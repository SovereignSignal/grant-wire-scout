#!/usr/bin/env python3
"""notify.py — multi-channel ops alert (M9). Shared by run-scout.sh and heartbeat.py.

Exception-only alerting: callers invoke this only when something is wrong, so an alert
arriving IS the signal (silence = healthy), mirroring the clawbytes ops pattern.

Resilience (M9 — the alert path must not have a single point of failure):
  1. Resend email (primary).
  2. A generic webhook FALLBACK (NOTIFY_WEBHOOK_URL) if Resend fails or isn't configured —
     point it at Telegram / Slack / Discord / any endpoint that accepts a JSON POST.
  3. The alert is ALWAYS written to the durable scout_alerts table (if DATABASE_URL is set),
     so an alert is queryable even when every push channel is down.

Env (all optional — notify uses whatever is configured):
  RESEND_API_KEY + NOTIFICATION_EMAIL + ALERT_FROM   (email, primary)
  NOTIFY_WEBHOOK_URL                                  (push fallback)
  DATABASE_URL                                        (durable record)

Usage: notify.py <subject> [body]   (body also read from stdin if not given as arg 2)
"""
import json
import os
import ssl
import sys
import urllib.request

# A real User-Agent is REQUIRED for Resend: its Cloudflare edge 403s the default
# "Python-urllib/3.x" UA as bot traffic before auth is even evaluated.
UA = "grant-wire-scout/1.0"


def _send_resend(subject, text):
    key = os.environ.get("RESEND_API_KEY", "")
    to = os.environ.get("NOTIFICATION_EMAIL", "")
    frm = os.environ.get("ALERT_FROM", "")
    if not (key and to and frm):
        return False
    payload = json.dumps({"from": frm, "to": [to], "subject": subject, "text": text}).encode()
    req = urllib.request.Request(
        "https://api.resend.com/emails", data=payload, method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json", "User-Agent": UA},
    )
    try:
        with urllib.request.urlopen(req, timeout=30, context=ssl.create_default_context()):
            return True
    except Exception as e:
        print(f"notify: resend failed: {e}", file=sys.stderr)
        return False


def _send_webhook(subject, text):
    url = os.environ.get("NOTIFY_WEBHOOK_URL", "")
    if not url:
        return False
    msg = f"{subject}\n\n{text}" if (text and text != subject) else subject
    # A generic shape that satisfies Slack ("text"), Discord ("content"), and bespoke receivers.
    payload = json.dumps({"text": msg, "content": msg, "subject": subject, "body": text}).encode()
    req = urllib.request.Request(
        url, data=payload, method="POST",
        headers={"Content-Type": "application/json", "User-Agent": UA},
    )
    try:
        with urllib.request.urlopen(req, timeout=30, context=ssl.create_default_context()):
            return True
    except Exception as e:
        print(f"notify: webhook failed: {e}", file=sys.stderr)
        return False


def _record_alert(subject, text, channels_ok):
    dsn = os.environ.get("DATABASE_URL", "")
    if not dsn:
        return
    try:
        import psycopg2
        conn = psycopg2.connect(dsn)
        try:
            with conn, conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO scout_alerts (subject, body, channels_ok) VALUES (%s, %s, %s)",
                    (subject, text, channels_ok),
                )
        finally:
            conn.close()
    except Exception as e:
        print(f"notify: alert-record failed (non-fatal): {e}", file=sys.stderr)


def send(subject, body):
    text = body or subject
    delivered = []
    if _send_resend(subject, text):
        delivered.append("resend")
    elif _send_webhook(subject, text):      # fallback only if Resend didn't deliver
        delivered.append("webhook")
    _record_alert(subject, text, ",".join(delivered) or "none")
    if delivered:
        print(f"notify: delivered via {','.join(delivered)} — '{subject}'")
        return 0
    print(f"notify: NO push channel delivered '{subject}' (recorded to scout_alerts if DB set)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: notify.py <subject> [body]")
    subj = sys.argv[1]
    text = sys.argv[2] if len(sys.argv) > 2 else (sys.stdin.read() if not sys.stdin.isatty() else "")
    sys.exit(send(subj, text))
