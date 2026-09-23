#!/usr/bin/env python3
"""extract.py — pull the producer JSON payload out of a headless CLI JSON run.

`claude -p --output-format json` wraps the model's answer under `.result` (a string).
`grok -p --output-format json` wraps it under `.text` (plus sessionId / stopReason).
The model is instructed to return ONLY a JSON object. We:
  1. Read the envelope, take the result text (Claude `.result`, Grok `.text`, …).
  2. Strip any stray markdown fences / leading prose defensively.
  3. json.loads it, keep any recoverable opportunities.
  4. Stamp producer/variant/wire/run_id from the wrapper when the model omits them.
  5. Write opportunities.json (the payload).

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
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse


# Top-level keys a well-behaved model emits. Attribution (producer / variant /
# wire / run_id) is also known to the wrapper — a prompt miss must not abort
# a run that already has opportunities (2026-09-10 Grok Fri tick: rc=1,
# `payload missing required key 'producer'`, paid-for finds discarded).
REQUIRED_TOP_KEYS = ("producer", "variant", "wire", "opportunities")

# Required keys for an individual opportunity object (salvage acceptance test).
REQUIRED_ITEM_KEYS = (
    "name", "source_url", "wire", "amount", "deadline", "summary",
    "classification", "fit_score", "fit_reason", "evidence", "discovered_via",
)

# Top-level metadata keys we try to recover on salvage (all precede the array).
META_KEYS = ("producer", "variant", "wire", "generated_at", "run_id")

# Wrapper-known attribution. run-producer.sh exports these before extract.
_STAMP_ENV = {
    "producer": "SCOUT_PRODUCER",
    "variant": "SCOUT_VARIANT",
    "wire": "SCOUT_WIRE",
    "run_id": "SCOUT_RUN_ID",
}

# Headless envelopes: Claude uses `result`; Grok Build uses `text` (+ sessionId).
# Also accept a few aliases so a CLI rename doesn't drop a whole run.
_ENVELOPE_TEXT_KEYS = ("result", "text", "output", "message", "response", "content")

# Social / shortener hosts are LEADS, never source_url. The prompt already says this;
# Grok still emitted x.com status URLs in Aug 2026 and several were approved. Enforce
# it here so a prompt miss cannot land a tweet as the canonical source.
_LEAD_HOSTS = (
    "x.com", "twitter.com", "mobile.twitter.com", "t.co",
    "bsky.app", "linkedin.com", "lnkd.in",
)


def _source_host(url: str) -> str:
    try:
        host = (urlparse(str(url or "").strip()).hostname or "").lower()
    except Exception:
        return ""
    return host[4:] if host.startswith("www.") else host


def reject_lead_urls(payload: dict) -> dict:
    """Move social/shortener source_urls into rejected[]. Mutates and returns payload."""
    if not isinstance(payload, dict):
        return payload
    kept, rejected = [], list(payload.get("rejected") or [])
    moved = 0
    for o in payload.get("opportunities") or []:
        if not isinstance(o, dict):
            continue
        host = _source_host(o.get("source_url", ""))
        if host in _LEAD_HOSTS or any(host.endswith("." + h) for h in _LEAD_HOSTS):
            rejected.append({
                "name": o.get("name"),
                "source_url": o.get("source_url"),
                "classification": "NOISE",
                "reason": "social/shortener URL is a lead, not a canonical source_url",
            })
            moved += 1
        else:
            kept.append(o)
    payload["opportunities"] = kept
    payload["rejected"] = rejected
    if moved:
        print(f"[extract] moved {moved} social source_url(s) to rejected (leads, not canonical)",
              file=sys.stderr)
    return payload


def _is_payload(obj) -> bool:
    return isinstance(obj, dict) and "opportunities" in obj


def wrapper_metadata() -> dict:
    """Attribution the wrapper already knows. Model output is not the source of truth."""
    meta = {}
    for key, env_name in _STAMP_ENV.items():
        val = (os.environ.get(env_name) or "").strip()
        if val:
            meta[key] = val
    return meta


def stamp_metadata(payload: dict) -> dict:
    """Fill / override top-level attribution from wrapper env. Mutates a copy."""
    if not isinstance(payload, dict):
        return payload
    payload = dict(payload)
    meta = wrapper_metadata()
    stamped = []
    for key, val in meta.items():
        prev = payload.get(key)
        if prev != val:
            stamped.append(key if key not in payload else f"{key}({prev!r}->{val!r})")
        payload[key] = val
    if "generated_at" not in payload or not str(payload.get("generated_at") or "").strip():
        payload["generated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        stamped.append("generated_at")
    if stamped:
        print(f"[extract] stamped wrapper metadata: {', '.join(stamped)}", file=sys.stderr)
    missing = [k for k in ("producer", "variant", "wire") if k not in payload]
    if missing:
        print(
            f"[extract] payload still missing {', '.join(missing)} "
            f"(wrapper did not stamp; keeping opportunities)",
            file=sys.stderr,
        )
    return payload


def normalize_payload(obj) -> dict:
    """Coerce a parsed model object into a payload dict and stamp wrapper metadata.

    A missing top-level `producer` (or variant/wire/run_id) is not fatal — the
    wrapper stamps those. We only reject objects that are not a payload at all.
    """
    if isinstance(obj, list):
        obj = {"opportunities": obj}
    if not isinstance(obj, dict):
        raise ValueError(f"payload is not an object (got {type(obj).__name__})")
    obj = dict(obj)
    if "opportunities" not in obj:
        if "rejected" in obj or any(k in obj for k in META_KEYS):
            obj["opportunities"] = []
        else:
            raise ValueError("payload missing required key 'opportunities'")
    elif isinstance(obj["opportunities"], dict):
        obj["opportunities"] = [obj["opportunities"]]
    elif not isinstance(obj["opportunities"], list):
        raise ValueError("opportunities must be an array")
    return stamp_metadata(obj)


def split_envelope(raw: dict):
    """Return (payload_dict_or_None, result_text).

    Grok's JSON object is `{text, stopReason, sessionId, ...}`. Claude's is
    `{result, total_cost_usd, ...}`. Either CLI may also write the producer
    payload as the top-level object (no envelope) or nest it as a dict.

    A bare payload does not need `producer` — the wrapper stamps attribution.
    """
    if _is_payload(raw):
        return raw, ""
    for k in _ENVELOPE_TEXT_KEYS:
        v = raw.get(k)
        if _is_payload(v):
            return v, ""
        if isinstance(v, str) and v.strip():
            return None, v
    return None, ""


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
    return stamp_metadata(payload)


def main(raw_path: str, out_json: str) -> int:
    try:
        raw_text = Path(raw_path).read_text()
    except FileNotFoundError:
        raise SystemExit(f"raw file missing: {raw_path}")
    if not raw_text.strip():
        raise SystemExit(f"raw file empty: {raw_path}")
    try:
        raw = json.loads(raw_text)
    except json.JSONDecodeError:
        # The raw file ITSELF is malformed/truncated — happens with the bare-payload
        # shape (the model wrote the payload straight to stdout and it was cut off mid
        # output). Don't abort the whole run: salvage opportunities from the raw text.
        try:
            payload = reject_lead_urls(salvage_payload(raw_text))
        except ValueError as e:
            # A CLI error blob or prose, not JSON: fail with a one-line reason instead
            # of a traceback so the alert mail's tail stays readable.
            raise SystemExit(f"raw file is not JSON and {e}: {raw_path}") from e
        Path(out_json).write_text(json.dumps(payload, indent=2))
        return 0
    if raw.get("is_error"):
        raise SystemExit(
            f"producer run errored: {raw.get('api_error_status') or raw.get('stopReason') or raw.get('error')}"
        )
    # Accept either shape: a CLI envelope (Claude `.result`, Grok `.text`) OR the
    # bare payload written straight to stdout. The producer must not depend on
    # the model's stdout-envelope shape. Missing top-level attribution is
    # stamped from SCOUT_* env — never abort a parseable opportunities array.
    payload, result_text = split_envelope(raw)
    if payload is not None:
        payload = normalize_payload(payload)
    else:
        try:
            payload = normalize_payload(coerce_payload(result_text))
        except (json.JSONDecodeError, ValueError):
            # PARSE FAILURE: salvage per-item instead of aborting the whole run.
            # In the salvage path we do NOT enforce the top-level key check — a
            # missing top-level key must never throw away salvaged opportunities.
            try:
                payload = salvage_payload(result_text)
            except ValueError as e:
                raise SystemExit(f"producer result is not a payload and {e}") from e

    Path(out_json).write_text(json.dumps(reject_lead_urls(payload), indent=2))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract.py <raw.json> <out-opportunities.json>")
    sys.exit(main(*sys.argv[1:]))
