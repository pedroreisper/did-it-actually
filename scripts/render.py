#!/usr/bin/env python3
"""Render the prose verdict box from report.json."""
from __future__ import annotations

import json
import sys
from pathlib import Path

GLYPH = {"PASS": "✅", "FAIL": "❌", "SKIP": "⚠️ ", "ERROR": "❌"}
LINE = "─" * 53


def main(report_path: str) -> None:
    r = json.loads(Path(report_path).read_text(encoding="utf-8"))
    excerpt = r.get("request_excerpt", "").strip().replace("\n", " ")
    if len(excerpt) > 80:
        excerpt = excerpt[:77] + "..."

    out = []
    out.append("SELF-AUDIT REPORT")
    out.append(LINE)
    out.append(f"Session:    {excerpt}")
    out.append(f"Started:    {r.get('started_at','?')}")
    out.append(f"Iteration:  {r.get('iteration','?')}/3"
               + (" — CAPPED" if r.get("iteration_capped") else ""))
    out.append(f"Audit ID:   {r.get('audit_id','?')}")
    scope = r.get("scope", {})
    out.append(f"Scope:      {len(scope.get('claimed_files', []))} claimed,"
               f" {len(scope.get('diffed_files', []))} diffed")
    out.append(f"Mode:       {r.get('session_meta', {}).get('mode', '?')}")
    out.append("")

    def block(label: str, rows: list[tuple[str, str, str]]) -> None:
        out.append(label)
        if not rows:
            out.append("  (none)")
        else:
            for _status, name, evidence in rows:
                ev = f" — {evidence}" if evidence else ""
                out.append(f"  • {name:<28} {ev}".rstrip())
        out.append("")

    verified, warnings, broken = [], [], []
    for cr in r.get("criteria_results", []):
        row = (cr["status"], cr["id"], cr.get("evidence", ""))
        if cr["status"] == "PASS":
            verified.append(row)
        elif cr["status"] == "SKIP":
            warnings.append(row)
        else:
            broken.append(row)
    for ck in r.get("checks_results", []):
        if ck["status"] == "PASS":
            verified.append(("PASS", ck["check_id"], "clean"))
        elif ck["status"] == "FAIL":
            n = len(ck.get("findings", []))
            sample = ck.get("findings", [{}])[0]
            evidence = f"{n} match(es); e.g. {sample.get('file','?')}:{sample.get('line','?')}"
            (warnings if ck.get("severity") == "warning" else broken).append(
                (ck["status"], ck["check_id"], evidence)
            )
        elif ck["status"] == "SKIP":
            warnings.append((ck["status"], ck["check_id"], "skipped"))
        else:
            broken.append((ck["status"], ck["check_id"], ck.get("error_message", "")))

    for phantom in scope.get("out_of_scope", []):
        broken.append(("FAIL", "phantom-edit", phantom))

    block("✅ VERIFIED", verified)
    block("⚠️  NEEDS ATTENTION", warnings)
    block("❌ BROKEN CLAIMS", broken)

    out.append(LINE)
    out.append("FOLLOW-UP ACTIONS (priority order)")
    follow_ups = r.get("follow_ups", [])
    if not follow_ups:
        out.append("  (none)")
    else:
        for i, fu in enumerate(follow_ups, 1):
            tag = fu["priority"]
            out.append(f"  {i}. [{tag}] {fu['verb']} {fu['object']} — {fu['reason']}")
    out.append("")
    out.append(LINE)
    out.append(f"VERDICT: {r['verdict']}")
    out.append(f"        {r.get('verdict_reason', '').strip()}")
    print("\n".join(out))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: render.py <report.json>")
    main(sys.argv[1])
