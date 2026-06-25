# Deploying grant-wire-scout on Railway

Two cron services from this one repo + image: the **scout** (finds grants, posts to the Wire
Room queue) and the **heartbeat** (pages if the scout goes silent). Auth rides the Claude.ai
**Max** subscription via a long-lived OAuth token in the **`CLAUDE_CODE_OAUTH_TOKEN`** env var —
no API key, no volume, no credential file.

## Data flow
`run-all.sh` → per wire: `run-producer.sh` (claude -p discovers + source-verifies) →
`submit.py` POSTs to `wire-room-ops POST /api/scan/submit` (internal key) → entries land
`scan_source='claude-code'`, status `raw` → Wire Room dedups + classifies + queues (~5 min).
Failures email you (Resend); silence is caught by the heartbeat.

## One-time setup

1. **Scout service** — deploy this repo (Dockerfile build).
   - **Make it a cron:** Settings → Cron Schedule `0 4 * * *`, Restart Policy **Never**.
     ⚠️ `railway.toml` did NOT auto-apply on first deploy here — set these in the UI (or via API)
     to be sure, otherwise it runs as an always-on service and crash-loops.
   - **Variables:** `WIRE_ROOM_API`, `INTERNAL_API_KEY`, `RESEND_API_KEY`, `NOTIFICATION_EMAIL`,
     `ALERT_FROM` (a Resend-verified sender), `MODEL=claude-sonnet-4-6`, `CLAUDE_CODE_OAUTH_TOKEN`
     (from `claude setup-token`). Optionally `SCOUT_WIRES=crypto` to start conservative.
   - **No volume.**

2. **Heartbeat service** — second service, same repo; set Config-as-code path to
   `railway.heartbeat.toml` (or set start command `python3 lib/heartbeat.py` + cron `0 14 * * *`
   in the UI). Variables: `DATABASE_URL` (read the shared Wire Room Postgres), `RESEND_API_KEY`,
   `NOTIFICATION_EMAIL`, `ALERT_FROM`, `SCOUT_SILENCE_HOURS=26`. No volume, no claude token.

3. **The token** (the only manual step): on a machine with the CLI, `claude setup-token`
   (completes the browser OAuth, prints a long-lived `sk-ant-oat...` token) → set it as the
   `CLAUDE_CODE_OAUTH_TOKEN` variable on the scout service. No `ANTHROPIC_API_KEY`.

## Validate before going live (recommended)
Trigger ONE manual run on the scout service and watch:
- `claude -p` auths off `CLAUDE_CODE_OAUTH_TOKEN` (an auth failure emails an `AUTH` alert),
- `submit: delivered N opportunities…` and the entries appearing in the Wire Room queue.
Then trust the `0 4 * * *` cron.

## Operating
- **Alerts are exception-only** (`AUTH` / `QUOTA` / `EMPTY` / `DELIVERY` / `FAILED`), plus the
  heartbeat on silence. No email = healthy.
- **Token expired?** Re-run `claude setup-token`, update the `CLAUDE_CODE_OAUTH_TOKEN` variable.
- **Scale:** raise `SCOUT_WIRES` / set `SCOUT_VARIANT=B`. Watch the Max usage cap — it's shared
  with interactive Claude Code sessions.
