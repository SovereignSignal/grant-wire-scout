#!/usr/bin/env python3
"""extract.py — pull the producer JSON payload out of a `claude -p --output-format json` run.

`claude -p --output-format json` wraps the model's answer in a result envelope under
`.result` (a string). The model is instructed to return ONLY a JSON object. We:
  1. Read the envelope, take .result.
  2. Strip any stray markdown fences / leading prose defensively.
  3. json.loads it, validate the top-level shape.
  4. Write opportunities.json (the payload).

RESILIENCE (C1): a single truncated/malformed token must NOT lose an entire run's
finds. If the whole-payload parse fails (output-token ceiling hit mid-array, a
malformed field, trailing prose, etc.) we SALVAGE instead of aborting: recover the
top-level metadata (which precedes the array and survives a mid-array truncation)
and recover every COMPLETE, balanced opportunity object we can brace-match out of
the "opportunities" array — dropping only the malformed/incomplete trailing item(s).
We only fail the run when nothing at all is recoverable.

Report rendering lives in report.py (re-runnable after verify.py stamps fields).

Usage: extract.py <raw.json> <out-opportunities.json>
"""
import json
import re
import sys
from pathlib import Path


# Required keys for a top-level payload (happy-path validation).
REQUIRED_TOP_KEYS = ("producer", "variant", "wire", "opportunities")

# Required keys for an individual opportunity object (salvage acceptance test).
REQUIRED_ITEM_KEYS = (
    "name", "source_url", "wire", "amount", "deadline", "summary",
    "classification", "fit_score", "fit_reason", "evidence", "discovered_via",
)

# Top-level metadata keys we try to recover on salvage (all precede the array).
META_KEYS = ("producer", "variant", "wire", "generated_at", "run_id")


def _loads(text: str) -> dict:
    """json.loads with the defensive scrubs models keep tripping on.

    Models sometimes abbreviate with standalone `...` lines or leave a trailing
    comma; strip both so one stray ellipsis doesn't lose the whole run.
    """
    text = re.sub(r"(?m)^\s*\.\.\.\s*,?\s*$", "", text)   # drop standalone ellipsis lines
    text = re.sub(r",(\s*[}\]])", r"\1", text)            # drop trailing commas
    return json.loads(text)


def _strip_fences(result_text: str) -> str:
    """Defensively strip markdown fences the model may have added despite instructions."""
    s = result_text.strip()
    if s.startswith("```"):
        s = re.sub(r"^```(?:json)?\s*", "", s)
        s = re.sub(r"\s*```$", "", s)
    return s


def coerce_payload(result_text: str) -> dict:
    """Extract the first JSON object from the model's result string (HAPPY PATH)."""
    s = _strip_fences(result_text)
    try:
        return _loads(s)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", s, re.DOTALL)  # fallback: outermost {...} block
        if not m:
            raise ValueError(f"no JSON object found in result (len={len(result_text)})")
        return _loads(m.group(0))


def _find_balanced_objects(text: str) -> list:
    """Yield each BALANCED top-level {...} object found in `text`.

    Brace-matching that correctly ignores braces inside JSON strings (respecting
    \\" escapes). An unterminated trailing object (truncation) is simply never
    closed and therefore never emitted — which is exactly what we want.
    """
    objects = []
    depth = 0
    start = None
    in_str = False
    esc = False
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start is not None:
                    objects.append(text[start:i + 1])
                    start = None
    return objects


def _recover_metadata(s: str) -> dict:
    """Recover top-level metadata that precedes the "opportunities" array."""
    opp_idx = s.find('"opportunities"')
    head = s[:opp_idx] if opp_idx != -1 else s

    # Best effort: treat the object head as a (truncated) object and close it.
    candidate = head.rstrip()
    candidate = candidate.rstrip(",").rstrip()
    if not candidate.endswith("}"):
        candidate = candidate + "}"
    try:
        parsed = _loads(candidate)
        if isinstance(parsed, dict):
            return {k: v for k, v in parsed.items() if k != "opportunities"}
    except Exception:
        pass

    # Fallback: targeted extraction of known scalar metadata keys.
    meta = {}
    for key in META_KEYS:
        m = re.search(r'"%s"\s*:\s*"([^"]*)"' % re.escape(key), head)
        if m:
            meta[key] = m.group(1)
    return meta


def salvage_payload(result_text: str) -> dict:
    """Recover metadata + as many complete opportunity objects as possible.

    Raises ValueError only if NOTHING is recoverable (no opportunities AND no
    usable metadata) — never drops salvaged opportunities over missing metadata.
    """
    s = _strip_fences(result_text)
    meta = _recover_metadata(s)

    salvaged = []
    dropped = 0
    opp_idx = s.find('"opportunities"')
    if opp_idx != -1:
        bracket = s.find("[", opp_idx)
        if bracket != -1:
            array_text = s[bracket + 1:]
            for cand in _find_balanced_objects(array_text):
                try:
                    obj = _loads(cand)
                except Exception:
                    dropped += 1
                    continue
                if isinstance(obj, dict) and all(k in obj for k in REQUIRED_ITEM_KEYS):
                    salvaged.append(obj)
                else:
                    dropped += 1

    if not salvaged and not meta:
        raise ValueError(
            f"nothing recoverable from result (len={len(result_text)})"
        )

    payload = dict(meta)
    payload["opportunities"] = salvaged

    print(
        f"[extract] SALVAGED {len(salvaged)} opportunities, "
        f"dropped {dropped} malformed (payload was truncated/invalid)",
        file=sys.stderr,
    )
    return payload


def main(raw_path: str, out_json: str) -> int:
    raw = json.loads(Path(raw_path).read_text())
    if raw.get("is_error"):
        raise SystemExit(f"claude run errored: {raw.get('api_error_status')}")
    # Accept either shape: the `claude -p` envelope (payload under .result, as Opus
    # emits) OR the bare payload written straight to stdout (observed with Sonnet).
    # The producer must not depend on the model's stdout-envelope shape.
    if "opportunities" in raw and "producer" in raw:
        payload = raw
        # HAPPY PATH (bare payload): keep the required-top-level-key check.
        for k in REQUIRED_TOP_KEYS:
            if k not in payload:
                raise SystemExit(f"payload missing required key '{k}'")
    else:
        result_text = raw.get("result", "")
        try:
            payload = coerce_payload(result_text)
            # HAPPY PATH: keep the required-top-level-key check.
            for k in REQUIRED_TOP_KEYS:
                if k not in payload:
                    raise SystemExit(f"payload missing required key '{k}'")
        except (json.JSONDecodeError, ValueError):
            # PARSE FAILURE: salvage per-item instead of aborting the whole run.
            # In the salvage path we do NOT enforce the top-level key check — a
            # missing top-level key must never throw away salvaged opportunities.
            payload = salvage_payload(result_text)

    Path(out_json).write_text(json.dumps(payload, indent=2))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract.py <raw.json> <out-opportunities.json>")
    sys.exit(main(*sys.argv[1:]))
