import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("ledger", Path(__file__).parents[1] / "lib/ledger.py")
ledger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger)


class Cursor:
    def __init__(self, missing_funnel=False):
        self.missing_funnel = missing_funnel
        self.writes = []

    def execute(self, sql, row):
        if self.missing_funnel and "found_count" in sql:
            raise RuntimeError('column "found_count" does not exist')
        self.writes.append((sql, dict(row)))

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class Connection(Cursor):
    def cursor(self):
        return self

    def close(self):
        pass

    def rollback(self):
        pass


class LedgerTests(unittest.TestCase):
    def test_wrapper_start_is_utc_for_both_engines_and_skipped_runs(self):
        for producer in ("claude-code", "grok-build"):
            for suffix in ("", "-skipped"):
                got = ledger.started_at_from_run_id(f"{producer}-2026-09-24T042656Z{suffix}")
                self.assertEqual(got.isoformat(), "2026-09-24T04:26:56+00:00")

    def test_unrecognized_or_invalid_ids_stay_unknown(self):
        for value in ("", "manual-run", "other-2026-09-24T042656Z",
                      "grok-build-2026-02-30T042656Z", "grok-build-2026-09-24T042656Z-extra"):
            self.assertIsNone(ledger.started_at_from_run_id(value))

    def write(self, *, metadata=True, missing_funnel=False):
        conn = Connection(missing_funnel)
        with tempfile.TemporaryDirectory() as root:
            rd = Path(root) / "grok-build-2026-09-24T042656Z"
            rd.mkdir()
            if metadata:
                (rd / "meta.json").write_text(json.dumps({
                    "run_id": rd.name, "wire": "oss", "opportunity_count": 2,
                    "found_count": 5, "dedup_dropped": 3, "duration_ms": 1000,
                }))
            with patch.dict(os.environ, {"DATABASE_URL": "postgresql://stub"}), \
                 patch.dict("sys.modules", {"psycopg2": types.SimpleNamespace(connect=lambda _: conn)}), \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ledger.main(rd, "ok" if metadata else "timeout"), 0)
        return conn.writes[0]

    def test_success_preserves_start_and_funnel(self):
        sql, row = self.write()
        self.assertEqual(row["started_at"].isoformat(), "2026-09-24T04:26:56+00:00")
        self.assertEqual((row["found_count"], row["dedup_dropped"]), (5, 3))
        self.assertIn("COALESCE(scout_runs.started_at, EXCLUDED.started_at)", sql)

    def test_timeout_before_metadata_still_has_wrapper_start(self):
        _, row = self.write(metadata=False)
        self.assertEqual(row["status"], "timeout")
        self.assertEqual(row["started_at"].isoformat(), "2026-09-24T04:26:56+00:00")
        self.assertIsNone(row["duration_ms"])

    def test_pre_migration_fallback_retains_start(self):
        sql, row = self.write(missing_funnel=True)
        self.assertNotIn("found_count", sql)
        self.assertIn("%(started_at)s", sql)
        self.assertIsNotNone(row["started_at"])


if __name__ == "__main__":
    unittest.main()
