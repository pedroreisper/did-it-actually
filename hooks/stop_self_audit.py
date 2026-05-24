#!/usr/bin/env python3
"""stop_self_audit.py — Stop hook that fires before Claude reports done.

Reads the Stop event payload (JSON on stdin per Claude Code hook spec), inspects
the last assistant message for completion signals, and if the session looks
multi-step, injects additionalContext telling Claude to run the did-it-actually
skill before terminating.

Wire this up via hooks/install_hook.sh — it appends a Stop matcher to
~/.claude/settings.json that calls this script.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

# Match completion signals only at sentence boundaries — avoids false-fires on
# phrases like "I'm done reading the file" mid-conversation. Requires the
# completion phrase to be near the end of the message, sentence-final, or
# accompanied by a check-mark glyph.
DONE_PATTERNS = re.compile(
    r"(?:"
    r"\b(?:all\s+done|all\s+set|task\s+complete|ready\s+to\s+ship|shipped|merged)\b"
    r"|\b(?:done|finished|complete|completo|pronto|feito)[.!]?\s*(?:$|\n)"
    r"|✅\s*(?:done|complete|completo|pronto|feito|ready|all\s+done)"
    r"|(?:^|\n)\s*✅\s*$"
    r")",
    re.IGNORECASE | re.MULTILINE,
)

MULTI_STEP_TOOL_THRESHOLD = 3
MULTI_STEP_FILE_THRESHOLD = 2


def load_event() -> dict:
    try:
        return json.load(sys.stdin)
    except Exception:
        return {}


def read_transcript(session_jsonl: str | None) -> list[dict]:
    if not session_jsonl or not os.path.exists(session_jsonl):
        return []
    lines = Path(session_jsonl).read_text(errors="replace").splitlines()
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def last_assistant_text(events: list[dict]) -> str:
    for evt in reversed(events):
        msg = evt.get("message", {})
        if msg.get("role") != "assistant":
            continue
        for c in msg.get("content", []) or []:
            if isinstance(c, dict) and c.get("type") == "text":
                return c.get("text", "")
    return ""


def session_metrics(events: list[dict]) -> dict:
    tool_calls = 0
    files: set[str] = set()
    for evt in events:
        msg = evt.get("message", {})
        for c in msg.get("content", []) or []:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use":
                tool_calls += 1
                inp = c.get("input", {}) or {}
                if "file_path" in inp:
                    files.add(inp["file_path"])
    return {"tool_calls": tool_calls, "file_count": len(files)}


def did_it_actually_already_ran(events: list[dict]) -> bool:
    """If the user (or a prior hook) already invoked the skill this turn, do not double-fire."""
    for evt in reversed(events[-20:]):
        msg = evt.get("message", {})
        for c in msg.get("content", []) or []:
            if isinstance(c, dict) and c.get("type") == "tool_use":
                inp = c.get("input", {}) or {}
                cmd = inp.get("command", "")
                if "audit.sh run" in cmd or "did-it-actually" in cmd:
                    return True
    return False


def main() -> None:
    event = load_event()
    session_jsonl = event.get("session_jsonl") or event.get("transcript_path")
    events = read_transcript(session_jsonl)
    text = last_assistant_text(events)

    if not DONE_PATTERNS.search(text):
        sys.exit(0)  # no completion signal; nothing to do

    metrics = session_metrics(events)
    if metrics["tool_calls"] < MULTI_STEP_TOOL_THRESHOLD and metrics["file_count"] < MULTI_STEP_FILE_THRESHOLD:
        sys.exit(0)  # trivial session; audit overhead not worth it

    if did_it_actually_already_ran(events):
        sys.exit(0)

    # Resolve the skill root so the reason message points at the real install path.
    skill_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    response = {
        "decision": "block",
        "reason": (
            f"did-it-actually: this turn touched {metrics['file_count']} file(s) over "
            f"{metrics['tool_calls']} tool call(s) and ended with a completion signal. "
            f"Before reporting done, run:\n\n"
            f"  bash {skill_root}/scripts/audit.sh init \"<original user request>\"   # if no contract yet\n"
            f"  bash {skill_root}/scripts/audit.sh run\n\n"
            f"Then iterate on any NOT VERIFIED findings (up to 3 times) and only emit "
            f"the final message once verdict is VERIFIED or VERIFIED WITH WARNINGS."
        ),
    }
    print(json.dumps(response))


if __name__ == "__main__":
    main()
