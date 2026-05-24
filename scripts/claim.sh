#!/usr/bin/env bash
# claim.sh — append a single row to the claim ledger.
# Args are passed via env vars to python3 (no string interpolation → no injection).
#
# Usage:
#   claim.sh edit <path>
#   claim.sh create <path>
#   claim.sh delete <path>
#   claim.sh cmd "<command>" <exit_code>
#   claim.sh action <name> <detail>
set -euo pipefail

WORK_DIR="${DIDIT_WORK_DIR:-.did-it-actually}"
mkdir -p "$WORK_DIR"
LEDGER="$WORK_DIR/claims.jsonl"

OP="${1:-}"
[ -n "$OP" ] || { printf 'usage: claim.sh <edit|create|delete|cmd|action> ...\n' >&2; exit 2; }
shift

sha256_path() {
  local p="$1"
  if [ ! -f "$p" ]; then printf 'absent'; return; fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$p" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$p" | awk '{print $1}'
  else
    printf 'no-sha-tool'
  fi
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

case "$OP" in
  edit|create)
    PATH_ARG="${1:-}"
    [ -n "$PATH_ARG" ] || { printf 'usage: claim.sh %s <path>\n' "$OP" >&2; exit 2; }
    SHA="$(sha256_path "$PATH_ARG")"
    SIZE="$(wc -c <"$PATH_ARG" 2>/dev/null | tr -d ' ' || printf 0)"
    OP="$OP" TS="$(now_iso)" PATH_ARG="$PATH_ARG" SHA="$SHA" SIZE="$SIZE" \
      python3 -c 'import json,os; print(json.dumps({"ts":os.environ["TS"],"op":os.environ["OP"],"path":os.environ["PATH_ARG"],"sha_after":os.environ["SHA"],"bytes":int(os.environ.get("SIZE","0") or 0)}))' >> "$LEDGER"
    ;;
  delete)
    PATH_ARG="${1:-}"
    [ -n "$PATH_ARG" ] || { printf 'usage: claim.sh delete <path>\n' >&2; exit 2; }
    TS="$(now_iso)" PATH_ARG="$PATH_ARG" \
      python3 -c 'import json,os; print(json.dumps({"ts":os.environ["TS"],"op":"delete","path":os.environ["PATH_ARG"]}))' >> "$LEDGER"
    ;;
  cmd)
    CMD_ARG="${1:-}"; EXIT_ARG="${2:-0}"
    [ -n "$CMD_ARG" ] || { printf 'usage: claim.sh cmd "<command>" <exit_code>\n' >&2; exit 2; }
    TS="$(now_iso)" CMD_ARG="$CMD_ARG" EXIT_ARG="$EXIT_ARG" \
      python3 -c 'import json,os; print(json.dumps({"ts":os.environ["TS"],"op":"cmd","cmd":os.environ["CMD_ARG"],"exit_code":int(os.environ.get("EXIT_ARG","0") or 0)}))' >> "$LEDGER"
    ;;
  action)
    NAME_ARG="${1:-}"; DETAIL_ARG="${2:-}"
    [ -n "$NAME_ARG" ] || { printf 'usage: claim.sh action <name> <detail>\n' >&2; exit 2; }
    TS="$(now_iso)" NAME_ARG="$NAME_ARG" DETAIL_ARG="$DETAIL_ARG" \
      python3 -c 'import json,os; print(json.dumps({"ts":os.environ["TS"],"op":"action","name":os.environ["NAME_ARG"],"detail":os.environ.get("DETAIL_ARG","")}))' >> "$LEDGER"
    ;;
  *)
    printf 'unknown op: %s\n' "$OP" >&2
    exit 2
    ;;
esac
