#!/usr/bin/env python3
"""name_dedup.py — drop finds whose PROGRAM NAME the operator has already decided on.

dedup.py matches on normalized URL against the Wire Room's seen-urls. That misses the
common case: the same program cited at a different URL. In the 30 days to 2026-09-03 the
Claude lane put Avalanche Team1 in front of the operator seven times and NSF CISE Future
CoRe eight, each time under a slightly different page, and each time someone had to read
it and decline it again.

It drops a name ONLY where the operator's own prior verdict was negative — declined or
archived. Three statuses are deliberately excluded, each measured against 60 days of both
lanes (2026-07-05 .. 2026-09-03, 418 finds) before choosing:

  status set                              dropped  approvals lost  waste stopped
  approved+declined+archived+duplicate         44               4             40
  approved+declined+archived                   33               2             31
  declined+archived            <- chosen       19               1             18

`duplicate` and `deduped` are not verdicts, they are automatic outcomes, so a name carrying
only those has never actually been ruled on: the Rust Foundation Maintainers Fund and the
Polymarket Science Fellowship were each deduped three or four times and then approved.
`approved` is excluded because a returning approved program is usually its next cycle,
which the prompt explicitly asks for: Solana Foundation Grants was approved in March and
again in August.

The one known cost of the chosen set is Arbitrum Open House Buildathon, declined three
times in May and approved as a new event in August. The complementary defence is the
priming list (known_programs.py), which now carries this producer's own repeat offenders
so the re-find is discouraged before it costs a search.

Set SCOUT_NAME_DEDUP=0 to disable.

It reads the Wire Room Postgres directly. The Wire Room has no seen-names endpoint, and the
scout already holds DATABASE_URL for known_programs.py and ledger.py, so this avoids a
cross-repo API change for one query.

Best-effort by contract: no DATABASE_URL, no psycopg2, or any DB error keeps every
opportunity and exits 0. This sits in the cron delivery path — it must never be the reason
a real find fails to land.

Usage: name_dedup.py <opportunities.json> <wire>
EXIT: 0 always, unless the payload itself cannot be read or written (2).
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

# Negative operator verdicts only — see the module docstring for the measurement.
_REJECTED_BY_OPERATOR = ("declined", "archived")
_DAYS = int(os.environ.get("SCOUT_NAME_DEDUP_DAYS", "180"))


def normalize_name(s) -> str:
    """Lowercase, strip punctuation, collapse whitespace.

    Deliberately conservative: it folds case, spacing and punctuation only. It does NOT
    stem, drop years, or strip parentheticals, because "Round 1" and "Round 2" are
    different programs and "2026 cohort" is exactly the new cycle the prompt asks for.
    """
    s = re.sub(r"[^a-z0-9]+", " ", str(s or "").lower())
    return " ".join(s.split())


def fetch_rejected_names(wire):
    dsn = os.environ.get("DATABASE_URL", "")
    if not dsn:
        return None
    try:
        import psycopg2
    except ImportError:
        return None
    try:
        conn = psycopg2.connect(dsn)
        try:
            with conn, conn.cursor() as cur:
                cur.execute(
                    """
                    /* seen_names */
                    SELECT DISTINCT name FROM scan_entries
                    WHERE wire = %s
                      AND status = ANY(%s)
                      AND name IS NOT NULL AND length(trim(name)) >= 3
                      AND created_at >= now() - (%s || ' days')::interval
                    """,
                    (wire, list(_REJECTED_BY_OPERATOR), str(_DAYS)),
                )
                return {normalize_name(r[0]) for r in cur.fetchall() if r and r[0]}
        finally:
            conn.close()
    except Exception:
        return None


def main(opp_path: str, wire: str) -> int:
    p = Path(opp_path)
    try:
        payload = json.loads(p.read_text())
    except Exception as e:
        print(f"name_dedup: cannot read {opp_path}: {e}", file=sys.stderr)
        return 2

    if (os.environ.get("SCOUT_NAME_DEDUP") or "1").strip().lower() in ("0", "false", "off", "no"):
        print("[name-dedup] disabled (SCOUT_NAME_DEDUP=0)")
        return 0

    seen = fetch_rejected_names(wire)
    if seen is None:
        print("[name-dedup] no DB — skipped (kept everything)")
        return 0

    opps = payload.get("opportunities") or []
    kept, dropped = [], []
    for o in opps:
        key = normalize_name(o.get("name"))
        if key and key in seen:
            dropped.append({
                "name": o.get("name"),
                "source_url": o.get("source_url"),
                "classification": "DUPLICATE",
                "reason": ("the operator already declined or archived this program by name "
                           "(name match, different URL)"),
            })
        else:
            kept.append(o)

    payload["opportunities"] = kept
    payload.setdefault("rejected", []).extend(dropped)
    payload["name_dedup"] = {"checked": len(opps), "kept": len(kept),
                             "dropped": len(dropped), "seen_set": len(seen)}
    # Keep the ledger's funnel honest: dedup.py may have already written one.
    funnel = payload.get("funnel")
    if isinstance(funnel, dict):
        funnel["kept"] = len(kept)
        funnel["name_dropped"] = len(dropped)

    try:
        p.write_text(json.dumps(payload, indent=2))
    except Exception as e:
        print(f"name_dedup: cannot write {opp_path}: {e}", file=sys.stderr)
        return 2

    print(f"[name-dedup] kept {len(kept)}, dropped {len(dropped)} (rejected-name set {len(seen)})")
    for d in dropped:
        print(f"[name-dedup]   drop: {d['name']}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: name_dedup.py <opportunities.json> <wire>")
    sys.exit(main(sys.argv[1], sys.argv[2]))
