#!/usr/bin/env bash
# run-grok-all.sh — Grok Build parallel lane. Same image as Claude + heartbeat; separate
# Railway cron (railway.grok.toml, 06:00 UTC, after Claude's 04:00 so Claude finds are
# already in the seen-url set). Lands as scan_source=grok-scout (existing Wire Room enum).
# JSON producer field is grok-build. Variant A only — Stringer's Grok Scout already uses
# variant S; don't collide in the variant dimension.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SERVICE_ROLE="${SERVICE_ROLE:-grok-scout}"
export SCOUT_ENGINE=grok
export SCOUT_SCAN_SOURCE="${SCOUT_SCAN_SOURCE:-grok-scout}"
export SCOUT_VARIANTS="${SCOUT_VARIANTS:-A}"
export SCOUT_WIRES="${SCOUT_WIRES:-crypto ai oss}"
export GROK_MODEL="${GROK_MODEL:-grok-4.6}"
exec "$ROOT/bin/run-all.sh"
