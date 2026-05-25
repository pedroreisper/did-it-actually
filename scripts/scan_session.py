#!/usr/bin/env python3
"""scan_session.py — sweep a Claude Code session JSONL for failure patterns.

Two modes:

1. **Ledger reconstruction** (default) — when claims.jsonl was not written
   during work, this script reads the session transcript and extracts
   Edit/Write/Bash tool calls as a best-effort ledger.

2. **Failure-pattern sweep** (--out) — surfaces banned-phrase permission
   asks in the last assistant message, swallowed-failure patterns in tool
   results, and visual-claim-without-evidence pairs. Emits a structured
   JSON with findings the audit can act on.

Calibrated against patterns extracted from real Claude Code sessions where
the user had to correct the assistant — see references/audit-checklist.md
"Specific failure-mode checks".

Usage:
  scan_session.py <session.jsonl> [--out claims.jsonl]
  scan_session.py --latest                            # auto-detect newest
  scan_session.py --latest --out findings.json        # failure-pattern sweep
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import time
from pathlib import Path


# ── Pattern banks calibrated against real failures ─────────────────────────

# Banned permission-ask phrases. Match against the LAST assistant message.
BANNED_PHRASE_PATTERNS = [
    (r"\bshould I\b", "should I"),
    (r"\bwant me to\b", "want me to"),
    (r"\blet me know if\b", "let me know if"),
    (r"\bdiz-me se\b", "diz-me se"),
    (r"\bqueres que\b", "queres que"),
    (r"\bse quiseres,? faço\b", "se quiseres faço"),
    (r"\bavanço com\b", "avanço com"),
    (r"\bposso seguir\b", "posso seguir"),
    (r"\bprossigo\b", "prossigo"),
    (r"\bmato\?", "Mato?"),
    (r"\bsigo\?", "Sigo?"),
    (r"\bcontinuo\?", "Continuo?"),
    (r"\bduas opções\s*:\s*\d", "Duas opções: 1... 2..."),
    (r"\bdo you want me to\b", "do you want me to"),
    (r"\blet me know\b.*\bif you want\b", "let me know if you want"),
]

# Hard-rule whitelist — these legitimately allow a permission stop.
HARD_RULE_WHITELIST_PATTERNS = [
    r"\bdelete\s+file", r"\beliminar?\s+ficheiro",
    r"\brm\s+-rf\b", r"\bsend\s+email", r"\benviar?\s+email",
    r"\bshare\s+doc", r"\bpartilhar?\s+(doc|documento)",
    r"\bmove\s+money", r"\btransferência",
    r"\btrade\b", r"\bforce[- ]push\b", r"\b--no-verify\b",
    r"\bamend\b",
]

# Soft-error patterns — Bash output that the agent should have addressed.
SOFT_ERROR_PATTERNS = [
    (r"\bTraceback\b", "Python traceback"),
    (r"\bSyntaxError:", "SyntaxError"),
    (r"^Error:", "Error: prefix"),
    (r"\bfatal:", "fatal:"),
    (r"\bexecution error:", "AppleScript execution error"),
    (r"\bpanic!", "panic!"),
    (r"HTTP/[12](\.\d)?\s+[45]\d\d", "HTTP 4xx/5xx"),
    (r"\b(400|401|403|404|429|500|502|503)\s+(Bad Request|Unauthorized|Forbidden|Not Found|Too Many|Internal|Bad Gateway|Service)", "HTTP error"),
    (r"\bconnection refused\b", "connection refused"),
    (r"\bNo such file or directory\b", "missing path"),
    (r"\bcommand not found\b", "command not found"),
    (r"\bpermission denied\b", "permission denied"),
    (r"AppleScript.*-1719\b", "AppleScript -1719"),
]

# Visual-claim phrases in assistant text that warrant downstream verification.
VISUAL_CLAIM_PATTERNS = [
    r"\baberto\b", r"\bopened\b", r"\bopen now\b", r"\blaunched\b",
    r"\bstarted\b", r"\bpronto\b", r"\bready\b", r"\bdone\b", r"\bfeito\b",
    r"\bcompleto\b", r"\bcompleta\b", r"\bshipped\b",
]

# GUI commands whose empty-stdout output is NOT proof of success.
GUI_COMMAND_PATTERNS = [
    r"^open\b", r"^open\s+-a\b",
    r"^osascript\s+-e\s+['\"]tell application",
    r"^caffeinate\b", r"^say\b",
    r"^/usr/bin/open\b",
]


# ── Session-transcript helpers ─────────────────────────────────────────────

def find_latest_session() -> str | None:
    home = os.environ.get("HOME", "")
    for sub in ("-Users-pedroreisper", "*"):
        pattern = os.path.join(home, ".claude", "projects", sub, "*.jsonl")
        matches = glob.glob(pattern)
        if matches:
            return max(matches, key=os.path.getmtime)
    return None


def iter_events(path: str):
    """Yield (event, content_block) pairs, streaming line-by-line."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            for content in evt.get("message", {}).get("content", []) or []:
                if isinstance(content, dict):
                    yield evt, content


def last_assistant_text(path: str) -> str:
    """Return the text of the most recent assistant message."""
    last = ""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = evt.get("message", {})
            if msg.get("role") != "assistant":
                continue
            for c in msg.get("content", []) or []:
                if isinstance(c, dict) and c.get("type") == "text":
                    last = c.get("text", "")
    return last


def first_user_text(path: str) -> str:
    """Return the text of the first user message — the original request."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = evt.get("message", {})
            if msg.get("role") != "user":
                continue
            for c in msg.get("content", []) or []:
                if isinstance(c, dict) and c.get("type") == "text":
                    return c.get("text", "")
                if isinstance(c, str):
                    return c
    return ""


# ── Failure-pattern sweep ──────────────────────────────────────────────────

def scan_banned_phrases(text: str) -> list[dict]:
    """Detect banned permission-ask phrases in the assistant's last message."""
    if not text:
        return []
    findings = []
    for pattern, label in BANNED_PHRASE_PATTERNS:
        m = re.search(pattern, text, flags=re.IGNORECASE)
        if m:
            findings.append({
                "check": "permission-stop-under-open-directive",
                "severity": "critical",
                "detail": f"banned phrase: {label!r} in last assistant message",
                "match": text[max(0, m.start() - 40):min(len(text), m.end() + 40)].strip(),
            })
    return findings


def scan_swallowed_failures(path: str) -> list[dict]:
    """Detect Bash tool results with error patterns the agent didn't address."""
    findings = []
    pending: dict[str, dict] = {}  # tool_use_id -> bash command
    history: list[dict] = []  # ordered list of (turn, kind, data)

    for evt, c in iter_events(path):
        ctype = c.get("type")
        if ctype == "tool_use" and c.get("name") == "Bash":
            inp = c.get("input", {}) or {}
            pending[c.get("id", "")] = {
                "cmd": inp.get("command", "")[:300],
                "ts": evt.get("timestamp", ""),
            }
        elif ctype == "tool_result":
            ref = pending.pop(c.get("tool_use_id", ""), None)
            output = c.get("content", "")
            if isinstance(output, list):
                output = " ".join(
                    b.get("text", "") if isinstance(b, dict) else str(b)
                    for b in output
                )[:2000]
            is_error = c.get("is_error", False)
            history.append({
                "kind": "bash_result",
                "cmd": ref["cmd"] if ref else "",
                "output": output,
                "is_error": is_error,
            })
        elif ctype == "text":
            history.append({"kind": "assistant_text", "text": c.get("text", "")[:1000]})

    # Scan history: each bash_result is followed by some assistant text. If the
    # output matches a soft-error pattern, check whether the next assistant
    # text addresses it. Heuristic: addressed if the next message references
    # the command name or any error keyword.
    for i, item in enumerate(history):
        if item["kind"] != "bash_result":
            continue
        output = item.get("output", "")
        cmd = item.get("cmd", "")
        # Soft-error scan
        for pattern, label in SOFT_ERROR_PATTERNS:
            if re.search(pattern, output, flags=re.IGNORECASE | re.MULTILINE):
                # Look ahead for acknowledgement in next 3 assistant messages
                addressed = False
                seen = 0
                for j in range(i + 1, len(history)):
                    if history[j]["kind"] == "assistant_text":
                        seen += 1
                        if re.search(
                            rf"({label.split()[0]}|fail|error|retry|fix|fall back|alternativa)",
                            history[j].get("text", ""),
                            flags=re.IGNORECASE,
                        ):
                            addressed = True
                            break
                        if seen >= 3:
                            break
                if not addressed:
                    findings.append({
                        "check": "swallowed-soft-error",
                        "severity": "warning",
                        "detail": f"unaddressed {label} after `{cmd[:80]}`",
                        "match": output[:300].strip(),
                    })

        # Empty-stdout-as-success on GUI commands
        if any(re.search(p, cmd, flags=re.MULTILINE) for p in GUI_COMMAND_PATTERNS):
            if not output.strip() and not item["is_error"]:
                # Did the next assistant message claim "opened/started" without verification?
                next_text = ""
                for j in range(i + 1, min(i + 3, len(history))):
                    if history[j]["kind"] == "assistant_text":
                        next_text = history[j].get("text", "")
                        break
                if any(re.search(p, next_text, flags=re.IGNORECASE) for p in VISUAL_CLAIM_PATTERNS):
                    # Verification required — look for screencapture/pgrep/osascript in
                    # the NEXT 5 history entries
                    verified = False
                    for j in range(i + 1, min(i + 10, len(history))):
                        if history[j]["kind"] == "bash_result":
                            vcmd = history[j].get("cmd", "")
                            if re.search(r"(screencapture|pgrep|osascript.*get name of every window)", vcmd):
                                verified = True
                                break
                    if not verified:
                        findings.append({
                            "check": "visual-claim-unverified",
                            "severity": "warning",
                            "detail": f"GUI cmd `{cmd[:80]}` returned empty; claim of success ({next_text[:80]!r}) has no screencapture/pgrep verification",
                        })
    return findings


def scan_session(path: str) -> dict:
    last_text = last_assistant_text(path)
    first_request = first_user_text(path)
    findings = []
    findings.extend(scan_banned_phrases(last_text))
    findings.extend(scan_swallowed_failures(path))
    return {
        "schema_version": "scan-v1",
        "scanned_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "session_file": path,
        "first_request_excerpt": first_request[:200],
        "last_assistant_excerpt": last_text[:200],
        "findings": findings,
        "summary": {
            "critical": sum(1 for f in findings if f.get("severity") == "critical"),
            "warning": sum(1 for f in findings if f.get("severity") == "warning"),
        },
    }


# ── Ledger reconstruction (existing behaviour) ─────────────────────────────

def reconstruct_ledger(path: str) -> list[dict]:
    rows: list[dict] = []
    pending: dict[str, dict] = {}
    for evt, c in iter_events(path):
        ctype = c.get("type")
        if ctype == "tool_use":
            tool = c.get("name", "")
            inp = c.get("input", {}) or {}
            ts = evt.get("timestamp") or time.strftime("%Y-%m-%dT%H:%M:%SZ")
            if tool in ("Edit", "Write", "MultiEdit") and "file_path" in inp:
                op = "edit" if tool != "Write" else "create"
                rows.append({"ts": ts, "op": op, "path": inp["file_path"], "source": f"reconstructed:{tool}"})
            elif tool == "Bash" and "command" in inp:
                pending[c.get("id", "")] = {"ts": ts, "cmd": inp["command"][:500]}
        elif ctype == "tool_result":
            ref = pending.pop(c.get("tool_use_id", ""), None)
            if ref:
                rows.append({"ts": ref["ts"], "op": "cmd", "cmd": ref["cmd"], "source": "reconstructed:Bash"})
    return rows


# ── Entry point ────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("session", nargs="?", help="path to session.jsonl")
    p.add_argument("--latest", action="store_true")
    p.add_argument("--out", help="output path. If ends in .json, do failure-sweep; else ledger reconstruction.")
    args = p.parse_args()

    session = args.session
    if args.latest or not session:
        session = find_latest_session()
        if not session:
            sys.exit("no session JSONL found under ~/.claude/projects/")

    out_path = args.out or ".did-it-actually/claims.jsonl"
    if out_path.endswith(".json"):
        # Failure-pattern sweep
        result = scan_session(session)
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        Path(out_path).write_text(json.dumps(result, indent=2), encoding="utf-8")
        print(f"scanned {session} → {out_path} ({len(result['findings'])} finding(s))", file=sys.stderr)
    else:
        # Ledger reconstruction (existing behaviour)
        rows = reconstruct_ledger(session)
        Path(out_path).parent.mkdir(parents=True, exist_ok=True)
        with Path(out_path).open("w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
        print(f"wrote {len(rows)} reconstructed claims to {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
