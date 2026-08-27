#!/usr/bin/env bash
# ab-score.sh — score the scout's A/B (prompt variant A vs B) by operator promotion rate.
#
# The A/B exists to answer: which producer prompt yields finds the operator actually keeps?
# Of the NON-DUPLICATE finds each variant produced (default scan_source=claude-code),
# what fraction did the operator APPROVE (vs decline/archive)? Duplicates are excluded
# from the rate — a repeat the Wire Room already had isn't a quality failure of the producer.
#
# No extra plumbing is needed once both arms have rows: the Wire Room stores prompt_variant
# per scan_entries row, so this is a plain read. Production is variant A only; set
# SCOUT_VARIANTS='A B' on Claude when you want a scored comparison (doubles quota).
#
# Usage:  DATABASE_URL=<wire-room postgres> ./bin/ab-score.sh [days] [scan_source]
#         scan_source default claude-code; pass grok-scout to score the Grok Build lane.
set -euo pipefail
DAYS="${1:-30}"
SOURCE="${2:-${SCOUT_SCAN_SOURCE:-claude-code}}"
[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "ab-score: days must be an integer (got '$DAYS')" >&2; exit 2; }
[[ "$SOURCE" =~ ^[a-z0-9-]+$ ]] || { echo "ab-score: scan_source must be [a-z0-9-] (got '$SOURCE')" >&2; exit 2; }
: "${DATABASE_URL:?set DATABASE_URL to the Wire Room Postgres connection string}"

psql "$DATABASE_URL" -P pager=off <<SQL
SELECT
  coalesce(prompt_variant, '(none)')                                  AS variant,
  count(*)                                                            AS total,
  count(*) FILTER (WHERE status = 'duplicate')                        AS duplicate,
  count(*) FILTER (WHERE status = 'approved')                         AS approved,
  count(*) FILTER (WHERE status = 'declined')                         AS declined,
  count(*) FILTER (WHERE status = 'archived')                         AS archived,
  round(100.0 * count(*) FILTER (WHERE status = 'approved')
        / nullif(count(*) FILTER (WHERE status IN ('approved','declined','archived')), 0), 1)
                                                                      AS approve_pct,
  round(avg(quality_score)::numeric, 1)                               AS avg_quality
FROM scan_entries
WHERE scan_source = '${SOURCE}'
  AND created_at > now() - interval '${DAYS} days'
GROUP BY prompt_variant
ORDER BY prompt_variant;
SQL

echo ""
echo "scan_source=${SOURCE}"
echo "approve_pct = approved / (approved + declined + archived); duplicates excluded."
echo "Compare variant A vs B once both have accumulated finds (set SCOUT_VARIANTS='A B')."
echo "Score the Grok Build lane with: ./bin/ab-score.sh ${DAYS} grok-scout"
