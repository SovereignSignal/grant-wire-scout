# Deploying grant-wire-scout on Railway

Two cron services from this one repo + image: the **scout** (finds grants, posts to the Wire
Room queue) and the **heartbeat** (pages if the scout goes silent). Auth rides the Claude.ai
**Max** subscription via an OAuth credential on a volume — no `ANTHROPIC_API_KEY`.

## Data flow
`run-all.sh` → per wire: `run-producer.sh` (claude -p discovers + source-verifies) →
`submit.py` POSTs to `wire-room-ops POST /api/scan/submit` (internal key) → entries land
`scan_source='claude-code'`, status `raw` → Wire Room dedups + classifies + queues (~5 min).
Failures email you (Resend); silence is caught by the heartbeat.

## One-time setup

1. **Scout service** — deploy this repo (Dockerfile build, uses `railway.toml`).
   - **Volume:** attach a volume mounted at **`/app/home/.claude`** (persists the OAuth token).
   - **Variables:** `WIRE_ROOM_API`, `INTERNAL_API_KEY`, `RESEND_API_KEY`, `NOTIFICATION_EMAIL`,
     `ALERT_FROM` (a Resend-verified sender), `MODEL=claude-sonnet-4-6`. Optionally
     `SCOUT_WIRES=crypto` to start conservative.
   - Cron `0 4 * * *` (set in `railway.toml`).

2. **Heartbeat service** — second service, same repo; set Config-as-code path to
   **`railway.heartbeat.toml`**. Variables: `DATABASE_URL` (read the shared Wire Room
   Postgres), `RESEND_API_KEY`, `NOTIFICATION_EMAIL`, `ALERT_FROM`, `SCOUT_SILENCE_HOURS=26`.
   No volume. Cron `0 14 * * *`.

3. **The OAuth token** (the only manual step):
   - On a machine with the CLI: `claude setup-token` (completes the browser OAuth; writes the
     credential to `~/.claude/`).
   - Copy that credential onto the scout service's volume at `/app/home/.claude/` (e.g. via a
     one-off `railway run` shell, or Railway's volume tooling). No API key is ever set.

## Validate before going live (recommended)
Disable the cron (or set `SCOUT_WIRES=crypto`) and run ONE manual tick on the scout service:

```
railway run --service <scout> bin/run-scout.sh crypto A
```

Watch for: a clean `submit: delivered N opportunities…` line, the entries appearing in the
Wire Room queue, and — the thing we can't prove until now — that **`claude -p` authed off the
mounted credential** (an auth failure emails an `AUTH` alert telling you to re-run
`claude setup-token`). Once a manual tick works end-to-end, enable the crons.

## Operating
- **Alerts are exception-only** — an email means something broke (`AUTH` / `QUOTA` / `EMPTY` /
  `DELIVERY` / `FAILED`), or the heartbeat saw silence. No email = healthy.
- **Token expired?** Re-run `claude setup-token`, replace the credential on the volume.
- **Add variant B / more volume:** raise `SCOUT_WIRES` / set `SCOUT_VARIANT=B` (or add a third
  service). Watch the Max usage cap — it's shared with interactive Claude Code sessions.
