#!/usr/bin/env python3
"""derive_contract.py — heuristically derive contract criteria from a user request.

Reads env: REQUEST, CONTRACT_PATH.

The output is a starting point, not a finished contract. It's calibrated
against patterns extracted from real Claude Code sessions where the user had
to re-prompt — specifically, the patterns where a verb in the request maps to
a checkable criterion the implementer routinely dropped.
"""
from __future__ import annotations

import os
import re
import sys
import time
from pathlib import Path

try:
    import yaml
except ImportError:
    print("derive_contract.py: pyyaml missing — pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def die(msg: str) -> None:
    print(f"derive_contract.py: {msg}", file=sys.stderr)
    sys.exit(1)


# Verb → criteria map. Each entry generates one or more criteria placeholders.
# Triggered by case-insensitive substring match on the request.
VERB_PATTERNS: list[dict] = [
    # ── File generation / conversion ─────────────────────────────────
    {
        "trigger": r"\b(converte|converter|convert|transcreve|transcribe|copia|extrai|extract|migra|export)\b",
        "criteria": [
            {
                "id": "output-file-meaningful",
                "intent": "the generated file is non-trivially large (not empty/garbled)",
                "type": "command",
                "spec": {
                    "cmd": "test -s OUTPUT_PATH && [ \"$(wc -c < OUTPUT_PATH)\" -ge 500 ]",
                    "expect_exit": 0,
                },
                "severity": "critical",
            }
        ],
    },
    # ── UI / opens / launches ────────────────────────────────────────
    {
        "trigger": r"\b(abre|abrir|open|launch|inicia)\b",
        "criteria": [
            {
                "id": "ui-state-reached",
                "intent": "the target UI state was reached (app open AND on the requested screen/URL)",
                "type": "review",
                "spec": {
                    "rubric": (
                        "The implementer must show a verification step beyond `open -a X` — "
                        "either a screencapture + Read, an `osascript \"tell app X to get name of "
                        "every window\"`, or a navigation confirmation. Empty stdout from `open` "
                        "is NOT verification."
                    )
                },
                "severity": "critical",
            }
        ],
    },
    # ── Kill / terminate / cleanup ───────────────────────────────────
    # Anchored to imperative-only forms to avoid PT preposition false-positives
    # ("para" = preposition; the verb "para" requires an explicit subject context).
    {
        "trigger": r"\b(kill|mata|matar|terminate|encerra|pkill|killall|stop\s+(the|o|a|all)\s+\w+)\b",
        "criteria": [
            {
                "id": "process-actually-killed",
                "intent": "the target process is verifiably absent after the kill",
                "type": "command",
                "spec": {
                    "cmd": "pgrep -f 'TARGET_PROCESS_NAME' > /dev/null && echo still_running && exit 1 || exit 0",
                    "expect_exit": 0,
                },
                "severity": "critical",
            }
        ],
    },
    # ── Research / find ──────────────────────────────────────────────
    {
        "trigger": r"\b(procura|research|inteira-te|find|look up|investiga|search|searches)\b",
        "criteria": [
            {
                "id": "research-attempted-multiple",
                "intent": "at least two distinct retrieval methods were attempted",
                "type": "review",
                "spec": {
                    "rubric": (
                        "If the implementer reported 'I couldn't find X', the tool transcript MUST "
                        "show at least two distinct retrieval methods tried (e.g. WebFetch, WebSearch, "
                        "Playwright, paper-lookup, Gmail MCP, archive.org, Google site:). One attempt "
                        "then giving up is a failure."
                    )
                },
                "severity": "warning",
            }
        ],
    },
    # ── Open PR / push / publish ─────────────────────────────────────
    {
        "trigger": r"\b(pr|pull request|abre pr|push|publish|publica|deploy|deploys|merge)\b",
        "criteria": [
            {
                "id": "pr-or-push-verifiable",
                "intent": "the PR / push / deploy is independently observable (not just announced)",
                "type": "review",
                "spec": {
                    "rubric": (
                        "Look for evidence in the tool transcript: gh pr view shows the PR exists, "
                        "git log on origin shows the push, deploy URL returns 200. Bare `git push` "
                        "in the ledger with no verification is insufficient."
                    )
                },
                "severity": "critical",
            }
        ],
    },
    # ── Tests ────────────────────────────────────────────────────────
    {
        "trigger": r"\b(test|tests|testa|testar)\b",
        "criteria": [
            {
                "id": "tests-actually-run",
                "intent": "the test suite was actually executed and passed",
                "type": "review",
                "spec": {
                    "rubric": (
                        "There must be a Bash tool call running the project's test command "
                        "(npm test / pytest / cargo test / go test / make test) with exit code 0. "
                        "An assistant claim like '42/42 pass' without a tool call producing that "
                        "output is fabricated."
                    )
                },
                "severity": "critical",
            }
        ],
    },
    # ── Send email / draft ───────────────────────────────────────────
    {
        "trigger": r"\b(envia email|send email|escreve email|draft|rascunho)\b",
        "criteria": [
            {
                "id": "email-state-correct",
                "intent": "email is in the correct state (draft vs sent) per user intent",
                "type": "review",
                "spec": {
                    "rubric": (
                        "If the user asked for a draft: confirm the message is in Drafts, not Sent. "
                        "If the user asked to send: confirm the Gmail/Outlook tool returned a sent "
                        "confirmation, not just 'draft created'."
                    )
                },
                "severity": "critical",
            }
        ],
    },
]


# Hard-rule whitelist: requests that legitimately allow a permission stop.
# These criteria are emitted with a `note:` flag so the critic knows NOT to fail
# them for stopping to ask.
HARD_RULE_WHITELIST = re.compile(
    r"\b(delete\s+files?|elimina(r)?\s+ficheiros?|rm\s+-rf|send\s+email|envia(r)?\s+email|"
    r"share\s+doc|partilha(r)?\s+(doc|documento)|move\s+money|transfer(ência)?|trade|"
    r"force[- ]push|amend|--no-verify)\b",
    re.IGNORECASE,
)


def derive_criteria(request: str) -> list[dict]:
    criteria: list[dict] = []
    seen_ids: set[str] = set()
    for entry in VERB_PATTERNS:
        if re.search(entry["trigger"], request, flags=re.IGNORECASE):
            for c in entry["criteria"]:
                if c["id"] not in seen_ids:
                    criteria.append(dict(c))
                    seen_ids.add(c["id"])
    return criteria


def add_autonomy_criterion(request: str) -> dict | None:
    """Add a no-permission-stops criterion unless the request is in the hard-rule whitelist."""
    if HARD_RULE_WHITELIST.search(request):
        return None
    return {
        "id": "no-permission-stops",
        "intent": (
            "the implementer did not stop to ask permission on a reversible action — "
            "the only acceptable stops are hard-rule items (delete, send email, share doc, "
            "move money, force-push, amend, --no-verify)"
        ),
        "type": "review",
        "spec": {
            "rubric": (
                "Scan the implementer's final message for banned phrases: 'should I', "
                "'want me to', 'let me know if', 'diz-me se', 'queres que', 'se quiseres faço', "
                "'avanço com', 'posso seguir', 'prossigo', 'Mato?', 'Sigo?', 'Continuo?', "
                "'Duas opções'. If matched AND the next step is reversible, this criterion FAILS."
            )
        },
        "severity": "warning",
    }


def main() -> None:
    request = os.environ.get("REQUEST", "").strip()
    contract_path = os.environ.get("CONTRACT_PATH", "")
    if not request:
        die("missing REQUEST env var")
    if not contract_path:
        die("missing CONTRACT_PATH env var")

    criteria: list[dict] = []
    placeholder = {
        "id": "request-addressed",
        "intent": (
            "REFINE — every discrete user ask has a corresponding deliverable. Replace this "
            "with concrete existence/content/command criteria, one per ask."
        ),
        "type": "review",
        "spec": {
            "rubric": "Every numbered or comma-separated sub-ask in the request must have "
                      "concrete evidence (file change, command output, URL fetch)."
        },
        "severity": "critical",
    }
    criteria.append(placeholder)
    criteria.extend(derive_criteria(request))
    auto = add_autonomy_criterion(request)
    if auto:
        criteria.append(auto)

    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    contract = {
        "version": 1,
        "request": request,
        "created_at": now,
        "iteration": 1,
        "criteria": criteria,
    }
    Path(contract_path).write_text(
        yaml.safe_dump(contract, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )
    print(f"wrote {contract_path} with {len(criteria)} criterion/criteria", file=sys.stderr)


if __name__ == "__main__":
    main()
