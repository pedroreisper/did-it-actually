#!/usr/bin/env bash
# install_hook.sh — wire stop_self_audit.py into ~/.claude/settings.json.
# Idempotent: re-running is safe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/stop_self_audit.py"
SETTINGS="${HOME}/.claude/settings.json"

[ -f "$HOOK" ] || { printf 'hook script missing: %s\n' "$HOOK" >&2; exit 1; }
chmod +x "$HOOK"

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, sys, os
settings_path, hook_path = sys.argv[1:3]
data = json.load(open(settings_path))
hooks = data.setdefault('hooks', {})
stop = hooks.setdefault('Stop', [])
# Look for existing did-it-actually entry
for entry in stop:
    if isinstance(entry, dict):
        for h in entry.get('hooks', []):
            if isinstance(h, dict) and 'did-it-actually' in h.get('command', ''):
                print('already installed')
                raise SystemExit(0)
stop.append({
    'matcher': '',
    'hooks': [
        {
            'type': 'command',
            'command': f'python3 {hook_path}',
            'timeout': 10,
        }
    ]
})
# Atomic write
tmp = settings_path + '.tmp'
with open(tmp, 'w') as f:
    json.dump(data, f, indent=2)
os.replace(tmp, settings_path)
print('installed Stop hook in', settings_path)
PY
