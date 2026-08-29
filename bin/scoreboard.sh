#!/usr/bin/env bash
# scoreboard.sh — standing promotion scoreboard for scout lanes.
#
# approve-of-decided per week × scan_source × wire × prompt_variant.
# Variant A on grok-scout is this Railway Grok lane; variant S is the
# Stringer / grok-build-wro-producer. Claude is scan_source=claude-code.
#
# Usage: DATABASE_URL=... ./bin/scoreboard.sh [days]
set -euo pipefail
DAYS="${1:-30}"
[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "scoreboard: days must be an integer (got '$DAYS')" >&2; exit 2; }
: "${DATABASE_URL:?set DATABASE_URL to the Wire Room Postgres connection string}"

psql "$DATABASE_URL" -P pager=off <<SQL
SELECT
  date_trunc('week', created_at)::date                              AS week,
  scan_source,
  wire,
  coalesce(prompt_variant, '(none)')                                AS variant,
  count(*)                                                          AS total,
  count(*) FILTER (WHERE status = 'duplicate')                      AS duplicate,
  count(*) FILTER (WHERE status = 'approved')                       AS approved,
  count(*) FILTER (WHERE status = 'declined')                       AS declined,
  count(*) FILTER (WHERE status = 'archived')                       AS archived,
  count(*) FILTER (WHERE status IN ('queued', 'raw', 'deduped'))    AS still_open,
  round(100.0 * count(*) FILTER (WHERE status = 'approved')
        / nullif(count(*) FILTER (WHERE status IN ('approved','declined','archived')), 0), 1)
                                                                    AS approve_pct,
  round(avg(quality_score)::numeric, 1)                             AS avg_quality
FROM scan_entries
WHERE scan_source IN ('claude-code', 'grok-scout', 'grok-build')
  AND created_at > now() - interval '${DAYS} days'
GROUP BY 1, 2, 3, 4
ORDER BY 1 DESC, 2, 3, 4;
SQL

echo ""
echo "approve_pct = approved / (approved + declined + archived); duplicates excluded."
echo "claude-code = Railway Claude. grok-scout variant A = Railway Grok."
echo "grok-scout variant S = Stringer / grok-build-wro-producer."
echo "grok-build = reserved; set SCOUT_SCAN_SOURCE=grok-build after the WRO enum ships."
echo "A/B only: ./bin/ab-score.sh ${DAYS} [scan_source]"
