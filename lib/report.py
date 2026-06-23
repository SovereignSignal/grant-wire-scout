#!/usr/bin/env python3
"""report.py — render the human-readable run report from (possibly verified) opportunities.json.

Re-renderable: called after verify.py stamps `verified`/`source_snippet`/`verification`,
so the report shows per-item verification status. Falls back gracefully if those fields
are absent (pre-verification).

Usage: report.py <opportunities.json> <out-report.md> <raw.json>
"""
import json
import sys
from pathlib import Path


def main(opp_path: str, out_report: str, raw_path: str) -> int:
    payload = json.loads(Path(opp_path).read_text())
    raw = json.loads(Path(raw_path).read_text()) if Path(raw_path).exists() else {}
    opps = payload.get("opportunities", [])
    rej = payload.get("rejected", [])
    wire = payload.get("wire", "?")
    variant = payload.get("variant", "?")

    verified = [o for o in opps if o.get("verified") is True]
    partial = [o for o in opps if o.get("verification", {}).get("status") == "partial"]
    unverified = [o for o in opps if o.get("verification", {}).get("status") in ("unverified", "fetch_failed")]
    has_vf = any("verification" in o for o in opps)

    lines = [
        f"# Claude Code Producer — {wire} / variant {variant}",
        "",
        f"- Run: `{payload.get('run_id', '?')}`",
        f"- Generated: {payload.get('generated_at', '?')}",
        f"- Opportunities: **{len(opps)}**  ·  Rejected: {len(rej)}",
    ]
    if has_vf:
        lines.append(
            f"- Source-verified: **{len(verified)}** verified · "
            f"{len(partial)} partial · {len(unverified)} unverified/failed"
        )
    if opps:
        scores = [o.get("fit_score", 0) for o in opps if isinstance(o.get("fit_score"), (int, float))]
        if scores:
            lines.append(f"- Avg fit score: {round(sum(scores) / len(scores))}")
    if raw.get("total_cost_usd") is not None:
        lines.append(f"- Cost-equiv: ${raw['total_cost_usd']:.4f} (subscription quota, not a bill)")
    lines.append("")

    if opps:
        lines.append("## Opportunities")
        for o in opps:
            vf = o.get("verification", {})
            status = vf.get("status")
            tag = {"verified": "✅", "partial": "🟡", "unverified": "❓", "fetch_failed": "⚠️"}.get(status, "")
            lines.append(
                f"- {tag} **{o.get('name','?')}** — {o.get('wire','?')}, "
                f"fit {o.get('fit_score','?')}, {o.get('amount','?')}, "
                f"deadline {o.get('deadline','?')}"
            )
            lines.append(f"  - {o.get('source_url','')}")
            lines.append(f"  - {o.get('summary','')}")
            if o.get("source_snippet"):
                lines.append(f"  - _source: {o['source_snippet']}_")
            elif status and status != "verified":
                miss = vf.get("missing", [])[:5]
                if miss:
                    lines.append(f"  - _unmatched claims: {', '.join(miss)}_")
    else:
        lines.append("## Opportunities\n(none passed the currency gate)")

    if rej:
        lines.append("\n## Rejected")
        for r in rej[:25]:
            lines.append(f"- [{r.get('classification','?')}] {r.get('name','?')} — {r.get('reason','')}")

    Path(out_report).write_text("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: report.py <opportunities.json> <out-report.md> <raw.json>")
    sys.exit(main(*sys.argv[1:]))
