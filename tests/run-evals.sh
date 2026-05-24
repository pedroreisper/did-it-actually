#!/usr/bin/env bash
# run-evals.sh — measure recall, precision, and cost of did-it-actually
# against the synthetic fixtures in tests/fixtures/.
#
# Each fixture is a self-contained directory with:
#   request.txt   — original user request
#   post/         — project state after the audited work (with planted failure)
#   claims.jsonl  — what Claude claimed it did
#   truth.json    — ground truth (expected verdict + per-criterion outcome)
#
# This script copies each fixture to a tempdir, runs the audit, and compares
# report.json against truth.json. It exits non-zero if any ship gate fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

[ -d "$FIXTURES_DIR" ] || { printf 'no fixtures at %s\n' "$FIXTURES_DIR" >&2; exit 2; }

shopt -s nullglob
FIXTURES=("$FIXTURES_DIR"/*/)
[ "${#FIXTURES[@]}" -gt 0 ] || { printf 'no fixtures found\n' >&2; exit 2; }

PASS=0
FAIL=0
TOTAL=${#FIXTURES[@]}
RESULTS=()

for fixture in "${FIXTURES[@]}"; do
  name="$(basename "$fixture")"
  printf '\n[fixture] %s\n' "$name"

  tmp="$(mktemp -d -t didit-eval-XXXXXX)"
  # err log lives OUTSIDE the audited tree so it isn't picked up as a phantom edit
  err_log="$tmp.err"
  cp -R "${fixture}post/." "$tmp/" 2>/dev/null || true
  mkdir -p "$tmp/.did-it-actually"
  cp "${fixture}claims.jsonl" "$tmp/.did-it-actually/claims.jsonl" 2>/dev/null || true

  request="$(cat "${fixture}request.txt" 2>/dev/null || printf 'no request')"
  expected_verdict="$(python3 -c "import json;print(json.load(open('${fixture}truth.json'))['expected_verdict'])" 2>/dev/null || printf 'NOT VERIFIED')"

  (
    cd "$tmp"
    # Use a hand-written contract if the fixture ships one, otherwise init a
    # placeholder. Hand-written contracts make the eval honest — placeholder
    # contracts always SKIP and would inflate the pass rate.
    if [ -f "${fixture}contract.yml" ]; then
      mkdir -p .did-it-actually
      cp "${fixture}contract.yml" .did-it-actually/contract.yml
    else
      bash "$SKILL_ROOT/scripts/audit.sh" init "$request" >/dev/null 2>&1
    fi
    # Initialise git so phantom-edit detection has a baseline.
    git init -q 2>/dev/null || true
    git config user.email "eval@didit" >/dev/null 2>&1 || true
    git config user.name "didit-eval" >/dev/null 2>&1 || true
    # Run audit. Do NOT swallow failures with `|| true` — a crashed audit
    # must propagate so we don't claim VERIFIED on an empty report.
    if ! bash "$SKILL_ROOT/scripts/audit.sh" run >/dev/null 2>"$err_log"; then
      printf '    audit crashed: %s\n' "$(tail -1 "$err_log" 2>/dev/null)" >&2
    fi
  )

  if [ -f "$tmp/.did-it-actually/report.json" ]; then
    actual_verdict="$(python3 -c "import json;print(json.load(open('$tmp/.did-it-actually/report.json'))['verdict'])")"
  else
    actual_verdict="AUDIT_FAILED"
  fi

  if [ "$actual_verdict" = "$expected_verdict" ]; then
    PASS=$((PASS+1))
    RESULTS+=("✓ $name : $actual_verdict")
    rm -rf "$tmp" "$err_log"
  else
    FAIL=$((FAIL+1))
    RESULTS+=("✗ $name : expected=$expected_verdict got=$actual_verdict (keep: $tmp)")
  fi
done

printf '\n%s\n' '─────────────────────────────────────────'
printf 'EVAL RESULTS — did-it-actually\n'
printf '%s\n' '─────────────────────────────────────────'
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
printf '\n  pass: %d / %d\n' "$PASS" "$TOTAL"

# Ship gate: require ≥ 80% pass rate on fixtures present.
if [ "$TOTAL" -eq 0 ]; then
  printf '\n[gate] no fixtures — eval is informational only.\n'
  exit 0
fi
PCT=$(( PASS * 100 / TOTAL ))
if [ "$PCT" -lt 80 ]; then
  printf '\n[gate] FAIL — pass rate %d%% < 80%% threshold.\n' "$PCT"
  exit 1
fi
printf '\n[gate] PASS — pass rate %d%% ≥ 80%% threshold.\n' "$PCT"
