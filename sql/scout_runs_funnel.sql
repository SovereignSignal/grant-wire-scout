-- Apply once on the shared Wire Room Postgres (psql "$DATABASE_URL" -f sql/scout_runs_funnel.sql).
-- grant-wire-scout must not ALTER this schema from a cron. After this lands,
-- ledger.py writes found_count / dedup_dropped and heartbeat can say
-- "saturation" (found N, all already in the catalog) instead of "thin day".
ALTER TABLE scout_runs ADD COLUMN IF NOT EXISTS found_count INTEGER;
ALTER TABLE scout_runs ADD COLUMN IF NOT EXISTS dedup_dropped INTEGER;
