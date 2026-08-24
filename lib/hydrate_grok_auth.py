#!/usr/bin/env python3
"""hydrate_grok_auth.py — materialize Grok Build credentials for a headless run.

Grok Build reads `~/.grok/auth.json` (override with GROK_HOME) from `grok login`,
or falls back to `XAI_API_KEY`. Access tokens in that file last ~6h; the CLI
refreshes them on disk using `refresh_token`. Cron containers are ephemeral, so
a volume at GROK_HOME is required for the refreshed file to survive until the
next tick. On Railway that is `/app/grok-session`, not `/app/home/.grok` (the
CLI binary lives under the latter). GROK_AUTH_JSON is the bootstrap / re-login seed.

Env:
  GROK_AUTH_JSON  contents of auth.json from `grok login` (preferred — grok.com / SuperGrok)
  GROK_HOME       config dir (default: $HOME/.grok)
  XAI_API_KEY     console.x.ai API key; no file needed, but this is a *bill*, not the
                  subscription. Use only if GROK_AUTH_JSON is unavailable.

Never prints the secret. Exits 0 if some usable auth is present, 2 if none is.
"""
from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path


def grok_home() -> Path:
    return Path(os.environ.get("GROK_HOME") or os.path.join(os.environ.get("HOME", "/tmp"), ".grok"))


def has_auth() -> bool:
    if (os.environ.get("XAI_API_KEY") or "").strip():
        return True
    if (os.environ.get("GROK_AUTH_JSON") or "").strip():
        return True
    return (grok_home() / "auth.json").is_file() and (grok_home() / "auth.json").stat().st_size > 0


def _sessions(obj: dict) -> list[dict]:
    sessions: list[dict] = []
    marker_keys = ("refresh_token", "access_token", "expires_at", "create_time", "key")
    if any(k in obj for k in marker_keys):
        sessions.append(obj)
    for v in obj.values():
        if isinstance(v, dict) and any(k in v for k in marker_keys):
            sessions.append(v)
    return sessions


def session_stamp(obj: dict) -> str:
    """Best-effort recency: create_time, else expires_at. Empty if unknown."""
    stamps = []
    for s in _sessions(obj):
        t = s.get("create_time") or s.get("expires_at") or ""
        if t:
            stamps.append(str(t))
    return max(stamps) if stamps else ""


def has_refresh(obj: dict) -> bool:
    return any(bool(s.get("refresh_token")) for s in _sessions(obj))


def _load_json_file(path: Path) -> dict | None:
    try:
        parsed = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return parsed if isinstance(parsed, dict) else None


def hydrate() -> Path | None:
    blob = (os.environ.get("GROK_AUTH_JSON") or "").strip()
    if not blob:
        return None
    try:
        parsed = json.loads(blob)
    except json.JSONDecodeError as e:
        raise SystemExit(f"hydrate_grok_auth: GROK_AUTH_JSON is not valid JSON: {e}") from e
    if not isinstance(parsed, dict):
        raise SystemExit("hydrate_grok_auth: GROK_AUTH_JSON must be a JSON object (auth.json)")
    home = grok_home()
    home.mkdir(parents=True, exist_ok=True)
    path = home / "auth.json"
    existing = _load_json_file(path) if path.is_file() and path.stat().st_size > 0 else None
    if existing is not None and has_refresh(existing):
        disk_ts = session_stamp(existing)
        env_ts = session_stamp(parsed)
        # Keep a volume-resident refresh if it is at least as new as the env seed.
        # A newer GROK_AUTH_JSON (re-login) still wins.
        if disk_ts and (not env_ts or disk_ts >= env_ts):
            os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
            print("hydrate_grok_auth: keeping on-disk session (newer than GROK_AUTH_JSON)")
            return path
    path.write_text(json.dumps(parsed))
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    print("hydrate_grok_auth: wrote GROK_AUTH_JSON to disk")
    return path


def main() -> int:
    try:
        hydrate()
    except SystemExit as e:
        print(e, file=sys.stderr)
        return 2
    if not has_auth():
        print(
            "hydrate_grok_auth: no Grok credentials — set GROK_AUTH_JSON "
            "(from `grok login`, contents of ~/.grok/auth.json) or XAI_API_KEY",
            file=sys.stderr,
        )
        return 2
    print("hydrate_grok_auth: grok credentials present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
