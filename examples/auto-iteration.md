# Example: the killer flow — auto-iteration replaces "I told you 10 times"

## The problem this example shows

Without this skill:

```
User:  Add caching to the /products endpoint, expire after 60s.

Claude: Done — added cache.

User:  It doesn't expire. Cache is permanent.

Claude: Fixed — added expiry.

User:  The expiry is 60 minutes, not seconds.

Claude: Fixed — 60 seconds now.

User:  You broke the test. test_products_no_cache fails.

Claude: Fixed.

User:  Now it's a memory leak — you never clean up old entries.

Claude: Fixed.

User:  ...
```

Five round-trips. The user gave the same information across multiple replies because each "Done" was premature.

## With did-it-actually

```
User:  Add caching to the /products endpoint, expire after 60s.

Claude: [reads request → writes contract.yml]
        criteria:
          - id: cache-attached
            type: content
            spec: { path: src/api/products.ts, must_match: 'cache\.' }
          - id: expiry-is-60-seconds
            type: content
            spec:
              path: src/api/cache.ts
              must_match_pcre: 'ttl.*=.*60(?!\d)'  # 60, not 600 or 6000
          - id: tests-still-pass
            type: command
            spec: { cmd: npm test, expect_exit: 0 }
          - id: no-memory-leak
            type: command
            spec: { cmd: node tests/leak-check.js, expect_exit: 0 }

        [does the work]

        [audit.sh run]
        Iteration 1: NOT VERIFIED
          ❌ expiry-is-60-seconds — read:src/api/cache.ts:8 matches /ttl = 60 \* 60/
            (60 minutes, not seconds)
          ❌ tests-still-pass — exit:1 (test_products_no_cache failed)

        [Claude fixes ttl = 60, fixes the no_cache test by checking the new query param]
        [audit.sh run]
        Iteration 2: NOT VERIFIED
          ❌ no-memory-leak — exit:1 (RSS grew 80MB over 100 cycles)

        [Claude adds LRU eviction with max 1000 entries]
        [audit.sh run]
        Iteration 3: VERIFIED

Claude: Done. Cache added to /products with 60s TTL and LRU eviction at 1000 entries.
        All tests pass. Memory leak check: stable RSS over 100 cycles.
```

**One user reply. Three internal iterations. Result delivered correctly on first response.**

## How the loop terminates

The cap is `3`. If iteration 3 still fails:

```
Iteration 3/3: NOT VERIFIED — CAPPED
  ❌ no-memory-leak — exit:1 (RSS still grows 12MB / 100 cycles after switching to WeakMap)

Claude: I can't get the memory leak below 12MB/100cycles in 3 iterations.
        Things I tried:
          - LRU eviction at 1000 entries → cut from 80MB to 25MB
          - WeakMap-keyed entries → cut to 12MB
          - Explicit GC hints → no further reduction
        Possible blockers:
          - The leak may be in a downstream library (cache library v2.3.1)
          - Or in the test harness itself (the leak-check.js threshold may be too tight for a hot V8)
        Want me to try a different cache library, or relax the test threshold to 20MB?
```

Cap behaviour is enforced by `audit.sh`, not by prompt. Claude cannot decide to iterate a fourth time.

## The contract is the source of truth

Notice: the user's original request (*"60s expiry"*) became `must_match_pcre: 'ttl.*=.*60(?!\d)'` — a regex that catches `ttl = 60` but rejects `ttl = 60 * 60` or `ttl = 600`. The first iteration's `60 minutes` mistake was caught mechanically, not by user re-reading.

Every ambiguity the user might have caught manually is now a contract criterion. The user describes the goal once; the skill enforces it across all iterations.

## When this flow does NOT happen

The auto-iteration loop only runs when:

- The Stop hook is installed (`bash hooks/install_hook.sh`), OR
- The user explicitly invoked `/did-it-actually` mid-turn

Otherwise the skill is just a manual audit — no auto-iteration. The killer flow needs the Stop hook to fire. That's why `install.sh --hook` is the recommended path.

## Comparison

| Without skill | With skill |
|---|---|
| 5 user replies | 1 user reply |
| User holds the spec in their head | Spec is `contract.yml`, machine-checked |
| Each "Done" was premature | "Done" is gated by VERIFIED |
| Same info repeated across replies | Each iteration sees the audit, not the user |
| User loses trust in "Done" | User trusts "Done" because it cites evidence |
