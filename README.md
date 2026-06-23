# grant-wire-scout

**The Grant Wire's scout** — a scheduled Claude Code producer that discovers and source-verifies grant opportunities, A/B-tested against the (flaky/dead) Codex producer. Slots in as a 7th cohort alongside the Stringer's existing intake sources, one layer upstream of the Wire Room.

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
| `run-producer.sh` | Wrapper: render prompt → `claude -p` → extract → dedup → artifact |
| `lib/extract.py` | Pull producer JSON out of the `claude -p` JSON envelope; render report.md |
| `lib/dedup.py` | Drop URLs already in Wire Room (`/api/scan/seen-urls`) |
| `runs/<wire>/<variant>/<run_id>/` | Per-run artifact: `opportunities.json`, `report.md`, `raw.json`, `meta.json` |

## Output contract (the important bit)

Each run emits one JSON object. `opportunities[]` matches Wire Room `scan_entries` (`name`, `source_url`, `wire`, `amount`, `deadline`, `summary`, `classification`, `quality_score→fit_score`) **plus** `producer`, `variant`, `run_id` — so the Stringer intake and the A/B split can attribute every promotion to its producer.

The prompt enforces the Wire Room's hardest gate — **currency** (reject expired/past-deadline/2026-inactive) — because that's the #1 reason the Stringer rejects rows.

## A/B variants

Both run daily per wire; scored by **promotion rate per producer** over the window (the cheap, honest signal — no neutral scorer needed).

| Variant | Thesis | Setting |
|---|---|---|
| **A — broad-cast** | Wide net, emit everything that passes source-verify + currency, let downstream filter. Tests **recall**. | target 5–8, no min score |
| **B — tight-filter** | Pre-score hard, only emit `fit_score ≥ 75`. Tests **precision** / low downstream noise. | target 3–5, ≥75 |

**Codex** (whatever it still emits) is the baseline. Winner = highest *(promoted − duplicates) per run* over ~2 weeks.

## Run it

```bash
# locally (M5 has Claude Code installed):
./run-producer.sh --wire crypto --variant A
# → runs/<wire>/A/<run_id>/{opportunities.json,report.md,...}

# with Wire Room dedup (optional, needs wire-room-ops reachable + internal key):
WIRE_ROOM_API=https://wire-room-ops-production.up.railway.app \
INTERNAL_API_KEY=... ./run-producer.sh --wire ai --variant A
```

## Auth model — Claude Code subscription, NOT API keys

This producer runs as **Claude Code on a Claude.ai subscription (Max)**, authed via a
**long-lived OAuth setup-token** (`claude setup-token`). There is no `ANTHROPIC_API_KEY`;
it does not make direct API calls. The local validation run on M5 used the same auth
(claude.ai OAuth, Max), so thestringer's runs will be auth-faithful to what was tested.

## Cost / capacity framing — it's a quota, not a bill

Because runs ride the subscription, `total_cost_usd` in the run envelope is
**accounting cost-equivalent, not a charge**. The real constraint is the Max plan's
**usage limits** (5-hour + weekly), and those are **shared with interactive Claude Code
sessions**. At full scale — 3 wires × 2 variants × daily, each ~$1.50-equivalent on Opus
— a scheduled producer is a meaningful fraction of the weekly Opus allowance and could
blow the cap, breaking interactive work.

Therefore: **default the producer to Sonnet** (≈5× cheaper in quota terms, plenty for
grant discovery), keep Opus available for interactive sessions, and promote to Opus only
for individual high-value runs. The `--model` flag on `run-producer.sh` makes this a
per-run choice; the Hermes cron job should pin Sonnet.

## Deployment (thestringer) — pending two unblocks

1. **Install + auth `claude` on thestringer.** Install the CLI, then run
   `claude setup-token` **once** (complete the OAuth flow in a browser — the resulting
   long-lived token persists for headless use). No API key, no `ANTHROPIC_API_KEY`.
2. **Producer Notion DB `366000c0` not shared with the write integration.** One-time
   grant in Notion UI (Connections → add integration), OR run the producer cohort-dir-only
   and have the Stringer ingest the `claude-code` cohort directly (no Notion writes).

Once unblocked: add a Hermes cron job (clone of the intake job) firing
`run-producer.sh --model claude-sonnet-4-5` per wire at ~04:00 UTC, ahead of the 12:00
intake. The Stringer's weekly cron-review job will then observe it like every other job.

## Status

- [x] Prompt + schema + wrapper + helpers
- [x] Live local validation (M5) — see `runs/`
- [ ] Install + auth `claude` on thestringer
- [ ] Notion DB access (or cohort-dir intake path)
- [ ] Hermes cron job (per wire, variant A + B)
- [ ] Promotion-rate-per-producer dashboard query
