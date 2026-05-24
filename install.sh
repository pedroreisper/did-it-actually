#!/usr/bin/env bash
# install.sh — install did-it-actually as a Claude Code skill.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/pedroreisper/did-it-actually/main/install.sh | bash
#   bash install.sh                # from a clone
#   bash install.sh --project      # install to .claude/skills/ in CWD instead of ~/.claude/skills/
#   bash install.sh --hook         # also wire up the Stop hook
#   bash install.sh --uninstall    # remove the install
set -euo pipefail

REPO_URL="https://github.com/pedroreisper/did-it-actually.git"
SKILL_NAME="did-it-actually"
INSTALL_DIR="${HOME}/.claude/skills"
WIRE_HOOK=0
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)   INSTALL_DIR="$(pwd)/.claude/skills";;
    --hook)      WIRE_HOOK=1;;
    --uninstall) UNINSTALL=1;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2;;
  esac
  shift
done

TARGET="$INSTALL_DIR/$SKILL_NAME"

if [ "$UNINSTALL" -eq 1 ]; then
  if [ -e "$TARGET" ]; then
    rm -rf "$TARGET"
    printf 'removed %s\n' "$TARGET"
  else
    printf 'nothing to remove at %s\n' "$TARGET"
  fi
  exit 0
fi

mkdir -p "$INSTALL_DIR"

# If invoked from inside a clone, copy the local checkout. Otherwise clone fresh.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SELF_DIR/SKILL.md" ] && grep -q "name: $SKILL_NAME" "$SELF_DIR/SKILL.md"; then
  printf 'installing from local checkout: %s\n' "$SELF_DIR"
  rm -rf "$TARGET"
  cp -R "$SELF_DIR" "$TARGET"
else
  if [ -d "$TARGET/.git" ]; then
    printf 'updating existing install at %s\n' "$TARGET"
    git -C "$TARGET" pull --ff-only
  else
    printf 'cloning into %s\n' "$TARGET"
    rm -rf "$TARGET"
    git clone --depth 1 "$REPO_URL" "$TARGET"
  fi
fi

chmod +x "$TARGET/scripts/"*.sh "$TARGET/scripts/"*.py "$TARGET/hooks/"*.sh "$TARGET/hooks/"*.py 2>/dev/null || true

if [ "$WIRE_HOOK" -eq 1 ]; then
  bash "$TARGET/hooks/install_hook.sh"
fi

printf '\n'
printf '\033[32m✓\033[0m did-it-actually installed at %s\n' "$TARGET"
printf '\nNext steps:\n'
printf '  • Restart your Claude Code session (or /reload) so the skill is discovered.\n'
printf '  • Verify the install:  bash %s/scripts/doctor.sh\n' "$TARGET"
if [ "$WIRE_HOOK" -eq 0 ]; then
  printf '  • Enable proactive firing (recommended):  bash %s/hooks/install_hook.sh\n' "$TARGET"
fi
printf '  • Run on a finished task:  /did-it-actually\n'
