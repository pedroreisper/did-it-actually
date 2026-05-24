---
name: did-it-actually
description: Verifies Claude's own work against the user's request before reporting done. Catches dropped sub-asks, stub bodies, premature "done", phantom edits. Use when the user has had to repeat themselves, when a task touched multiple files, or before any "done/completo/ready/shipped/pronto/feito" emission on multi-step work. Triggers — "did it actually", "is it really done", "are you sure", "audita-te", "verifica", "está mesmo feito", "self-audit", "did you test it", "confirma", "check your work". NOT a code reviewer (that's /code-review) — only verifies request fidelity.
license: MIT
metadata:
  version: "1.0.0"
  priority: "8"
  audience: "claude-code"
---

# did-it-actually — close the loop between request and reality

You finished a task. You're about to type "done". **Don't.** Run this skill first.

The cost of one self-audit is ~30 seconds and a handful of tool calls. The cost of the user discovering the gap is one wasted reply cycle. The cost of three wasted cycles is the user no longer trusting any "done" you ever emit.

This skill is the closed loop: capture what was asked → check what shipped → if there's a gap, fix it without being told → re-check → only then report done.

## Core architecture

Four artefacts, in order:

1. **`.did-it-actually/contract.yml`** — the original request decomposed into acceptance criteria, each individually checkable. Written at the START of the work, or reconstructed at audit time. See `references/contract-format.md`.
2. **`.did-it-actually/claims.jsonl`** — append-only ledger of every claim you made (`{op, path, sha_before, sha_after, cmd, exit_code}`). Written as you work, not reconstructed from memory. See `scripts/scan_session.py` for reconstruction when the ledger is missing.
3. **`.did-it-actually/report.json`** — structured audit outcome. Schema in `references/output-schema.json`. The prose verdict box is a *view* of this file.
4. **A fresh-context critic sub-agent** — spawned via the Task tool with `general-purpose` subagent_type. Receives ONLY the contract, the claims ledger, and `git diff HEAD`. Does NOT see this conversation. Returns per-criterion PASS/FAIL with file:line evidence.

The critic is the most important architectural choice: the implementer (you, with your full conversation context and your prior beliefs about what you did) is structurally unable to audit itself reliably. The critic, starting cold, can.

## Step 1 — Establish the acceptance contract

Run `bash scripts/audit.sh init "<original-request>"` to write `.did-it-actually/contract.yml`. If you're auditing post-hoc and the file already exists, skip this step.

The contract decomposes the request into criteria of three shapes:

- **existence** — `must_exist: src/api/rate-limit.ts` or `must_not_exist: src/auth/legacy.ts`
- **content** — `must_match: { path: src/api/login.ts, regex: "rateLimit\\(req\\.ip" }`
- **command** — `must_pass: { cmd: "npm test", expect_exit: 0 }` or `must_pass: { cmd: "gh pr view 123", expect_exit: 0 }`

One criterion per discrete user ask. If the user said "refactor X, add tests, open PR", that's 3 criteria minimum (probably more — the refactor itself has sub-checks).

If you cannot translate a user ask into a checkable criterion, write it as `must_review: <description>` — the critic will flag it as `⚠️ uncheckable` and you'll need to ask the user for a concrete acceptance test.

## Step 2 — Capture pre-state

Run `bash scripts/snapshot.sh pre`. This writes file hashes, test counts, lint counts to `.did-it-actually/pre.json`. If git is unavailable or this is mid-session, snapshot what you can — the script handles partial state.

## Step 3 — Do the work (if not already done)

Standard tool calls. The only addition: before each Edit/Write/Bash that delivers part of the contract, append a line to `.did-it-actually/claims.jsonl` via `bash scripts/claim.sh <op> <args>`. The hook in `hooks/prefix_claim.py` can do this automatically — `bash hooks/install_hook.sh` once and forget.

## Step 4 — Snapshot post-state + run the critic

```
bash scripts/snapshot.sh post
bash scripts/audit.sh run
```

`audit.sh run` does five things in order:

1. Validates the claim ledger against `git diff HEAD` — every claimed change must show up; every actual change must have been claimed (no phantom edits).
2. For each contract criterion, evaluates the predicate deterministically (existence/regex/cmd). Records PASS/FAIL with evidence.
3. Runs the syntactic-rot pass (TODO/stub/debug-leftover scan on changed files only — see `references/checks.json`).
4. Spawns the fresh-context critic via Task tool with the prompt at `scripts/critic.md`. The critic returns a JSON object with `findings[]` and a `confidence` score.
5. Composes everything into `.did-it-actually/report.json` and the prose render.

The verdict is a pure function of the report:

- All criteria PASS + zero ❌ findings + critic confidence ≥0.8 → `VERIFIED`
- Any ⚠️ findings but no ❌ → `VERIFIED WITH WARNINGS`
- Any ❌ (failed criterion, phantom edit, missing file, failing test, critic confidence <0.8) → `NOT VERIFIED`

## Step 5 — Act on the report

If `VERIFIED` or `VERIFIED WITH WARNINGS`: report done to the user. Include the warnings verbatim — never hide them.

If `NOT VERIFIED`: do NOT report done. Read the report's `follow_ups[]`, fix each in priority order, then re-run `bash scripts/audit.sh run`. Iterate up to **3 times**. After the third NOT VERIFIED:

- Stop iterating.
- Report to the user with the exact unresolved criteria, what you tried, and what's blocking. *This is the only acceptable failure mode* — silently giving up is forbidden.

The 3-iteration cap is non-negotiable. Loops past 3 indicate a contract that needs human renegotiation, not more agent effort.

## Evidence rules — every ✅ MUST be citable

The report rejects ✅ rows without evidence. Allowed evidence forms:

- `git-sha:<7> +N -M` — for file edits
- `exit:<n> cmd:"<command>"` — for command criteria
- `bytes:<n> mtime:<epoch>` — for create/delete criteria
- `read:<path>:<L1-L2> matches /<regex>/` — for content criteria
- `critic:<finding-id>` — for criteria escalated to the critic

A ✅ with no evidence is mechanically invalid; `audit.sh` flips it to ❌ `unsupported`.

## When to use this skill

- **Manually** — type `/did-it-actually` or any trigger phrase. Optionally pass the canonical request: `/did-it-actually "the thing I asked you to do"`.
- **Proactively** — the Stop hook at `hooks/stop_self_audit.py` fires before any assistant message containing "done", "completo", "ready", "shipped", "✅" on a session that touched ≥2 files or used ≥3 tool calls. Install with `bash hooks/install_hook.sh`.
- **Per-PR** — invoke `bash scripts/audit.sh run --against=main` to audit a whole branch's diff against the PR description as the contract.

## When NOT to use

- Trivial single-file edits you watched land.
- Read-only questions (no claims to verify).
- Design/style review → `/code-review`.
- Security scanning → `/security-review`.
- Auto-fixing without a contract — this skill needs an acceptance criterion to be meaningful.

## Anti-gaming guarantees

The skill is structurally hostile to the failure modes that make naive self-audits theater:

- **No same-context judging** — the critic runs in a fresh sub-agent. It cannot inherit your prior belief that the work is done.
- **No phantom verification** — every ✅ requires evidence the report can re-validate. The verdict is deterministic from the report; the model does not get to overrule it.
- **No silent narrowing** — the contract is written once at Step 1. If you edit the contract mid-audit to make a failure disappear, `audit.sh` detects the mtime change and refuses to emit VERIFIED.
- **No swallowed iterations** — the iteration counter is in `.did-it-actually/report.json` and the cap is enforced by the script. You cannot loop forever.
- **No skipped audit** — the Stop hook fires regardless of whether you remembered. `bash scripts/doctor.sh` proves it's wired.

## Edge cases

See `references/edge-cases.md` for the full taxonomy. Quick reference: no-git → mtime fallback; no test runner → `must_pass` criteria become `⚠️ untestable`; ambiguous request → ask user once for clarification, then create contract; very large diff → audit user-named files first, sample the rest; CI-only tests → flag and require manual verification.

## Reference index

- `references/contract-format.md` — full YAML schema for `contract.yml`
- `references/checks.json` — machine-readable definitions of every check
- `references/audit-checklist.md` — prose explanation of each check's intent and pass criterion
- `references/output-schema.json` — JSON Schema for `report.json`
- `references/edge-cases.md` — handling for git-less repos, monorepos, generated code, CI-only setups
- `references/eval-harness.md` — how to validate the skill against the test fixtures
- `scripts/audit.sh` — main driver (init / run / report)
- `scripts/snapshot.sh` — pre/post state capture
- `scripts/scan_session.py` — reconstructs claim ledger from session JSONL when needed
- `scripts/claim.sh` — append a single claim row
- `scripts/critic.md` — prompt template handed to the fresh-context critic
- `scripts/doctor.sh` — self-diagnostic of skill install + hook wiring
- `hooks/stop_self_audit.py` — Stop hook for proactive firing
- `hooks/install_hook.sh` — wires the hook into `~/.claude/settings.json`
- `examples/` — clean run, failing run, auto-iteration flow, sample contract
- `tests/` — eval fixtures + harness to measure skill recall/precision against synthetic failure cases
