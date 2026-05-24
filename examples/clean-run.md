# Example: clean audit (VERIFIED on first iteration)

## Context

User asked: *"Add a rate limit to /api/login — 5 requests per minute per IP. Add a test."*

Claude edited `src/api/login.ts`, created `src/api/rate-limit.ts` and `src/api/login.test.ts`, ran the tests.

## Contract (`.did-it-actually/contract.yml`, abbreviated)

```yaml
criteria:
  - id: rate-limit-module-exists      # existence
  - id: login-uses-rate-limit         # content
  - id: rate-limit-is-five-per-min    # content
  - id: test-exists                   # existence
  - id: tests-pass                    # command
```

## Audit output

```
SELF-AUDIT REPORT
─────────────────────────────────────────────
Session:    Add a rate limit to /api/login — 5 requests per minute per IP.
Started:    2026-05-25T00:31:00Z
Iteration:  1/3
Audit ID:   c4d6e2af1b8e
Scope:      3 claimed, 3 diffed
Mode:       git

✅ VERIFIED
  • rate-limit-module-exists    — bytes:412 sha:a8c9bf2
  • login-uses-rate-limit       — read:src/api/login.ts:3-3 matches /from "\.\/rate-limit"/
  • rate-limit-is-five-per-min  — read:src/api/rate-limit.ts:12-15 matches /windowMs:\s*60_000.*max:\s*5/
  • test-exists                 — bytes:1247 sha:e1a09b7
  • tests-pass                  — exit:0 cmd:"npm test"
  • no-todos                    — clean
  • no-stub-bodies              — clean
  • no-debug-leftovers          — clean
  • critic-agreement            — confidence:0.95 verdict:VERIFIED

⚠️  NEEDS ATTENTION
  (none)

❌ BROKEN CLAIMS
  (none)

─────────────────────────────────────────────
FOLLOW-UP ACTIONS (priority order)
  (none)

─────────────────────────────────────────────
VERDICT: VERIFIED
        All criteria passed; critic confidence 0.95.
```

## What Claude does next

Reports to the user:

> *"Done. Rate limit added to /api/login (5 req/min/IP). Test added. 43/43 pass."*

No follow-up. No re-prompting. First-reply success.

## Why this report is trustworthy

- Each ✅ cites concrete evidence — a SHA, a regex match with line range, an exit code. The report would be rejected if any ✅ lacked evidence.
- The fresh-context critic agreed independently. It read the contract and the diff with no knowledge of the conversation that produced the work, and found nothing.
- The contract SHA is recorded — if it had been edited between iteration start and audit time, the verdict would have been `AUDIT_FAILED`.
