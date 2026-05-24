#!/usr/bin/env python3
"""scan_session.py — reconstruct the claim ledger from a Claude Code session JSONL.

When the user (or hook) didn't write claims.jsonl as work happened, this
script reads the session transcript and emits a best-effort ledger by
extracting Edit / Write / Bash tool calls and their results.

Usage:
  scan_session.py <session.jsonl> [--out .did-it-actually/claims.jsonl]
  scan_session.py --latest                      # auto-detect newest session
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time
from pathlib import Path


def find_latest_session() -> str | None:
    # Claude Code stores transcripts under ~/.claude/projects/<cwd-slug>/<id>.jsonl
    home = os.environ.get("HOME", "")
    pattern = os.path.join(home, ".claude", "projects", "*", "*.jsonl")
    matches = glob.glob(pattern)
    if not matches:
        return None
    return max(matches, key=os.path.getmtime)


def iter_tool_uses(path: str):
    # Stream line-by-line — Claude session JSONLs can be hundreds of MB.
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            for content in evt.get("message", {}).get("content", []) or []:
                if not isinstance(content, dict):
                    continue
                if content.get("type") in ("tool_use", "tool_result"):
                    yield evt, content


def reconstruct(session_path: str) -> list[dict]:
    rows: list[dict] = []
    pending_use: dict[str, dict] = {}
    for evt, c in iter_tool_uses(session_path):
        ctype = c.get("type")
        if ctype == "tool_use":
            tool = c.get("name", "")
            inp = c.get("input", {}) or {}
            ts = evt.get("timestamp") or time.strftime("%Y-%m-%dT%H:%M:%SZ")
            if tool in ("Edit", "Write", "MultiEdit") and "file_path" in inp:
                op = "edit" if tool != "Write" else "create"
                rows.append({
                    "ts": ts,
                    "op": op,
                    "path": inp["file_path"],
                    "source": f"reconstructed:{tool}",
                })
            elif tool == "Bash" and "command" in inp:
                pending_use[c.get("id", "")] = {
                    "ts": ts,
                    "cmd": inp["command"][:500],
                    "tool_use_id": c.get("id"),
                }
        elif ctype == "tool_result":
            ref = pending_use.pop(c.get("tool_use_id", ""), None)
            if ref:
                # tool_result may report exit code, but Claude Code's transcript
                # does not include it structurally; we record cmd only.
                rows.append({
                    "ts": ref["ts"],
                    "op": "cmd",
                    "cmd": ref["cmd"],
                    "source": "reconstructed:Bash",
                })
    return rows


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("session", nargs="?", help="path to session.jsonl")
    p.add_argument("--latest", action="store_true")
    p.add_argument("--out", default=".did-it-actually/claims.jsonl")
    args = p.parse_args()

    session = args.session
    if args.latest or not session:
        session = find_latest_session()
        if not session:
            sys.exit("no session JSONL found under ~/.claude/projects/")

    rows = reconstruct(session)
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    print(f"wrote {len(rows)} reconstructed claims to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
