#!/usr/bin/env bash
# doctor.sh — self-diagnostic. Checks that did-it-actually is wired up correctly.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
result() {
  local status="$1"; shift
  case "$status" in
    ok)   PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$*";;
    warn) PASS=$((PASS+1)); printf '  \033[33m~\033[0m %s\n' "$*";;
    err)  FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$*";;
  esac
}

printf 'did-it-actually  doctor\n'
printf '%s\n' '─────────────────────────────────────────'

# 1. Skill structure
printf '\nSkill structure:\n'
[ -f "$SKILL_ROOT/SKILL.md" ]                && result ok "SKILL.md present"                || result err "SKILL.md missing at $SKILL_ROOT"
[ -f "$SKILL_ROOT/references/checks.json" ]  && result ok "references/checks.json present"  || result err "references/checks.json missing"
[ -f "$SKILL_ROOT/references/output-schema.json" ] && result ok "references/output-schema.json present" || result err "references/output-schema.json missing"
[ -x "$SCRIPT_DIR/audit.sh" ]                && result ok "audit.sh is executable"           || result warn "audit.sh not executable — run 'chmod +x scripts/*.sh hooks/*.sh'"

# 2. Frontmatter sanity
printf '\nFrontmatter:\n'
NAME="$(awk '/^name:/ {print $2; exit}' "$SKILL_ROOT/SKILL.md" 2>/dev/null || true)"
DIR_NAME="$(basename "$SKILL_ROOT")"
if [ "$NAME" = "$DIR_NAME" ]; then
  result ok "frontmatter name ($NAME) matches directory name"
else
  result err "name '$NAME' != directory '$DIR_NAME' — install will not be auto-discovered"
fi

# 3. Skill is discoverable by Claude Code
printf '\nClaude Code discovery:\n'
CC_SKILLS="${HOME}/.claude/skills"
PROJECT_SKILLS="$(pwd)/.claude/skills"
if [ -L "$CC_SKILLS/$NAME" ] || [ -d "$CC_SKILLS/$NAME" ]; then
  result ok "installed at $CC_SKILLS/$NAME"
elif [ -L "$PROJECT_SKILLS/$NAME" ] || [ -d "$PROJECT_SKILLS/$NAME" ]; then
  result ok "installed at $PROJECT_SKILLS/$NAME (project-scoped)"
else
  result warn "not installed — run install.sh from this repo"
fi

# 4. Required runtimes
printf '\nRuntimes:\n'
command -v python3 >/dev/null && result ok "python3: $(python3 --version 2>&1)" || result err "python3 missing"
command -v bash    >/dev/null && result ok "bash: $(bash --version | head -1)"  || result err "bash missing"
python3 -c 'import yaml' 2>/dev/null && result ok "python pyyaml installed" || result warn "pyyaml missing — 'pip install pyyaml' (audit.sh needs it)"
command -v shasum >/dev/null && result ok "shasum available" || (command -v sha256sum >/dev/null && result ok "sha256sum available" || result err "no sha256 tool")
command -v git    >/dev/null && result ok "git: $(git --version)" || result warn "git missing — skill will fall back to mtime mode"

# 5. Hook wiring
printf '\nHook wiring:\n'
SETTINGS="${HOME}/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  if grep -q 'did-it-actually' "$SETTINGS"; then
    result ok "Stop hook registered in $SETTINGS"
  else
    result warn "Stop hook NOT registered — run 'bash hooks/install_hook.sh' for proactive firing"
  fi
else
  result warn "$SETTINGS not found"
fi

# 6. End-to-end smoke test
printf '\nEnd-to-end smoke:\n'
SMOKE_DIR="$(mktemp -d -t didit-doctor-XXXXXX)"
(
  cd "$SMOKE_DIR"
  printf 'placeholder\n' > placeholder.txt
  if bash "$SCRIPT_DIR/audit.sh" init "smoke test request" >/dev/null 2>&1 && [ -f .did-it-actually/contract.yml ]; then
    result ok "audit.sh init writes contract.yml"
  else
    result err "audit.sh init failed"
  fi
)
rm -rf "$SMOKE_DIR"

# 7. Summary
printf '\n%s\n' '─────────────────────────────────────────'
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFix the FAIL items above before relying on the skill.\n'
  exit 1
fi
printf '\nAll critical checks pass.\n'
