# Audit checklist — what each check does and why

The authoritative machine-readable definitions live in `checks.json`. This file is the human-readable companion: for each check, what it catches, why it matters, and where the false-positive / false-negative risks lie.

## Claim reconciliation (the foundational layer)

### `ledger-vs-diff`

**Catches**: Claude said it edited file X but never did. Or Claude edited file Y silently and never mentioned it.

**Why it matters**: This is the single most common failure mode in long Claude sessions. Phantom edits are how "but it should work" happens. Missing claims are how "you also broke this other thing" happens.

**Mechanism**: compares `claims.jsonl` against `git diff --name-only HEAD`. Symmetric set difference. Both directions are errors.

**False-positive risk**: low — git diff is ground truth.
**False-negative risk**: medium if the ledger was never written (Claude forgot to call `claim.sh`). Mitigation: the Stop hook reconstructs the ledger from session JSONL via `scan_session.py`.

### `ledger-shas-match`

**Catches**: Claude claimed to edit a file with one content but the file's actual content differs.

**Why it matters**: catches "I wrote X" when the actual file has Y — could be a stale read, a partial write, or a later overwrite the agent didn't notice.

**Mechanism**: re-hashes each file in the ledger and compares to `sha_after`.

## Contract evaluation

### `contract-existence`, `contract-content`, `contract-command`

**Catches**: the user asked for X and X did not happen.

**Why it matters**: this is the entire reason the skill exists. Every other check is decoration.

**Mechanism**: deterministic evaluator per criterion type. See `contract-format.md` for spec details.

**False-positive risk**: depends on contract quality. A regex like `'foo'` will match `foobar`. Mitigation: contracts should use anchored regexes (`'\bfoo\b'`).
**False-negative risk**: depends on contract completeness. A user ask not encoded in any criterion will not be checked. Mitigation: the critic agent reads the full original request and can flag "this user ask has no criterion".

### `contract-review`

**Catches**: subjective asks (tone, design intent, UX) that don't reduce to a regex.

**Why it matters**: not every user request is mechanically checkable. Refusing to attempt them would silently fail those asks.

**Mechanism**: handed to the fresh-context critic with the criterion's `rubric` as the evaluation guide.

**Verdict ceiling**: `review` criteria can never cause `NOT VERIFIED` on their own — only `VERIFIED WITH WARNINGS`. To gate `VERIFIED` strictly, convert the criterion to `content` or `command` type.

## Syntactic rot

### `no-todos`

**Catches**: Claude left `TODO:` comments in shipped code.

**Why it matters**: every TODO is a deferred problem. Most are forgotten.

**Patterns**: `\bTODO\b`, `\bFIXME\b`, `\bHACK\b`, `\bXXX\b`, `\bNOCOMMIT\b`.

**False-positive risk**: medium — tests sometimes contain `TODO` in test names; the user may have requested TODOs explicitly. Mitigation: `.did-it-actually/ignore` for per-file suppressions, severity is `warning` not `critical`.

### `no-stub-bodies`

**Catches**: empty function bodies disguised as implementations — `pass`, `...`, `raise NotImplementedError`, `throw new Error("not implemented")`, Kotlin `TODO()`, Rust `unimplemented!()`, `panic!("unimplemented")`.

**Why it matters**: this is the second most common failure mode after dropped sub-asks. Claude scaffolds the shape and forgets to fill it in.

**Mechanism**: regex sweep over changed lines (`scripts/audit.sh` → `syntactic_rot`). AST-based detection is a planned upgrade (see README Contributing), not yet implemented — today every language is regex-only.

**False-positive risk**: medium — string literals that contain the patterns can trip it.
**False-negative risk**: medium — clever evasions (`raise type('NIE', (Exception,), {})()`) defeat a pure regex; an AST walk would catch more, which is why it's on the roadmap.

### `no-debug-leftovers`

**Catches**: `console.log`, `debugger`, `pdb.set_trace`, `binding.pry`, `byebug` in changed non-test files.

**Why it matters**: debug output in production code is a security and noise issue.

**False-positive risk**: medium — `console.log` is legitimate in scripts and dev tooling. Mitigation: skip in files matching `**/scripts/**`, `**/*.dev.*`, `**/bin/**`. Suppressible.

## Structural

### `syntax-valid`

**Catches**: file no longer parses in its language.

**Why it matters**: code that doesn't parse is broken. Surprisingly easy for Claude to ship after a multi-edit session.

**Mechanism**: language-specific compiler check per `checks.json` tool_map.

### `no-new-skipped-tests`

**Catches**: tests that were silenced in this session that weren't silenced before.

**Why it matters**: the "I made the test pass" failure mode is often "I made it not run". The audit must catch this even when overall test count is preserved.

**Mechanism**: grep for skip markers in test files; diff against `pre.json` snapshot.

**False-positive risk**: low — only flags *new* skips, not pre-existing ones.

## Session history

### `swallowed-bash-failures`

**Catches**: a Bash tool call in this session exited non-zero and was never addressed in subsequent messages.

**Why it matters**: Claude sometimes runs a command, sees it fail, and silently moves on. The user never knows.

**Mechanism**: `scripts/scan_session.py` parses the session JSONL log, finds all Bash invocations, checks exit codes, and looks for any later assistant message that references the failure (by file path, command name, or error string).

**False-positive risk**: medium — the heuristic for "addressed" is fuzzy. Conservative: flag as `⚠️` not `❌`.

## Fresh-context critic

### `critic-agreement`

**Catches**: everything else. The critic is the safety net for failures the deterministic checks miss.

**Why it matters**: deterministic checks can only catch what was specified. The critic, reading the original request and the actual diff with no conversation contamination, may spot misalignments that no contract criterion captured.

**Mechanism**: spawned via Task tool with `general-purpose` subagent_type. Prompt at `scripts/critic.md`. Input: contract.yml, claims.jsonl, `git diff HEAD`, original request. Output: structured JSON with verdict + confidence + per-finding evidence.

**Critic isolation**:
- No access to the conversation that produced the work.
- No access to the implementer's prior beliefs.
- Receives only the artifacts a fresh reviewer would have.

**Confidence threshold**: critic verdict counts toward the final verdict only if `confidence ≥ 0.7`. Below that, the critic is `SKIP` and the deterministic checks alone decide.

**Why this beats LLM-as-judge in the same context**: see the literature on Self-Refine failures (Madaan 2023, Huang 2024). Same-context self-critique converges on the prior belief. Fresh-context critique does not.

## Meta-audit (audit of the audit)

After all checks run, `audit.sh` validates the audit itself:

- **`all_checks_ran`**: every check in `checks.json` produced a result row (PASS / FAIL / SKIP / ERROR — not silently absent).
- **`missing_inputs`**: lists any file/tool the audit needed but couldn't read (`contract.yml`, `claims.jsonl`, `git`, `pre.json`).
- **`contract_mutated_mid_iteration`**: true if `contract.yml`'s sha256 differs from the iteration-start sha. Triggers `AUDIT_FAILED` verdict — the agent cannot edit the goalposts.

If the meta-audit fails, the final verdict is `AUDIT_FAILED`, never `VERIFIED`. The skill is honest about its own brittleness.
