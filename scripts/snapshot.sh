#!/usr/bin/env bash
# snapshot.sh — capture pre/post state of the working tree.
# Records: per-file sha256 + size + mtime, lint counts, test counts where detectable.
set -euo pipefail

WORK_DIR="${DIDIT_WORK_DIR:-.did-it-actually}"
mkdir -p "$WORK_DIR"

PHASE="${1:-pre}"
case "$PHASE" in
  pre|post) ;;
  *) printf 'usage: snapshot.sh <pre|post>\n' >&2; exit 2 ;;
esac

OUT="$WORK_DIR/$PHASE.json"

python3 - "$OUT" "$PHASE" <<'PY'
import json, os, hashlib, subprocess, sys, time
from pathlib import Path

out_path, phase = sys.argv[1:3]

IGNORE_DIRS = {
    'node_modules', '.git', '.venv', 'venv', '__pycache__',
    'dist', 'build', '.next', 'target', 'coverage', '.cache',
    '.did-it-actually',
}

def walk():
    for root, dirs, files in os.walk('.'):
        dirs[:] = [d for d in dirs if d not in IGNORE_DIRS and not d.startswith('.')]
        for f in files:
            p = os.path.join(root, f)
            if p.startswith('./'):
                p = p[2:]
            yield p

def sha256_file(p):
    h = hashlib.sha256()
    try:
        with open(p, 'rb') as fh:
            for chunk in iter(lambda: fh.read(8192), b''):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None

files = {}
count = 0
for p in walk():
    try:
        st = os.stat(p)
    except OSError:
        continue
    if st.st_size > 1_000_000:
        # skip large blobs to keep snapshot fast
        files[p] = {'size': st.st_size, 'mtime': int(st.st_mtime), 'sha': None}
    else:
        files[p] = {'size': st.st_size, 'mtime': int(st.st_mtime), 'sha': sha256_file(p)}
    count += 1
    if count > 5000:
        break  # safety cap

def safe(cmd, timeout=10):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None

env = {}
if os.path.exists('package.json'):
    r = safe('npm test -- --listTests 2>/dev/null || true')
    if r and r.stdout:
        env['test_count_estimate'] = len([l for l in r.stdout.splitlines() if l.endswith('.test.ts') or l.endswith('.test.js') or l.endswith('.spec.ts')])
if os.path.exists('pyproject.toml') or os.path.exists('pytest.ini'):
    r = safe('python -m pytest --collect-only -q 2>/dev/null || true')
    if r and r.stdout:
        env['test_count_estimate'] = sum(1 for l in r.stdout.splitlines() if '::' in l)

snapshot = {
    'phase': phase,
    'taken_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'file_count': len(files),
    'files': files,
    'env': env,
}
with open(out_path, 'w') as fh:
    json.dump(snapshot, fh, indent=2)
print(f'wrote {out_path} — {len(files)} files', file=sys.stderr)
PY
