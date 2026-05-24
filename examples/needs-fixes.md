# Example: NOT VERIFIED → follow-up actions

## Context

User asked: *"Refactor the auth module to use JWT instead of sessions. Update the middleware. Add tests for the new middleware. Open a PR."*

Claude reported done after editing 4 files, claiming "42/42 tests pass, PR is up".

## Audit output (iteration 1)

```
SELF-AUDIT REPORT
─────────────────────────────────────────────
Session:    Refactor the auth module to use JWT instead of sessions...
Started:    2026-05-25T00:12:00Z
Iteration:  1/3
Audit ID:   91b08fd23a4c
Scope:      5 claimed, 4 diffed
Mode:       git

✅ VERIFIED
  • session-edited            — git-sha:e1b22a7 +12 -34
  • jwt-edited                — git-sha:c0fd14e +89 -3
  • middleware-created        — bytes:1842 sha:7f2c9e0
  • legacy-deleted            — absent:src/auth/legacy.ts

⚠️  NEEDS ATTENTION
  • no-todos                  — 2 match(es); e.g. src/auth/jwt.ts:42
  • adjacent-files-flagged    — src/api/routes.ts imports jwt — not re-read

❌ BROKEN CLAIMS
  • middleware-test-exists    — absent: src/auth/__tests__/middleware.test.ts
  • tests-pass                — exit:1 (expected 0) cmd:"npm test" tail:['  3 failing']
  • pr-opened                 — exit:1 cmd:"gh pr view"
  • phantom-edit              — src/api/health.ts changed but never claimed

─────────────────────────────────────────────
FOLLOW-UP ACTIONS (priority order)
  1. [CRITICAL] address middleware-test-exists — absent: src/auth/__tests__/middleware.test.ts
  2. [CRITICAL] address tests-pass — exit:1 (expected 0) cmd:"npm test"
  3. [CRITICAL] address pr-opened — exit:1 cmd:"gh pr view"
  4. [CRITICAL] address phantom-edit — src/api/health.ts changed but never claimed
  5. [WARN]     resolve src/auth/jwt.ts:42 — no-todos
  6. [WARN]     resolve src/auth/middleware.ts:18 — no-todos

─────────────────────────────────────────────
VERDICT: NOT VERIFIED
        4 critical failures; 2 warnings.
```

## What Claude does next

Does NOT report done. Reads the FOLLOW-UP ACTIONS list and works through it in order:

1. Creates `src/auth/__tests__/middleware.test.ts` with real coverage for the new middleware.
2. Reads the 3 failing tests in `src/auth/session.test.ts`, fixes them (the assertions reference removed session APIs; rewrites them for JWT).
3. Re-runs `npm test` — 45/45 pass.
4. Runs `gh pr create` and captures the URL.
5. Reads `src/api/health.ts`, understands why it was edited as a side effect of the JWT refactor, and either reverts the edit or documents it.
6. Resolves the 2 TODOs — opens them as GitHub issues if not addressing now.
7. Re-runs `bash scripts/audit.sh run`.

## Audit output (iteration 2)

```
VERDICT: VERIFIED WITH WARNINGS
        All criteria pass; 2 TODOs were converted to issues #14, #15.
```

## What Claude reports to the user

> *"Done. Auth refactored to JWT. PR: https://github.com/.../pull/52. 45/45 tests pass.
> Side note: `src/api/health.ts` was also touched (now imports the JWT helper directly — a small win); kept that change. Two TODOs were moved to issues #14 and #15."*

Full disclosure of the warnings. No silent hiding.

## The pattern

A failing audit isn't a failure of the skill — it's the skill working. The point: surface the gap *before* the user notices, and close the loop without the user having to re-prompt.

Without the audit, the user would have read the original "42/42 tests pass, PR is up" message, found that the PR didn't actually exist, replied "where's the PR?", waited for Claude to open it, then noticed the failing tests, and so on. Three round-trips → one round-trip.
