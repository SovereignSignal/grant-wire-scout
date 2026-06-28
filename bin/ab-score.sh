#!/usr/bin/env bash
# ab-score.sh — score the scout's A/B (prompt variant A vs B) by operator promotion rate.
#
# The A/B exists to answer: which producer prompt yields finds the operator actually keeps?
# Of the NON-DUPLICATE claude-code finds each variant produced, what fraction did the operator
# APPROVE (vs decline/archive)? Duplicates are excluded from the rate — a repeat the Wire Room
# already had isn't a quality failure of the producer.
#
# No extra plumbing is needed: the scout now runs both variants (bin/run-all.sh) and the Wire
# Room stores prompt_variant per scan_entries row, so this is a plain read.
#
# Usage:  DATABASE_URL=<wire-room postgres> ./bin/ab-score.sh [days]      (window default 30)
set -euo pipefail
DAYS="${1:-30}"
[[ "$DAYS" =~ ^[0-9]+$ ]] || { echo "ab-score: days must be an integer (got '$DAYS')" >&2; exit 2; }
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
WHERE scan_source = 'claude-code'
  AND created_at > now() - interval '${DAYS} days'
GROUP BY prompt_variant
ORDER BY prompt_variant;
SQL

echo ""
echo "approve_pct = approved / (approved + declined + archived); duplicates excluded."
echo "Compare variant A vs B once both have accumulated finds (the scout now runs both)."
