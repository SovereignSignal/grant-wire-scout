# AGENTS.md

## Cursor Cloud specific instructions

`grant-wire-scout` is a scheduled grant-discovery **producer** pipeline: `bin/run-all.sh`/`bin/run-scout.sh` → `run-producer.sh` renders `prompts/producer.md`, invokes a headless CLI (`claude -p` or `grok -p`), then `lib/*.py` extract → verify → dedup → report → submit to the Wire Room and alert (email/webhook) only on failure. `lib/heartbeat.py` is a separate Railway cron that pages if the scout goes silent. It is a backend/CLI service — there is no web UI to exercise.

### Runtime & dependencies
- Python 3 (stdlib does most of the work) + Bash ≥ 4 are already present. The only third-party package is `psycopg2-binary` (see `requirements.txt`), and only `lib/heartbeat.py`/`lib/ledger.py` need it. The startup update script installs it, so it is normally already available.
- The `claude` and `grok` CLIs are **not** installed in this dev image — they only exist in the production `Dockerfile`. Live `bin/run-all.sh`/`run-producer.sh` runs also need subscription auth secrets (`CLAUDE_CODE_OAUTH_TOKEN` / `GROK_AUTH_JSON`) that are not present here, so a real quota-spending run is not expected in-VM.

### Tests (hermetic — no network, no quota, no prod side effects)
The test suite is the four scripts under `bin/`: `test-e2e.sh`, `test-grok-engine.sh`, `test-heartbeat.sh`, `test-producer-timeout.sh`. They stub `claude`/`grok`, mock the Wire Room over loopback HTTP, and stub `psycopg2` on `PYTHONPATH` where needed. Run them directly, e.g. `bash bin/test-e2e.sh`.

### Lint
There is no dedicated linter/formatter configured. The syntax-check equivalents are `python3 -m py_compile lib/*.py` and `bash -n <script>.sh`.

### Running end-to-end without the real CLIs / secrets
To exercise the full pipeline locally, override the CLI with a stub via the `CLAUDE=`/`GROK=` env vars and point `WIRE_ROOM_API` at a local mock HTTP server (`INTERNAL_API_KEY=<anything>`), which is exactly what `bin/test-e2e.sh` and `bin/test-grok-engine.sh` do — read those for a working harness. `bin/run-scout.sh crypto A` is the single-wire entrypoint.

### Non-obvious gotchas
- `runs/` (per-run artifacts) is gitignored and regenerated every run.
- The Wire Room `/api/scan/seen-urls` endpoint returns `{"urls": [...]}`; a mock that returns a bare list makes `lib/dedup.py` skip dedup (non-fatal, full set retained).
- `bin/run-all.sh` intentionally refuses loudly (exit 1) when `SERVICE_ROLE=scout` but the matching auth secret is missing — a missing token is a misconfiguration, not a silent no-op.
