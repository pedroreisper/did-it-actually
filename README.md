# did-it-actually

> Stop telling Claude the same thing five times. This skill makes Claude check its own work against your request — and fix the gap before reporting done.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## The pain it solves

You ask Claude for a thing. Claude reports done. You read the result, find the gap, repeat the ask. Claude reports done again. You read the result, find a different gap. Three rounds later you give up and fix it yourself.

This is not a Claude problem — it's a feedback-loop problem. The implementer cannot reliably audit itself in the same context that produced the work. Self-review converges on prior belief.

**did-it-actually** closes the loop with three structural fixes:

1. **A formal contract** — your request decomposed into discrete, falsifiable acceptance criteria written to `.did-it-actually/contract.yml`.
2. **A fresh-context critic** — an independent sub-agent that audits the work without seeing the conversation that produced it.
3. **A fix-and-re-audit loop** — the skill tells Claude to fix any NOT VERIFIED gaps and re-run the audit; the script enforces a hard cap of 3 iterations. The loop itself is prompt-driven (Claude reads the report and acts), but the cap, the verdict, and the contract integrity are mechanical.

The verdict is a pure function of evidence. Every `✅` cites a SHA, an exit code, or a `file:line`. Anything else is mechanically downgraded to `❌`.

## Quick demo

```
You: Add rate limit to /api/login, 5 req/min/IP. Add a test. Open a PR.

Claude: [edits 3 files, runs tests, says "done — PR opened"]

→ Stop hook fires → did-it-actually runs automatically

SELF-AUDIT REPORT
─────────────────────────────────────────────
Iteration: 1/3
✅ VERIFIED
  • rate-limit-module-exists  bytes:412 sha:a8c9...
  • login-imports-rate-limit  read:src/api/login.ts:3-3 matches /from ".\/rate-limit"/
  • tests-pass                exit:0 cmd:"npm test"
❌ BROKEN CLAIMS
  • pr-opened                 no gh pr create in claim ledger; gh pr view exits 1
VERDICT: NOT VERIFIED
        sub-ask dropped: PR was claimed but not opened.

→ Claude reads report → runs `gh pr create` → re-audits

Iteration: 2/3
VERDICT: VERIFIED

Claude: Done. PR opened: https://github.com/.../pull/47. All 43 tests pass.
```

You typed the request once. The audit caught the dropped sub-ask. Claude fixed it without being told. You got the result you wanted on the first reply.

## Install

Inspect-then-run (recommended — install.sh is short and worth a read):

```bash
git clone https://github.com/pedroreisper/did-it-actually
cd did-it-actually
less install.sh       # 80 lines, no obfuscation
bash install.sh --hook
```

One-liner (if you trust the source):

```bash
curl -fsSL https://raw.githubusercontent.com/pedroreisper/did-it-actually/main/install.sh | bash -s -- --hook
```

Project-scoped (shared with a team via your repo):

```bash
bash install.sh --project --hook
```

Verify it's wired up:

```bash
bash ~/.claude/skills/did-it-actually/scripts/doctor.sh
```

The `--hook` flag enables proactive firing (recommended). Without it, the skill only runs when you invoke it explicitly.

## Usage

### Manual

Type any of these in chat:

- `/did-it-actually`
- "did it actually finish?"
- "audita-te"
- "verifica o que fizeste"
- "is it really done?"

Or pass the canonical request explicitly:

```
/did-it-actually "the thing I asked you to do"
```

### Proactive (recommended)

With `--hook` installed, the audit fires automatically before Claude emits any "done / completo / ready / shipped" message on a turn that touched ≥2 files or used ≥3 tool calls. You don't have to remember.

### Per-PR

Audit a whole branch against the PR description as the contract:

```bash
bash ~/.claude/skills/did-it-actually/scripts/audit.sh run --against=main
```

## What this skill is NOT

- Not a code reviewer (`/code-review` does that)
- Not a security scanner (`/security-review` does that)
- Not a test framework (uses your existing test runner)
- Not an auto-fixer for code-quality nits — it audits *request fidelity*, not style

This skill is intentionally narrow. It answers exactly one question: **did Claude actually do what you asked**.

## How it works

```
┌─────────────────────────────────────────────────────────────┐
│  User request                                                │
│       │                                                      │
│       ▼                                                      │
│  contract.yml ◄────────────────────────────────┐            │
│       │              (Step 1: decompose ask)    │            │
│       ▼                                          │            │
│  Claude does the work, appending claims.jsonl   │            │
│       │              (Steps 2-3)                 │            │
│       ▼                                          │            │
│  audit.sh run                                    │            │
│   ├─► deterministic checks                       │            │
│   │     - ledger ≡ git diff                      │            │
│   │     - existence / content / command          │            │
│   │     - syntactic-rot scan                     │            │
│   │                                              │            │
│   └─► Task spawn → fresh-context critic ────────┘            │
│                       (no conversation history)              │
│                                                              │
│  report.json + prose render                                  │
│       │                                                      │
│       ├── VERIFIED ───────────► report done to user          │
│       └── NOT VERIFIED ───────► loop: fix → re-audit         │
│                                  (cap: 3 iterations)         │
└─────────────────────────────────────────────────────────────┘
```

Full architecture in [`SKILL.md`](SKILL.md).

## Anti-gaming guarantees

The skill is structurally hostile to the failure modes that make naive self-audits theater:

| Failure mode | How the skill blocks it |
|---|---|
| Same-context judging | Critic runs in a fresh sub-agent with no conversation history |
| Phantom ✅ ("I checked and it's fine") | Every ✅ requires citable evidence (SHA, exit code, file:line) |
| Moving the goalposts mid-iteration | Contract SHA is recorded; mutation → `AUDIT_FAILED` |
| Infinite "fix → re-audit" loops | Hard 3-iteration cap enforced by script, not by prompt |
| Skipping the audit | Stop hook fires regardless of agent intent; `doctor` proves it's wired |
| Stub bodies passing as work | Regex sweep on changed lines flags `NotImplementedError`/`unimplemented!()`/`TODO()` stubs |
| Silenced tests | Diff vs pre-state catches *new* skips, not pre-existing ones |
| Swallowed Bash failures | `scan_session.py` reads the session JSONL for unaddressed non-zero exits |

## Validation

The skill ships with an eval harness (`tests/`) measuring recall and precision against synthetic failure-mode fixtures. Four ship today — `missing-file`, `dropped-subask`, `stub-body`, and a `clean-control` (which must stay VERIFIED, guarding precision); `references/eval-harness.md` lists the further fixtures the harness is designed to grow into. Target gates:

- recall(missing-file) ≥ 0.95
- recall(dropped-subask) ≥ 0.95
- recall(stub-body) ≥ 0.85
- precision(NOT VERIFIED) ≥ 0.90 — `clean-control` must never trip
- cost ≤ 5,000 tokens / 15 tool calls per audit

```bash
bash tests/run-evals.sh
```

See [`references/eval-harness.md`](references/eval-harness.md) for methodology.

## Layout

```
did-it-actually/
├── SKILL.md                    # entry point Claude Code loads
├── README.md                   # this file
├── LICENSE                     # MIT
├── install.sh                  # one-liner installer
├── references/
│   ├── contract-format.md      # contract.yml YAML schema
│   ├── checks.json             # machine-readable check definitions
│   ├── output-schema.json      # JSON Schema for report.json
│   ├── audit-checklist.md      # per-check intent + risks
│   ├── edge-cases.md           # no-git, monorepos, generated files, CI-only
│   └── eval-harness.md         # how to measure the skill
├── scripts/
│   ├── audit.sh                # main driver (init / run / render / status / doctor)
│   ├── render.py               # JSON → prose verdict box
│   ├── snapshot.sh             # pre/post state capture
│   ├── snapshot.py             # snapshot diff utilities
│   ├── claim.sh                # append a single claim row
│   ├── scan_session.py         # reconstruct ledger from session JSONL
│   ├── critic.md               # prompt template for the fresh-context critic
│   └── doctor.sh               # self-diagnostic
├── hooks/
│   ├── stop_self_audit.py      # Stop hook for proactive firing
│   └── install_hook.sh         # wires the hook into ~/.claude/settings.json
├── examples/
│   ├── clean-run.md            # VERIFIED scenario
│   ├── needs-fixes.md          # NOT VERIFIED → followups
│   ├── auto-iteration.md       # the killer "no more 10 times" flow
│   └── contract.example.yml    # sample contract
└── tests/
    ├── run-evals.sh            # eval harness driver
    └── fixtures/               # synthetic failure-mode test cases
```

## Contributing

Two things especially valuable:

1. **New fixtures** — when a real Claude session produces a failure mode this skill doesn't catch, distill it into a fixture under `tests/fixtures/` and open a PR. The eval harness grows with the failure surface.
2. **AST-based stub detection** — the rot scan is regex-only today, so clever evasions slip through (`raise type('NIE',(Exception,),{})()`). A real AST walk for Python/TypeScript (then Rust, Go, Kotlin, Swift, Ruby) would cut the false-negative rate; `references/checks.json` sketches the per-language targets.

Keep `SKILL.md` under ~200 lines. Detail goes in `references/`.

## License

[MIT](LICENSE).

## Acknowledgments

The architecture distills critiques from six independent reviewer perspectives — LLM-eval research, SRE/observability, DX/OSS adoption, adversarial-security, Anthropic-skill ecosystem, and formal-verification — applied to an earlier prose-only draft. The convergent insight: **structure over narration, evidence over claims, fresh context over self-review, auto-iterate over notify**.

If this skill saves you one "please can you actually fix it this time" reply, it's worth its install cost.
