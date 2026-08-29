# Deploying grant-wire-scout on Railway

Three cron services from this one repo + image: the **Claude scout** (finds grants, posts to
the Wire Room queue), the **Grok Build scout** (parallel lane, same gates, different search
index), and the **heartbeat** (pages if a wire is silent across both scout lanes). Claude is
unchanged. Grok is additive.

## Data flow
`run-all.sh` → per wire: `run-producer.sh` (`claude -p` or `grok -p` discovers + source-verifies)
→ `submit.py` POSTs to `wire-room-ops POST /api/scan/submit` (internal key) → entries land
`scan_source='claude-code'` or `'grok-scout'`, status `raw` → Wire Room dedups + classifies +
queues (~5 min). Failures email you (Resend); a wire with no scout rows from either
lane is caught by the heartbeat.

The JSON `producer` field is `claude-code` or `grok-build`. Wire Room's `scan_source` enum
already has `grok-scout` (Stringer's Grok Scout). This Railway lane reuses that value — do
**not** invent `grok-build` as a scan_source without a wire-room-ops enum PR. Variant **A**
only on the Grok lane so it doesn't collide with Stringer's variant `S`.

## One-time setup

1. **Scout service (Claude)** — deploy this repo (Dockerfile build).
   - **Make it a cron:** Settings → Cron Schedule `0 4 * * 0,2,4,6` (Sun/Tue/Thu/Sat 04:00 UTC), Restart Policy **Never**.
     ⚠️ `railway.toml` did NOT auto-apply on first deploy here — set these in the UI (or via API)
     to be sure, otherwise it runs as an always-on service and crash-loops.
   - **Variables:** `WIRE_ROOM_API`, `INTERNAL_API_KEY`, `RESEND_API_KEY`, `NOTIFICATION_EMAIL`,
     `ALERT_FROM` (a Resend-verified sender), `MODEL=claude-sonnet-4-6`, `CLAUDE_CODE_OAUTH_TOKEN`
     (from `claude setup-token`). Optionally `SCOUT_WIRES=crypto` to start conservative.
   - **No volume.** Do not set `SCOUT_ENGINE` — default is `claude`.

2. **Heartbeat service** — second service, same repo; set Config-as-code path to
   `railway.heartbeat.toml` (or set start command `python3 lib/heartbeat.py` + cron `0 14 * * *`
   in the UI). Variables: `DATABASE_URL` (read the shared Wire Room Postgres), `RESEND_API_KEY`,
   `NOTIFICATION_EMAIL`, `ALERT_FROM`, `SCOUT_SILENCE_HOURS=60`. No volume, no claude/grok token.
   Watches **both** `claude-code` and `grok-scout` by default — a wire is silent only when
   neither lane landed rows. Pin one lane with `SCOUT_SCAN_SOURCE=claude-code` (or
   `grok-scout`) if you want an isolated monitor. 60 hours covers the weekday split:
   Tue/Thu/Sat 14:00 still see the previous Claude tick (58h), and Friday still sees
   Wednesday's Grok tick (56h). 52h missed both and paged a saturated Claude oss while
   Grok had just fed the wire.

3. **Grok Build scout (parallel, optional)** — third service, same repo; Config-as-code path
   `railway.grok.toml` (start command `bin/run-grok-all.sh`, cron `0 6 * * 1,3,5` Mon/Wed/Fri, Restart **Never**).
   Same shared variables as the Claude scout (`WIRE_ROOM_API`, `INTERNAL_API_KEY`, Resend,
   `DATABASE_URL` for the ledger), plus:
   - **`GROK_AUTH_JSON`** — contents of `~/.grok/auth.json` after `grok login` on a machine with
     a browser. This rides grok.com / SuperGrok, same idea as `CLAUDE_CODE_OAUTH_TOKEN`.
     Access tokens last ~6h; the CLI refreshes them on disk. Attach a volume at
     `/app/grok-session` and set `GROK_HOME=/app/grok-session` so the refreshed
     file survives until the next cron. Do **not** mount over `/app/home/.grok`
     — that directory also holds the Grok CLI binary in the image.
     Hydrate keeps that on-disk session unless you put a *newer* `GROK_AUTH_JSON` (re-login).
     When the lane AUTH-alerts anyway, re-run `grok login` and replace the env var.
     Do **not** set `XAI_API_KEY` unless you accept a console.x.ai API bill.
   - `GROK_MODEL=grok-4.6` (Grok Build flagship as of 2026-08-12). Flip to `grok-4.7` the day
     it ships in Grok Build — do not leave a 4.7 default that the CLI cannot resolve.
   - Wires: `SCOUT_WIRES=crypto ai oss` (same set as Claude). Script pins `SCOUT_VARIANTS=A`.
   - Cadence splits the week so both lanes are not burning quota every night: Claude
     Sun/Tue/Thu/Sat 04:00 UTC, Grok Mon/Wed/Fri 06:00 UTC. Grok's edge is X-first
     discovery, not a race to submit first.

4. **The Claude token** (the only manual step for the existing service): on a machine with the
   CLI, `claude setup-token` (completes the browser OAuth, prints a long-lived `sk-ant-oat...`
   token) → set it as the `CLAUDE_CODE_OAUTH_TOKEN` variable on the scout service. No
   `ANTHROPIC_API_KEY`.

## Validate before going live (recommended)
Trigger ONE manual run on the Claude scout service and watch:
- `claude -p` auths off `CLAUDE_CODE_OAUTH_TOKEN` (an auth failure emails an `AUTH` alert),
- `submit: delivered N opportunities…` and the entries appearing in the Wire Room queue.
Then trust the `0 4 * * 0,2,4,6` cron.

For Grok: same, one manual deploy of the grok-scout service. Confirm
`scan_source=grok-scout` in the Wire Room. Default wires are `crypto ai oss`.

## Operating
- **Cadence:** Claude Sun/Tue/Thu/Sat 04:00 UTC; Grok Mon/Wed/Fri 06:00 UTC. Heartbeat
  runs daily at 14:00 UTC against **both** scout sources (`SCOUT_SILENCE_HOURS=60`).
- **Alerts are exception-only** (`AUTH` / `QUOTA` / `EMPTY` / `DELIVERY` / `FAILED`), plus the
  heartbeat when a wire is silent across both lanes. No email = healthy.
- **Quota, not dollars.** Both lanes ride subscriptions (Claude Max, SuperGrok). The CLI
  `cost_usd` is accounting-equivalent only. The real budget is the shared usage cap and
  operator review time. Keep `SCOUT_VARIANT=A` (unset used to fall through to A+B).
- **SILENT on a Claude-off day** that names a wire Grok already fed is a stale window —
  after this deploy it should not fire. A clean zero-yield still means "nothing new",
  which includes "every find was already in the catalog".
- **Claude token expired?** Re-run `claude setup-token`, update `CLAUDE_CODE_OAUTH_TOKEN`.
- **Grok session expired?** Access tokens last ~6h; the CLI refresh lives on the
  `/app/grok-session` volume. Re-run `grok login` and replace `GROK_AUTH_JSON` only after an
  AUTH alert (or if the volume is gone) — not on a daily schedule.
- **Scale:** raise `SCOUT_WIRES` / set `SCOUT_VARIANT=B` on Claude. Watch the Max usage cap —
  it's shared with interactive Claude Code sessions. Grok Build usage is the SuperGrok quota
  (or an API bill if you set `XAI_API_KEY`).
- **Score the A/B (or Claude vs Grok):** `./bin/ab-score.sh 30` and `./bin/ab-score.sh 30 grok-scout`.
  Standing board (week × source × wire × variant): `./bin/scoreboard.sh 30`.
  Railway Grok is `grok-scout` / variant **A**. Stringer Grok is variant **S**.
- **Skip a saturated wire:** set `SCOUT_SKIP_IF_FED_HOURS=36` on Claude and/or Grok.
  Writes a `status=skipped` ledger row so the lane does not look dead.
- **Verified-only submit:** `SCOUT_REQUIRE_VERIFIED=1` drops `unverified` / `fetch_failed`
  (keeps `partial`). Default off — recall over precision.
- **Saturation vs thin day:** apply `sql/scout_runs_funnel.sql` once on Wire Room
  Postgres. After that, heartbeat can say "found 6, all already in the catalog".
- **Split Grok sources:** keep submitting as `grok-scout` until wire-room-ops adds
  `grok-build` to `SCAN_SOURCES`. Then set `SCOUT_SCAN_SOURCE=grok-build` on
  `grant-wire-grok`. Do not flip first — WRO will reject the batch.
- **Lane-dead mail:** heartbeat still does not SILENT a wire the other lane fed, but
  it will page `LANE: Claude` (or Grok) if that producer wrote no ok/skipped ledger
  row, or failed AUTH/QUOTA, in the window.
