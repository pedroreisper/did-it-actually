# `contract.yml` — acceptance criteria format

The contract is the formal version of the user's request. Each criterion is a falsifiable claim that the work satisfied the user. The audit succeeds iff every criterion evaluates to PASS.

## Schema

```yaml
version: 1
request: |
  <verbatim original user request, multi-line OK>
created_at: <ISO 8601>
iteration: <int — incremented by audit.sh on each re-run>
criteria:
  - id: <short-kebab-case-slug>
    intent: <one-line restatement of the user-facing ask>
    type: <existence | content | command | review>
    spec: <see per-type specs below>
    severity: <critical | warning>
```

## Per-type specs

### `existence`

```yaml
- id: rate-limit-module-created
  intent: a rate-limit module exists at the standard path
  type: existence
  spec:
    must_exist: src/api/rate-limit.ts
    min_bytes: 100         # optional, default 1
  severity: critical
```

Variants:

- `must_exist: <path>` — file must be present and ≥`min_bytes`
- `must_not_exist: <path>` — file must be absent
- `must_exist_any: [<path1>, <path2>]` — at least one of the listed paths exists
- `must_exist_all: [<path1>, <path2>]` — all listed paths exist

### `content`

```yaml
- id: login-uses-rate-limit
  intent: the login handler calls rateLimit on the request IP
  type: content
  spec:
    path: src/api/login.ts
    must_match: 'rateLimit\(req\.ip'   # ECMAScript regex
    must_not_match: 'TODO|FIXME'        # optional negative pattern
  severity: critical
```

Variants:

- `path: <file>` + `must_match: <regex>` — file must contain the pattern
- `path: <file>` + `must_not_match: <regex>` — file must NOT contain the pattern
- `paths: [<glob>]` — apply the patterns across multiple files; PASS iff every file passes
- `line_range: [<L1>, <L2>]` — restrict the match to the given line range (for surgical edits)

### `command`

```yaml
- id: tests-pass
  intent: the full test suite passes after the changes
  type: command
  spec:
    cmd: npm test
    expect_exit: 0
    expect_stdout_contains: ""         # optional substring
    expect_stdout_matches: ""          # optional regex
    timeout_seconds: 120
  severity: critical
```

Variants:

- `cmd: <string>` — shell command, run in the project root
- `expect_exit: <int>` — required exit code (default 0)
- `expect_stdout_contains: <string>` — stdout must contain the substring
- `expect_stdout_matches: <regex>` — stdout must match the regex
- `expect_stderr_silent: true` — stderr must be empty (rare; use for strict gates)
- `timeout_seconds: <int>` — kill the command after this many seconds; FAIL on timeout

### `review`

For asks that can't be mechanically checked (subjective, UX, design intent, copy tone).

```yaml
- id: copy-sounds-natural
  intent: the error message reads like a human wrote it
  type: review
  spec:
    target: src/api/errors.ts
    rubric: |
      No filler ("we are sorry to inform you"), under 12 words,
      uses second person ("you"), avoids "an error has occurred"
  severity: warning
```

`review` criteria are evaluated by the critic sub-agent, not by deterministic script. They cannot raise the verdict above `VERIFIED WITH WARNINGS` on their own — if the critic flags one as failing, it counts as ⚠️, not ❌. To gate `VERIFIED` on a subjective ask, convert it to a `content` criterion with a regex that approximates the rubric.

## Severity rules

- `critical` — failure of this criterion makes the verdict `NOT VERIFIED`.
- `warning` — failure makes it `VERIFIED WITH WARNINGS`, never `NOT VERIFIED`.

Default severity is `critical` for `existence` and `command` types, `warning` for `review`.

## Multi-language regex note

Regexes are interpreted by the runtime that evaluates them:

- `content` criteria → `grep -E` (POSIX extended regex)
- `command.expect_stdout_matches` → `grep -E` (same)

Escape backslashes per YAML rules: `'rateLimit\(req\.ip'` not `"rateLimit\(req\.ip"`.

For PCRE features (lookahead, named groups), use `must_match_pcre: ...` instead — `audit.sh` will fall back to Python's `re` module.

## Worked example — full contract

Original request: *"Add a rate limit to /api/login — 5 requests per minute per IP. Add a test. Make sure linting still passes."*

```yaml
version: 1
request: |
  Add a rate limit to /api/login — 5 requests per minute per IP.
  Add a test. Make sure linting still passes.
created_at: 2026-05-25T00:14:00Z
iteration: 1
criteria:
  - id: rate-limit-module-exists
    intent: a rate-limit utility module is created
    type: existence
    spec:
      must_exist: src/api/rate-limit.ts
      min_bytes: 200
    severity: critical

  - id: login-imports-rate-limit
    intent: login.ts imports and uses the rate-limit utility
    type: content
    spec:
      path: src/api/login.ts
      must_match: 'from\s+["\047]\./rate-limit["\047]'
      must_match_pcre: 'rateLimit\s*\(\s*req\.ip'
    severity: critical

  - id: rate-limit-is-five-per-minute
    intent: limit is configured as 5 req / 60 s per IP
    type: content
    spec:
      path: src/api/rate-limit.ts
      must_match: '\b5\b'
      must_match_pcre: 'window.*=.*60\s*[*x]?\s*1000|60_?000'
    severity: critical

  - id: test-exists
    intent: a test file references the rate-limit behaviour
    type: existence
    spec:
      must_exist_any:
        - src/api/rate-limit.test.ts
        - src/api/__tests__/rate-limit.test.ts
        - tests/api/rate-limit.test.ts
    severity: critical

  - id: tests-pass
    intent: npm test exits 0
    type: command
    spec:
      cmd: npm test
      expect_exit: 0
      timeout_seconds: 120
    severity: critical

  - id: lint-clean
    intent: eslint exits 0 on changed files
    type: command
    spec:
      cmd: npm run lint -- --max-warnings 0
      expect_exit: 0
      timeout_seconds: 60
    severity: critical
```

Six criteria, each independently falsifiable. If any returns FAIL, the verdict is NOT VERIFIED and the report names which one and why.

## Contract authoring tips

- **One criterion per discrete user ask.** Resist bundling.
- **Use the user's words in `intent`.** When the report quotes intent back to the user, it should feel like *their* request, not a translation.
- **Prefer command criteria for behaviour, content criteria for shape.** "Tests pass" is a command criterion. "Function is named `rateLimit`" is a content criterion.
- **Anchor regexes.** `'\bfoo\b'` not `'foo'`.
- **Avoid `review` unless genuinely subjective.** Most "vague" asks can be made concrete with a regex on a comment, a docstring, a test name, or a CLI flag.
- **Re-read the user's message verbatim before writing the contract.** This is where most contracts diverge from intent.

## Tamper-evidence

`audit.sh run` records `sha256(contract.yml)` in `report.json`. If the contract's mtime or hash changes mid-iteration, the audit refuses to emit `VERIFIED` and flags `contract-mutated`. Contract changes are legitimate between sessions (user re-scoped) but not within an iteration loop.
