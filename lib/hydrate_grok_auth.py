#!/usr/bin/env python3
"""hydrate_grok_auth.py — materialize Grok Build credentials for a headless run.

Grok Build reads `~/.grok/auth.json` (override with GROK_HOME) from `grok login`,
or falls back to `XAI_API_KEY`. Railway has no volume, so the subscription session
is passed the same way Claude's is: a long-lived blob in an env var, written to
disk just before `grok -p`.

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
    path.write_text(json.dumps(parsed))
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
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
