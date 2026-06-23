#!/usr/bin/env python3
"""extract.py — pull the producer JSON payload out of a `claude -p --output-format json` run.

`claude -p --output-format json` wraps the model's answer in a result envelope under
`.result` (a string). The model is instructed to return ONLY a JSON object. We:
  1. Read the envelope, take .result.
  2. Strip any stray markdown fences / leading prose defensively.
  3. json.loads it, validate the top-level shape.
  4. Write opportunities.json (the payload).

Report rendering lives in report.py (re-runnable after verify.py stamps fields).

Usage: extract.py <raw.json> <out-opportunities.json>
"""
import json
import re
import sys
from pathlib import Path


def coerce_payload(result_text: str) -> dict:
    """Extract the first JSON object from the model's result string."""
    s = result_text.strip()
    if s.startswith("```"):  # strip fences if the model added them despite instructions
        s = re.sub(r"^```(?:json)?\s*", "", s)
        s = re.sub(r"\s*```$", "", s)
    try:
        return json.loads(s)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", s, re.DOTALL)  # fallback: outermost {...} block
        if not m:
            raise ValueError(f"no JSON object found in result (len={len(result_text)})")
        return json.loads(m.group(0))


def main(raw_path: str, out_json: str) -> int:
    raw = json.loads(Path(raw_path).read_text())
    if raw.get("is_error"):
        raise SystemExit(f"claude run errored: {raw.get('api_error_status')}")
    # Accept either shape: the `claude -p` envelope (payload under .result, as Opus
    # emits) OR the bare payload written straight to stdout (observed with Sonnet).
    # The producer must not depend on the model's stdout-envelope shape.
    if "opportunities" in raw and "producer" in raw:
        payload = raw
    else:
        payload = coerce_payload(raw.get("result", ""))
    for k in ("producer", "variant", "wire", "opportunities"):
        if k not in payload:
            raise SystemExit(f"payload missing required key '{k}'")
    Path(out_json).write_text(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract.py <raw.json> <out-opportunities.json>")
    sys.exit(main(*sys.argv[1:]))
