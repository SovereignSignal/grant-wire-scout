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
from datetime import datetime, timezone
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


def _stamp(obj: dict, key: str) -> str:
    stamps = [str(s[key]) for s in _sessions(obj) if s.get(key)]
    return max(stamps) if stamps else ""


def session_stamp(obj: dict, key: str | None = None) -> str:
    """Best-effort recency: create_time, else expires_at. Empty if unknown.

    Pass `key` to read one field only; newer_or_same() uses that to compare the
    on-disk and env sessions on the SAME field, never create_time against expires_at.
    """
    if key:
        return _stamp(obj, key)
    return _stamp(obj, "create_time") or _stamp(obj, "expires_at")


def newer_or_same(disk: dict, env: dict) -> bool | None:
    """Is the on-disk session at least as new as the env seed?

    Compares create_time with create_time, else expires_at with expires_at — the
    CLI's refresh rewrites expires_at but not create_time, and a raw string compare
    of one field against the other says nothing. None when neither side has a stamp.
    """
    for key in ("create_time", "expires_at"):
        d, e = _stamp(disk, key), _stamp(env, key)
        if d and e:
            return d >= e
    d, e = session_stamp(disk), session_stamp(env)
    if d and not e:
        return True
    if e and not d:
        return False
    return None


def _parse_ts(value: str) -> datetime | None:
    raw = str(value or "").strip()
    if not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        try:
            dt = datetime.fromtimestamp(float(raw), tz=timezone.utc)
        except (ValueError, OverflowError, OSError):
            return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def describe_expiry(obj: dict, label: str) -> str:
    """One log line about the session's access-token expiry. Never prints the token.

    The alert mail is often the only record of a tick; when the run hangs or AUTH-fails
    this line says whether the CLI had a live token or had to refresh one first.
    """
    exp = _parse_ts(_stamp(obj, "expires_at"))
    if exp is None:
        return f"hydrate_grok_auth: {label} session has no readable expires_at"
    delta = exp - datetime.now(timezone.utc)
    hours = abs(delta.total_seconds()) / 3600
    refresh = "has a refresh_token" if has_refresh(obj) else "has NO refresh_token"
    if delta.total_seconds() < 0:
        return (f"hydrate_grok_auth: {label} session access token EXPIRED {hours:.1f}h ago "
                f"({exp.isoformat()}); the CLI must refresh it before the run — {refresh}")
    return (f"hydrate_grok_auth: {label} session access token valid for {hours:.1f}h "
            f"({exp.isoformat()}) — {refresh}")


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
        # Keep a volume-resident refresh if it is at least as new as the env seed.
        # A newer GROK_AUTH_JSON (re-login) still wins.
        if newer_or_same(existing, parsed):
            os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
            print("hydrate_grok_auth: keeping on-disk session (newer than GROK_AUTH_JSON)")
            print(describe_expiry(existing, "on-disk"))
            return path
    path.write_text(json.dumps(parsed))
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
    print("hydrate_grok_auth: wrote GROK_AUTH_JSON to disk")
    print(describe_expiry(parsed, "GROK_AUTH_JSON"))
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
