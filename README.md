# grant-wire-scout

**The Grant Wire's scout** — scheduled producers (Claude Code + a parallel Grok Build lane)
that discover and source-verify grant opportunities. Slots in as a 7th cohort alongside the
Stringer's existing intake sources, one layer upstream of the Wire Room. Claude stays the
default Railway cron; Grok is a third service on the same image, not a replacement.

## Why

The Codex + Claude Notion producer pipeline dropped ~93% over 4 weeks (mid-May → mid-June 2026), with a Codex "model at capacity" outage as the clearest lead. The daily *intake* (Stringer/Hermes on `thestringer`) is healthy; the decline is purely upstream producer volume. This producer makes Claude Code a **reliable** producer so the Wire Room keeps fed independent of Codex, and lets us measure Claude vs Codex head-to-head on promotion rate.

## What a "scheduled task" is here

Claude Code (v2.1) has no native scheduler. A "scheduled task" = a headless `claude -p` invocation driven by an **external** scheduler. On `thestringer` that scheduler is **Hermes cron** (`~/.hermes/cron/jobs.json`) — the same system that already fires the daily intake (`e673c266f671`, 12:00 UTC). The producer runs **alongside** it, one layer upstream.

```
Hermes cron (thestringer) ──► run-producer.sh ──► claude -p (WebSearch+WebFetch) ──► opportunities.json
                                                                                              │
                                              writes to cohort lane + (opt) Notion DB ◄──────┘
                                                                                              │
Stringer intake (Hermes cron 12:00 UTC) ──► reads cohorts + Notion DB ──► promotes to Wire Room
```

## Parts

| Path | Role |
|---|---|
| `prompts/producer.md` | Wire-parameterized producer prompt (discovery → source-verify → currency-gate → JSON) |
| `schemas/opportunity.schema.json` | Strict output contract (Wire Room `scan_entries` shape + producer attribution) |
| `run-producer.sh` | Wrapper: render prompt → `claude -p` or `grok -p` → extract → dedup → artifact |
| `bin/run-all.sh` | Claude cron tick (default `SCOUT_ENGINE=claude`) |
| `bin/run-grok-all.sh` | Grok Build cron tick (`scan_source=grok-scout`, variant A) |
| `lib/extract.py` | Pull producer JSON out of the Claude `.result` or Grok `.text` envelope |
| `lib/hydrate_grok_auth.py` | Write `GROK_AUTH_JSON` to `$GROK_HOME/auth.json` before `grok -p` |
| `railway.grok.toml` | Third Railway service: same image, `0 6 * * 1,3,5` (Mon/Wed/Fri) |
| `lib/dedup.py` | Drop URLs already in Wire Room (`/api/scan/seen-urls`) |
| `lib/validate.py` | Enforce the opportunity schema; optional verified-only gate |
| `lib/skip_if_fed.py` | Opt-in: skip a wire the other lane just filled |
| `bin/scoreboard.sh` | Weekly approve-of-decided by source × wire × variant |
| `lib/digest.py` | Daily visibility email: queue finds, models used, week/month spend |
| `runs/<wire>/<variant>/<run_id>/` | Per-run artifact: `opportunities.json`, `report.md`, `raw.json`, `meta.json`, `producer.stderr` (+ `raw.killed.json` / `raw.salvage.json` after a timeout) |

## Output contract (the important bit)

Each run emits one JSON object. `opportunities[]` matches Wire Room `scan_entries` (`name`, `source_url`, `wire`, `amount`, `deadline`, `summary`, `classification`, `quality_score→fit_score`) **plus** `producer`, `variant`, `run_id` — so the Stringer intake and the A/B split can attribute every promotion to its producer.

The prompt enforces the Wire Room's hardest gate — **currency** (reject expired/past-deadline/2026-inactive) — because that's the #1 reason the Stringer rejects rows.

## A/B variants

Production is **variant A only** (one arm per wire). `SCOUT_VARIANTS='A B'` runs both so
promotion rates are comparable — that **doubles** the Max/SuperGrok quota share, so leave
it off until you are scoring on purpose (`bin/ab-score.sh`).

| Variant | Thesis | Setting |
|---|---|---|
| **A — broad-cast** | Wide net, emit everything that passes source-verify + currency, let downstream filter. Tests **recall**. | target 5–8, no min score |
| **B — tight-filter** | Pre-score hard, only emit `fit_score ≥ 75`. Tests **precision** / low downstream noise. | target 3–5, ≥75 |

**Codex** (whatever it still emits) is the baseline. Winner = highest *(promoted − duplicates) per run* over ~2 weeks.

## Run it

```bash
# locally (needs Claude Code installed):
./run-producer.sh --wire crypto --variant A
# → runs/<wire>/A/<run_id>/{opportunities.json,report.md,...}

# Grok Build lane (needs `grok` on PATH + `grok login` or GROK_AUTH_JSON):
./run-producer.sh --wire crypto --variant A --engine grok

# with Wire Room dedup (optional, needs wire-room-ops reachable + internal key):
WIRE_ROOM_API=https://wire-room-ops-production.up.railway.app \
INTERNAL_API_KEY=... ./run-producer.sh --wire ai --variant A
```

## Parallel Grok Build lane (Railway)

Same Docker image as Claude + heartbeat. New service via `railway.grok.toml`:
`bin/run-grok-all.sh` **Mon/Wed/Fri 06:00 UTC**; Claude is **Sun/Tue/Thu/Sat 04:00 UTC** so
the lanes split SuperGrok / Claude Max quota. Runs **crypto, ai, and
oss** (variant A). Submits
`scan_source=grok-scout` (already in Wire Room's `SCAN_SOURCES`); JSON `"producer": "grok-build"`.
Auth is `GROK_AUTH_JSON` (contents of `~/.grok/auth.json` from `grok login`) — subscription,
not `XAI_API_KEY` unless you want an API bill. Access tokens last ~6h; persist the refreshed
session on a volume at `/app/grok-session` (`GROK_HOME`). Default model is
`grok-4.7`. The image installs the latest Grok CLI, and each wire runs `grok update`
before the hunt (120s cap). A 426 / outdated response upgrades the CLI and retries
that wire once. Claude stays on its pinned CLI and on Claude.

See [DEPLOY.md](DEPLOY.md) for the third-service checklist. Claude cron stays on
`railway.toml` if you never add the Grok service.

## Auth model — Claude Code subscription, NOT API keys

This producer runs as **Claude Code on a Claude.ai subscription (Max)**, authed via a
**long-lived OAuth setup-token** (`claude setup-token`). There is no `ANTHROPIC_API_KEY`;
it does not make direct API calls. The local validation run on M5 used the same auth
(claude.ai OAuth, Max), so thestringer's runs will be auth-faithful to what was tested.

## Cost / capacity framing — it's a quota, not a bill

Because runs ride the subscription, `total_cost_usd` in the run envelope is
**accounting cost-equivalent, not a charge**. The real constraint is the Max plan's
**usage limits** (5-hour + weekly), and those are **shared with interactive Claude Code
sessions**, and Opus has its own cap on top of that shared window.

The Claude cron defaults to **Opus 5.5** (`claude-opus-5-5`). List price is $4 / $20
per million input / output tokens, cache reads $0.20, against Sonnet 4.6 at $3 / $15.
The accounting figure is about a third higher. On Max, Opus draws the shared 5-hour
and weekly allowance faster than Sonnet (Anthropic's guidance: several times more of
the plan per turn), and thinking is always on at the default effort `medium`, billed
as output. This lane is 3 wires, 4 days a week, up to 100 turns each, so it can take
a real share of the weekly allowance and can trip the Opus cap while Sonnet would
still have headroom. Fast mode ($8 / $40) is not enabled. Set `MODEL=claude-sonnet-4-6`
on the Claude service to step back. Grok 4.7 is the same price and speed as Grok 4.6
($2 / $6 per million input / output tokens). The `--model` flag on `run-producer.sh`
overrides either default for one run.

## Deployment

Production is **Railway**, three crons from this image. See [DEPLOY.md](DEPLOY.md).
Thestringer / Hermes cron / Notion DB `366000c0` are **not** the live path.

| Service | Cron (UTC) | Start |
|---|---|---|
| `grant-wire-scout` (Claude) | `0 4 * * 0,2,4,6` | `bin/run-all.sh` |
| `grant-wire-grok` | `0 6 * * 1,3,5` | `bin/run-grok-all.sh` |
| `grant-wire-heartbeat` | `0 14 * * *` | `python3 lib/heartbeat.py` (silence page + daily digest) |

`railway.toml` historically did not auto-apply on the Claude service — confirm the
schedule in the Railway UI/API after deploy.

## Status

- [x] Prompt + schema + wrapper + helpers
- [x] Live Railway Claude + Grok + heartbeat
- [x] Dual-lane silence (a wire is silent only if neither lane landed rows)
- [x] Lane-dead page (one producer can die even when the other fed the wire)
- [x] `SCOUT_SKIP_IF_FED_HOURS` (opt-in; skip a wire the other lane just filled)
- [x] Runtime schema validate + optional `SCOUT_REQUIRE_VERIFIED`
- [x] Standing scoreboard: `./bin/scoreboard.sh 30`
- [x] Daily digest email (queue + models + week/month quota-equiv spend)
- [ ] Apply `sql/scout_runs_funnel.sql` on Wire Room Postgres (saturation vs thin)
- [ ] WRO enum `grok-build` (then set `SCOUT_SCAN_SOURCE=grok-build` on the Grok service)
- [ ] Promotion scoreboard as a Wire Room view (script exists; pin it somewhere operators look)
