#!/usr/bin/env python3
"""snapshot.py — utilities for comparing pre/post snapshots."""
from __future__ import annotations

import json
import sys
from pathlib import Path


def cmd_diff(pre_path: str) -> None:
    """Print files whose sha or mtime changed since the pre snapshot."""
    pre = json.loads(Path(pre_path).read_text())
    pre_files = pre.get("files", {})
    changed: list[str] = []
    import os, hashlib

    for path, meta in pre_files.items():
        if not os.path.exists(path):
            changed.append(path)
            continue
        st = os.stat(path)
        if st.st_size != meta.get("size") or int(st.st_mtime) != meta.get("mtime"):
            changed.append(path)
    # also include newly-created files in cwd that weren't in pre
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs if d not in {".git", "node_modules", "__pycache__", ".did-it-actually", ".venv"}]
        for f in files:
            rel = os.path.relpath(os.path.join(root, f))
            if rel not in pre_files:
                changed.append(rel)
    for c in sorted(set(changed)):
        print(c)


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: snapshot.py diff <pre.json>")
    if sys.argv[1] == "diff":
        cmd_diff(sys.argv[2])
    else:
        sys.exit(f"unknown subcommand: {sys.argv[1]}")


if __name__ == "__main__":
    main()
