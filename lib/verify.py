#!/usr/bin/env python3
"""verify.py — make each producer run self-proving.

After the model emits opportunities, this re-fetches every source_url and checks that
the claimed facts (program name tokens, amount, deadline) actually appear on the page.
It stamps each opportunity with:
  - verified: bool            (did the page support the key claims?)
  - source_snippet: str        (the supporting text, ~first matched window)
  - verification: {            (full breakdown for auditing)
      status: "verified" | "partial" | "unverified" | "fetch_failed",
      matched: [claim tokens found on the page],
      missing: [claim tokens NOT found],
      fetched_at, http_status, content_len }

This closes two gaps from validation:
  1. The `server_tool_use` counter reads 0 even for real web use, so it can't drive
     observability. verify.py gives a real, per-item verification signal instead.
  2. Source-verification should capture WHAT was on the page (a snippet), not just
     confirm the URL resolves — so a model-gloss number (e.g. "$50M announced Feb")
     is distinguishable from a page-verbatim figure.

Usage: verify.py <opportunities.json> [--timeout 15] [--delay 1.0]
"""
import argparse
import datetime
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

UA = "Mozilla/5.0 (grant-wire-scout/verify; +contact: sov@sovereignsignal.com)"


def normalize_text(s: str) -> str:
    """Lowercase, collapse whitespace, strip tags, unescape entities."""
    import html
    s = re.sub(r"<[^>]+>", " ", s)
    s = html.unescape(s)
    return re.sub(r"\s+", " ", s).lower()


def fetch(url: str, timeout: int) -> tuple[int, str]:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read(2_000_000).decode("utf-8", errors="replace")  # cap at 2MB/page
        return r.status, normalize_text(body)


def claim_tokens(opp: dict) -> dict:
    """Extract concrete, checkable claims from an opportunity."""
    name = str(opp.get("name") or "")
    amount = str(opp.get("amount") or "")
    deadline = str(opp.get("deadline") or "")
    summary = str(opp.get("summary") or "")

    # Name tokens: distinctive words from the program name (skip generic words)
    STOP = {
        "grant", "grants", "program", "programme", "foundation", "the", "and",
        "for", "of", "community", "fund", "funding", "award", "awards", "open",
        "round", "build", "developer", "developers", "research", "ecosystem",
        "network", "new", "2026", "application", "applications",
    }
    name_words = [w for w in re.findall(r"[a-z0-9]+", name.lower()) if w not in STOP and len(w) > 2]

    # Amount: pull out bare numbers + currency figures ($X, Xk, Xm, X,000)
    amount_nums = []
    seen_val = set()
    for m in re.finditer(r"\$\s?(\d[\d,]*(?:\.\d+)?)\s?(k|m|million|b|billion)?", amount + " " + summary, re.I):
        # only trust DOLLAR-prefixed amounts; bare token counts (e.g. "150K in XLM")
        # inflate into nonsense and pollute `missing`.
        num = m.group(1).replace(",", "")
        unit = (m.group(2) or "").lower()
        try:
            val = float(num)
            if unit in ("m", "million"): val *= 1_000_000
            elif unit in ("k",): val *= 1_000
            elif unit in ("b", "billion"): val *= 1_000_000_000
            if val in seen_val or val < 1000:  # skip tiny/junk + dupes
                continue
            seen_val.add(val)
            amount_nums.append(f"{int(val):,}")
            amount_nums.append(str(int(val)))
        except ValueError:
            pass
    for m in re.finditer(r"\$\d[\d,]*", amount + " " + summary):
        amount_nums.append(m.group(0))

    # Deadline: a YYYY-MM-DD, or month-name + day. Skip bare 4-digit years.
    deadline_tokens = []
    if re.match(r"\d{4}-\d{2}-\d{2}", deadline):
        deadline_tokens.append(deadline)  # exact
        try:
            d = datetime.date.fromisoformat(deadline[:10])
            deadline_tokens.append(d.strftime("%B %d").replace(" 0", " ").lower())  # "july 26"
            deadline_tokens.append(d.strftime("%B %-d").lower())
        except ValueError:
            pass
    for m in re.finditer(r"(january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{1,2}", summary.lower()):
        deadline_tokens.append(m.group(0))

    return {
        "name_words": name_words[:6],          # distinctive name tokens
        "amounts": list(dict.fromkeys(amount_nums))[:4],  # dedup, keep few
        "deadlines": list(dict.fromkeys(deadline_tokens))[:3],
    }


def find_snippet(page: str, needles: list, window: int = 90):
    for n in needles:
        i = page.find(n.lower())
        if i >= 0:
            start = max(0, i - window // 2)
            end = min(len(page), i + len(n) + window // 2)
            return "…" + page[start:end].strip() + "…"
    return None


def verify_one(opp: dict, timeout: int) -> dict:
    url = str(opp.get("source_url") or "")
    claims = claim_tokens(opp)
    result = {
        "status": "fetch_failed", "matched": [], "missing": [],
        "fetched_at": datetime.datetime.utcnow().isoformat() + "Z",
        "http_status": None, "content_len": 0, "claims": claims,
    }
    if not url:
        result["status"] = "fetch_failed"
        opp.update(verified=False, source_snippet=None, verification=result)
        return opp

    try:
        status, page = fetch(url, timeout)
    except urllib.error.HTTPError as e:
        result["http_status"] = e.code
        opp.update(verified=False, source_snippet=None, verification=result)
        return opp
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        result["missing"] = ["fetch_failed:" + type(e).__name__]
        opp.update(verified=False, source_snippet=None, verification=result)
        return opp

    result["http_status"] = status
    result["content_len"] = len(page)

    # Check each claim category. Name words are the strongest signal (program identity).
    name_hits = [w for w in claims["name_words"] if w in page]
    amount_hits = [a for a in claims["amounts"] if a.lower() in page]
    deadline_hits = [d for d in claims["deadlines"] if d.lower() in page]

    result["matched"] = sorted(set(name_hits + amount_hits + deadline_hits))
    result["missing"] = sorted(
        set(claims["name_words"] + claims["amounts"] + claims["deadlines"]) - set(result["matched"])
    )

    # Identity gate: at least ~half the distinctive name tokens must hit.
    name_ok = len(name_hits) >= max(1, len(claims["name_words"]) // 2) if claims["name_words"] else True
    # Fact corroboration: amount OR deadline should appear (rolling/no-amount items exempt).
    fact_ok = bool(amount_hits or deadline_hits) or (
        str(opp.get("amount") or "").lower() in ("not specified", "rolling", "unknown", "")
    )

    if name_ok and fact_ok:
        result["status"] = "verified"
        snippet = find_snippet(page, name_hits or amount_hits or deadline_hits)
    elif name_ok:
        result["status"] = "partial"
        snippet = find_snippet(page, name_hits)
    else:
        result["status"] = "unverified"
        snippet = None

    opp.update(verified=(result["status"] == "verified"), source_snippet=snippet, verification=result)
    return opp


def main(opp_path: str, timeout: int, delay: float) -> int:
    payload = json.loads(Path(opp_path).read_text())
    opps = payload.get("opportunities", [])
    counts = {"verified": 0, "partial": 0, "unverified": 0, "fetch_failed": 0}
    for o in opps:
        try:
            verify_one(o, timeout)
        except Exception as e:
            o.update(verified=False, source_snippet=None, verification={
                "status": "fetch_failed", "error": type(e).__name__,
                "matched": [], "missing": [],
                "fetched_at": datetime.datetime.utcnow().isoformat() + "Z",
                "http_status": None, "content_len": 0,
            })
        counts[o["verification"]["status"]] = counts.get(o["verification"]["status"], 0) + 1
        time.sleep(delay)  # be polite
    Path(opp_path).write_text(json.dumps(payload, indent=2))

    n = len(opps) or 1
    print(
        f"[verify] {len(opps)} items → "
        f"verified={counts.get('verified',0)} "
        f"partial={counts.get('partial',0)} "
        f"unverified={counts.get('unverified',0)} "
        f"fetch_failed={counts.get('fetch_failed',0)}"
    )
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("opportunities_json")
    ap.add_argument("--timeout", type=int, default=15)
    ap.add_argument("--delay", type=float, default=1.0)
    args = ap.parse_args()
    sys.exit(main(args.opportunities_json, args.timeout, args.delay))
