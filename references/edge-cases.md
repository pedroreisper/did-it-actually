# Edge cases

## No git repo

**Symptom**: `git rev-parse --is-inside-work-tree` exits non-zero.

**Handling**:
- `snapshot.sh pre` records file mtimes + sha256 for every file under cwd (depth-capped to avoid `node_modules`, `.venv`, etc.).
- `ledger-vs-diff` falls back to comparing `pre.json` snapshots: any file with changed sha256 or mtime is treated as a diffed file.
- `report.json.session_meta.mode = "no-git-mtime"`.
- Header line in prose render: `Mode: no-git fallback (mtime + sha256)`.

## No test runner detectable

**Symptom**: `must_pass: cmd: npm test` runs but the project has no package.json scripts.test, or the cmd is `echo "no tests"` style stub.

**Handling**:
- `audit.sh` runs the cmd anyway and reports exit code + output. If the output matches `(no tests|echo|exit 0|:)$` patterns, mark as `SKIP` with `skip_reason: "test command appears to be a stub"`.
- Verdict treats SKIP as ⚠️, not as ✅ — explicit acknowledgement that the project lacks test coverage.

## Monorepo

**Symptom**: multiple `package.json` / `pyproject.toml` in subdirectories.

**Handling**:
- `audit.sh` groups changed files by their nearest package root.
- `must_pass: cmd: npm test` runs in each affected package's root.
- Per-package results aggregate to a single verdict (any package fails → criterion fails).

## Generated files

**Symptom**: `dist/`, `build/`, `node_modules/`, `*.lock`, `__pycache__/`, `coverage/`, `.next/`, `target/`, `*.min.js`, `*.generated.*` appear in the diff.

**Handling**: auto-excluded from `claims.jsonl`, `ledger-vs-diff`, and syntactic-rot scans. Listed in `report.json.scope.generated_files_changed` for transparency, but not used in verdict.

The exclusion list is in `.did-it-actually/ignore-globs` and editable per project.

## Binary files

**Symptom**: `git diff --numstat` shows `-\t-\t<file>` (binary).

**Handling**:
- Existence and command criteria still apply.
- Content criteria skip binary files automatically and flag `SKIP: binary`.
- Syntactic-rot scans skip them.

## Very large diff (>50 files changed)

**Handling**:
- Audit all files explicitly named in `contract.yml` or `claims.jsonl` (highest confidence).
- Sample 10 random unannounced files for `ledger-vs-diff` phantom-edit detection.
- Syntactic-rot scans run on the full set (cheap).
- `report.json.scope` records `sample_size_phantom_check: 10`.

## Ambiguous original request

**Symptom**: the user's first message cannot be decomposed into discrete acceptance criteria — too vague, too discursive, or "fix this" with no antecedent.

**Handling**:
- `audit.sh init` writes a placeholder contract with a single `must_review` criterion containing the raw request.
- Critic is instructed to flag every reasonable interpretation as a `⚠️ uncheckable` finding.
- Skill emits `verdict: NOT VERIFIED, verdict_reason: "contract incomplete — ask user for acceptance test"`.
- Follow-up: a `[CRITICAL]` action telling Claude to ask the user one focused question with the candidate interpretations.

## CI-only tests

**Symptom**: `package.json` has `"test": "echo 'see CI'"`.

**Handling**: detected at `audit.sh run`; criterion flagged `SKIP: ci-only`. Follow-up suggests `[INFO] Verify in CI before merge`. Optionally suggest scheduling: `[INFO] Consider /schedule to check CI when it completes`.

## Pre-existing failures

**Symptom**: `must_pass: cmd: npm test` fails, but the failures are in files unchanged in this session.

**Handling**:
- `snapshot.sh pre` captured pre-state test counts and per-test status (if the runner supports `--json` or similar).
- `audit.sh` diffs current failure set against pre-state failure set.
- Pre-existing failures are flagged `ℹ️ pre-existing` and do NOT cause the criterion to fail.
- New failures fail the criterion as ❌.

## TaskCreate was not used despite multi-step work

**Symptom**: original request had ≥3 sub-asks but Claude didn't invoke TaskCreate.

**Handling**:
- Contract creation still works — `audit.sh init` parses the user request directly, regardless of whether TaskCreate was used.
- Report adds a `⚠️` finding: `taskcreate-skipped — multi-step request did not use TaskCreate`.
- Does not affect verdict (warning only).

## User explicitly asked for incomplete output

**Symptom**: original request was "scaffold the handlers — leave them as TODO for now".

**Handling**:
- Contract is created with explicit `must_match: TODO` criteria on the relevant files.
- `no-todos` scan still flags them but with `⚠️ user-requested` (the criterion overrides the syntactic-rot check).
- Verdict can be `VERIFIED` if all `user-requested TODOs` are the only findings.

## Action claims that span time (background jobs, deploys)

**Symptom**: "Deploy initiated" — but the deploy is still running.

**Handling**:
- Criterion is `must_pass: cmd: <verify-deploy>` with a `polling_seconds` field (extension to command spec).
- If polling expires without success, criterion fails with `⚠️ in-progress` not `❌`.
- Follow-up: `[INFO] Verify deploy completion at <URL>` and a suggestion to use `/schedule` for the deploy ETA.

## Critic sub-agent timeout / error

**Symptom**: the Task spawn returns an error or times out.

**Handling**:
- `critic-agreement` check status: `ERROR`.
- Audit verdict cannot be `VERIFIED` — degrades to `VERIFIED WITH WARNINGS` if everything else is clean, or `NOT VERIFIED` if there are other failures.
- Follow-up: `[WARN] Critic agent unavailable — re-run audit when possible`.

## Iteration cap reached (3rd NOT VERIFIED)

**Symptom**: third iteration still fails.

**Handling**:
- Verdict: `NOT VERIFIED`, `iteration_capped: true`.
- Report includes a diff between iteration 1's failures and iteration 3's failures to show what was tried.
- Follow-up section is replaced by a `STUCK` block: lists exactly which criteria are still failing, what was tried, and what the user must decide (renegotiate contract, accept partial, or take over manually).
- Stop iterating. Report to user.

## Contract mutated mid-iteration

**Symptom**: `sha256(contract.yml)` at iteration N+1 differs from iteration N.

**Handling**:
- `meta_audit.contract_mutated_mid_iteration: true`.
- Verdict: `AUDIT_FAILED`.
- Reason: agent moved the goalposts to make a failure disappear. Pure honesty signal.
- Follow-up: surface the contract diff to the user and ask whether the change was legitimate (genuine rescope) or a workaround.

## `.did-it-actually/` directory committed by accident

**Symptom**: the audit's working directory is checked into git.

**Handling**: `install.sh` appends `.did-it-actually/` to the project's `.gitignore` on first run. `doctor.sh` warns if the directory is tracked.
