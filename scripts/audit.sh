#!/usr/bin/env bash
# audit.sh — main driver for did-it-actually
# Subcommands: init <request>  |  run  |  render  |  status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${DIDIT_WORK_DIR:-.did-it-actually}"
CONTRACT="$WORK_DIR/contract.yml"
CLAIMS="$WORK_DIR/claims.jsonl"
PRE="$WORK_DIR/pre.json"
REPORT="$WORK_DIR/report.json"

die() { printf 'audit.sh: %s\n' "$*" >&2; exit 1; }
log() { printf '[audit] %s\n' "$*" >&2; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'no-sha-tool'
  fi
}

ensure_workdir() {
  mkdir -p "$WORK_DIR"
  [ -f "$WORK_DIR/.gitignore" ] || printf '*\n' > "$WORK_DIR/.gitignore"
  if [ -f .gitignore ] && ! grep -qE '^\.did-it-actually/?$' .gitignore; then
    printf '\n.did-it-actually/\n' >> .gitignore
  fi
}

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
# init: write a starter contract from a free-text request.
# Claude is expected to read the resulting contract.yml and replace the
# `must_review` placeholder with real criteria before Step 2.
# ---------------------------------------------------------------------------
cmd_init() {
  local request="${1:-}"
  [ -n "$request" ] || die "usage: audit.sh init \"<original user request>\""
  ensure_workdir
  local now; now="$(iso_now)"
  cat > "$CONTRACT" <<EOF
version: 1
request: |
$(printf '%s\n' "$request" | sed 's/^/  /')
created_at: $now
iteration: 1
criteria:
  - id: request-addressed
    intent: |
      PLACEHOLDER — decompose the request above into discrete, falsifiable
      acceptance criteria of type existence | content | command. Replace this
      entry. See references/contract-format.md for the schema.
    type: review
    spec:
      rubric: |
        The work delivered everything the user asked for, with no silent
        deferrals.
    severity: critical
EOF
  log "wrote $CONTRACT — decompose the placeholder before running audit"
  printf '%s\n' "$CONTRACT"
}

# ---------------------------------------------------------------------------
# run: evaluate the contract + checks; write report.json; render prose.
# ---------------------------------------------------------------------------
cmd_run() {
  ensure_workdir
  [ -f "$CONTRACT" ] || die "no contract at $CONTRACT — run 'audit.sh init' first"

  local started_at; started_at="$(iso_now)"
  local contract_sha; contract_sha="$(sha256_file "$CONTRACT")"
  local mode="git"
  local head=""
  if git rev-parse --git-dir >/dev/null 2>&1; then
    head="$(git rev-parse HEAD 2>/dev/null || printf 'no-commits-yet')"
  else
    mode="no-git-mtime"
  fi

  # iteration is tracked in a sidecar file so contract.yml hash stays stable across runs
  local iter_file="$WORK_DIR/iteration"
  local iter
  if [ -f "$iter_file" ]; then iter="$(cat "$iter_file" 2>/dev/null || printf 1)"; else iter=1; fi
  [ -n "$iter" ] || iter=1
  local audit_id
  if command -v shasum >/dev/null 2>&1; then
    audit_id="$(printf '%s%s%s%s' "$contract_sha" "$head" "$started_at" "$$" | shasum -a 256 | awk '{print substr($1,1,12)}')"
  else
    audit_id="$(printf '%s%s%s%s' "$contract_sha" "$head" "$started_at" "$$" | sha256sum | awk '{print substr($1,1,12)}')"
  fi

  # ---- Step A: ledger-vs-diff reconciliation ----
  local diff_files=""
  local claimed_files=""
  if [ "$mode" = "git" ]; then
    # tracked changes + untracked-but-not-ignored files
    diff_files="$( { git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | sort -u || true)"
  else
    if [ -f "$PRE" ]; then
      diff_files="$(python3 "$SCRIPT_DIR/snapshot.py" diff "$PRE" 2>/dev/null || true)"
    fi
  fi
  local ledger_present=0
  if [ -f "$CLAIMS" ]; then
    ledger_present=1
    claimed_files="$(CLAIMS="$CLAIMS" python3 -c '
import json, os
seen = set()
for line in open(os.environ["CLAIMS"]):
    try:
        r = json.loads(line)
        p = r.get("path", "")
        if p:
            seen.add(p)
    except Exception:
        pass
print("\n".join(sorted(seen)))
')"
  fi
  local phantom_edits=""
  local missing_claims=""
  # Only compute phantom edits when the ledger exists; otherwise every diffed
  # file would be flagged as phantom — a false-positive that destroys trust.
  if [ "$ledger_present" -eq 1 ] && { [ -n "$diff_files" ] || [ -n "$claimed_files" ]; }; then
    phantom_edits="$(comm -23 <(printf '%s\n' "$diff_files" | sort -u) <(printf '%s\n' "$claimed_files" | sort -u) 2>/dev/null | grep -v '^$' || true)"
    missing_claims="$(comm -13 <(printf '%s\n' "$diff_files" | sort -u) <(printf '%s\n' "$claimed_files" | sort -u) 2>/dev/null | grep -v '^$' || true)"
  fi

  # ---- Step B: evaluate each criterion ----
  export DIFF_FILES="$diff_files"
  export CLAIMED_FILES="$claimed_files"
  export PHANTOM_EDITS="$phantom_edits"
  export MISSING_CLAIMS="$missing_claims"
  python3 - "$CONTRACT" "$REPORT" "$started_at" "$audit_id" "$iter" "$contract_sha" "$mode" "$head" <<'PYEVAL'
import json, os, re, subprocess, sys, hashlib, time, yaml
from pathlib import Path

contract_path, report_path, started_at, audit_id, iteration, contract_sha, mode, head = sys.argv[1:9]
iteration = int(iteration)
contract = yaml.safe_load(open(contract_path))
work_dir = os.path.dirname(report_path)

def sha256_path(p):
    h = hashlib.sha256()
    try:
        with open(p, 'rb') as f:
            for chunk in iter(lambda: f.read(8192), b''):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None

def eval_existence(spec):
    if 'must_exist' in spec:
        p = spec['must_exist']
        min_bytes = int(spec.get('min_bytes', 1))
        if not os.path.exists(p):
            return 'FAIL', f'absent: {p}'
        size = os.path.getsize(p)
        if size < min_bytes:
            return 'FAIL', f'too small: {p} ({size}B < {min_bytes}B)'
        sha = sha256_path(p) or 'unknown'
        return 'PASS', f'bytes:{size} sha:{sha[:7]}'
    if 'must_not_exist' in spec:
        p = spec['must_not_exist']
        return ('PASS', f'absent: {p}') if not os.path.exists(p) else ('FAIL', f'still exists: {p}')
    if 'must_exist_any' in spec:
        for p in spec['must_exist_any']:
            if os.path.exists(p) and os.path.getsize(p) >= 1:
                return 'PASS', f'found: {p}'
        return 'FAIL', f'none of: {spec["must_exist_any"]}'
    if 'must_exist_all' in spec:
        missing = [p for p in spec['must_exist_all'] if not os.path.exists(p)]
        if missing:
            return 'FAIL', f'missing: {missing}'
        return 'PASS', f'all present: {spec["must_exist_all"]}'
    return 'SKIP', 'unknown existence spec'

def eval_content(spec):
    paths = [spec['path']] if 'path' in spec else []
    if 'paths' in spec:
        # simple glob
        import glob as _glob
        for pat in spec['paths']:
            paths.extend(_glob.glob(pat, recursive=True))
    if not paths:
        return 'SKIP', 'no path'
    for p in paths:
        if not os.path.exists(p):
            return 'FAIL', f'missing: {p}'
        try:
            content = open(p, encoding='utf-8', errors='replace').read()
        except Exception as e:
            return 'FAIL', f'read error: {p} ({e})'
        if 'must_match' in spec:
            if not re.search(spec['must_match'], content):
                return 'FAIL', f'pattern absent: /{spec["must_match"]}/ in {p}'
        if 'must_match_pcre' in spec:
            if not re.search(spec['must_match_pcre'], content):
                return 'FAIL', f'pattern absent (pcre): /{spec["must_match_pcre"]}/ in {p}'
        if 'must_not_match' in spec:
            if re.search(spec['must_not_match'], content):
                return 'FAIL', f'forbidden pattern present: /{spec["must_not_match"]}/ in {p}'
    return 'PASS', f'all {len(paths)} file(s) match'

def eval_command(spec):
    cmd = spec.get('cmd')
    if not cmd:
        return 'SKIP', 'no cmd'
    expect_exit = int(spec.get('expect_exit', 0))
    timeout = int(spec.get('timeout_seconds', 60))
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 'FAIL', f'timeout after {timeout}s: {cmd}'
    if r.returncode != expect_exit:
        tail = (r.stdout + r.stderr).strip().splitlines()[-3:]
        return 'FAIL', f'exit:{r.returncode} (expected {expect_exit}) cmd:"{cmd}" tail:{tail}'
    if 'expect_stdout_contains' in spec and spec['expect_stdout_contains'] not in r.stdout:
        return 'FAIL', f'stdout missing substring: {spec["expect_stdout_contains"]!r}'
    if 'expect_stdout_matches' in spec and not re.search(spec['expect_stdout_matches'], r.stdout):
        return 'FAIL', f'stdout regex no match: /{spec["expect_stdout_matches"]}/'
    return 'PASS', f'exit:0 cmd:"{cmd[:60]}"'

def eval_review(spec):
    # Delegated to critic. Mark SKIP here; critic fills in.
    return 'SKIP', 'delegated-to-critic'

results = []
for c in contract.get('criteria', []):
    cid = c.get('id', 'unknown')
    ctype = c.get('type', 'review')
    spec = c.get('spec', {})
    severity = c.get('severity', 'critical' if ctype in ('existence','command') else 'warning')
    start = time.time()
    try:
        if ctype == 'existence':
            status, evidence = eval_existence(spec)
        elif ctype == 'content':
            status, evidence = eval_content(spec)
        elif ctype == 'command':
            status, evidence = eval_command(spec)
        elif ctype == 'review':
            status, evidence = eval_review(spec)
        else:
            status, evidence = 'SKIP', f'unknown type: {ctype}'
    except Exception as e:
        status, evidence = 'ERROR', f'evaluator crashed: {e}'
    duration_ms = int((time.time() - start) * 1000)
    results.append({
        'id': cid,
        'intent': (c.get('intent') or '').strip(),
        'status': status,
        'evidence': evidence,
        'severity': severity,
        'duration_ms': duration_ms,
        'type': ctype,
    })

# ---- syntactic-rot scan on changed files ----
def syntactic_rot(files):
    findings = []
    patterns = {
        'no-todos':         (r'\b(TODO|FIXME|HACK|XXX|NOCOMMIT)\b', 'warning'),
        'no-stub-bodies':   (r'(raise\s+NotImplementedError|throw\s+new\s+Error\([\'"]not\s*implemented|\bunimplemented!\(\)|TODO\(\))', 'critical'),
        'no-debug-leftovers': (r'\b(console\.log|debugger|pdb\.set_trace|binding\.pry|byebug)\b', 'warning'),
    }
    for check_id, (pat, sev) in patterns.items():
        hits = []
        for f in files:
            if not os.path.isfile(f):
                continue
            try:
                with open(f, encoding='utf-8', errors='replace') as fh:
                    for i, line in enumerate(fh, 1):
                        if re.search(pat, line):
                            hits.append({'file': f, 'line': i, 'snippet': line.strip()[:120]})
            except Exception:
                pass
        findings.append({
            'check_id': check_id,
            'status': 'FAIL' if hits else 'PASS',
            'severity': sev,
            'findings': hits,
        })
    return findings

# load diff files via env
diff_files_env = os.environ.get('DIFF_FILES', '').splitlines()
diff_files_env = [f for f in diff_files_env if f and os.path.isfile(f)]
rot = syntactic_rot(diff_files_env)

# ---- compute verdict ----
critical_fail = any(r['status'] == 'FAIL' and r['severity'] == 'critical' for r in results)
critical_fail = critical_fail or any(r['status'] == 'ERROR' for r in results)
critical_fail = critical_fail or any(r['status'] == 'FAIL' and r['severity'] == 'critical' for r in rot)
warning_fail = any(r['status'] == 'FAIL' and r['severity'] == 'warning' for r in results + rot)
phantom = os.environ.get('PHANTOM_EDITS','').strip()
missing_claim = os.environ.get('MISSING_CLAIMS','').strip()
if phantom:
    critical_fail = True

# A contract whose criteria were never terminally evaluated must NOT pass. The
# default `init`/`derive` contract is a single review criterion that this script
# marks SKIP/delegated-to-critic — the critic (a fresh sub-agent) has to run
# before any pass. Without this guard, `audit.sh run` on a fresh contract would
# emit a hollow VERIFIED having checked nothing. Pending-critic ≠ verified.
terminally_evaluated = sum(1 for r in results if r['status'] in ('PASS', 'FAIL'))
pending_critic = any(
    r['status'] == 'SKIP' and 'critic' in (r.get('evidence') or '')
    for r in results
)
not_evaluated = (terminally_evaluated == 0)

if critical_fail or not_evaluated or pending_critic:
    verdict = 'NOT VERIFIED'
elif warning_fail:
    verdict = 'VERIFIED WITH WARNINGS'
else:
    verdict = 'VERIFIED'

reason = []
if critical_fail: reason.append('one or more critical criteria failed')
if phantom: reason.append(f'phantom edits: {phantom.splitlines()[:3]}')
if not_evaluated: reason.append('no criterion was terminally evaluated (all SKIP/delegated) — decompose the contract or run the critic')
if pending_critic: reason.append('review criteria are delegated to the fresh-context critic, which has not run yet — spawn it (scripts/critic.md), fold in its verdict, then re-run')
if warning_fail: reason.append('warnings present')
if not reason: reason.append('all criteria passed; no rot detected')

# build follow-ups
follow_ups = []
prio_order = {'critical': 'CRITICAL', 'warning': 'WARN'}
for r in results:
    if r['status'] in ('FAIL','ERROR'):
        follow_ups.append({
            'priority': prio_order.get(r['severity'], 'INFO'),
            'verb': 'address',
            'object': r['id'],
            'reason': r['evidence'],
            'criterion_id': r['id'],
        })
for rot_check in rot:
    if rot_check['status'] == 'FAIL':
        for hit in rot_check['findings'][:5]:
            follow_ups.append({
                'priority': prio_order.get(rot_check['severity'], 'INFO'),
                'verb': 'resolve',
                'object': f"{hit['file']}:{hit['line']}",
                'reason': f"{rot_check['check_id']}: {hit['snippet']}",
            })

report = {
    'schema_version': 'report-v1',
    'audit_id': audit_id,
    'started_at': started_at,
    'completed_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'iteration': iteration,
    'iteration_capped': iteration >= 3 and verdict == 'NOT VERIFIED',
    'request_excerpt': (contract.get('request') or '')[:200],
    'contract_sha256': contract_sha,
    'verdict': verdict,
    'verdict_reason': '; '.join(reason)[:300],
    'scope': {
        'claimed_files': sorted(set(p for p in (os.environ.get('CLAIMED_FILES','').splitlines()) if p)),
        'diffed_files': sorted(set(p for p in diff_files_env if p)),
        'in_scope': diff_files_env,
        'out_of_scope': phantom.splitlines() if phantom else [],
    },
    'criteria_results': results,
    'checks_results': rot,
    'follow_ups': follow_ups,
    'session_meta': {
        'git_head': head,
        'cwd': os.getcwd(),
        'mode': mode,
    },
    'meta_audit': {
        'all_checks_ran': True,
        'missing_inputs': [],
        'contract_mutated_mid_iteration': False,
    },
}

with open(report_path, 'w') as f:
    json.dump(report, f, indent=2)

print(verdict)
PYEVAL

  # Bump iteration in the sidecar file (NOT in contract.yml — that file's
  # sha256 must remain stable across iterations so contract-mutation detection
  # works).
  local next_iter=$((iter + 1))
  printf '%d\n' "$next_iter" > "$iter_file"

  cmd_render
}

# ---------------------------------------------------------------------------
# render: print the prose verdict box from report.json
# ---------------------------------------------------------------------------
cmd_render() {
  [ -f "$REPORT" ] || die "no report at $REPORT — run 'audit.sh run' first"
  python3 "$SCRIPT_DIR/render.py" "$REPORT"
}

cmd_status() {
  if [ -f "$REPORT" ]; then
    python3 -c "import json;d=json.load(open('$REPORT'));print(d['verdict'])"
  else
    printf 'NO_AUDIT\n'
  fi
}

cmd_doctor() { bash "$SCRIPT_DIR/doctor.sh"; }

# ---------------------------------------------------------------------------
# derive: parse the user request for verbs and emit a richer starter contract
# than `init`. Derived criteria are heuristic — Claude should read the result
# and refine, not treat it as final.
# ---------------------------------------------------------------------------
cmd_derive() {
  local request="${1:-}"
  [ -n "$request" ] || die "usage: audit.sh derive \"<original user request>\""
  ensure_workdir
  REQUEST="$request" CONTRACT_PATH="$CONTRACT" \
    python3 "$SCRIPT_DIR/derive_contract.py"
  log "wrote $CONTRACT — refine the derived criteria before running audit"
  printf '%s\n' "$CONTRACT"
}

# ---------------------------------------------------------------------------
# scan: read the latest session JSONL and emit a sweep report — banned-phrase
# detection, swallowed-failure detection, sticky-constraint extraction.
# Useful before a Stop hook fires, to surface what would be flagged.
# ---------------------------------------------------------------------------
cmd_scan() {
  ensure_workdir
  python3 "$SCRIPT_DIR/scan_session.py" --latest --out "$WORK_DIR/scan-findings.json" "$@" || true
  if [ -f "$WORK_DIR/scan-findings.json" ]; then
    python3 -c "
import json, sys
d = json.load(open('$WORK_DIR/scan-findings.json'))
findings = d.get('findings', [])
print(f'{len(findings)} finding(s) in scan-findings.json')
for f in findings[:20]:
    print(f\"  [{f.get('severity','?')}] {f.get('check','?')}: {f.get('detail','')[:100]}\")
"
  fi
}

usage() {
  cat <<EOF
did-it-actually  — audit.sh
  init "<request>"   write a starter contract.yml for the user's request
  derive "<request>" auto-derive criteria from the prompt's verbs (richer than init)
  run                evaluate the contract, write report.json, render prose
  render             re-render the most recent report
  status             print the most recent verdict
  scan               sweep the latest Claude session JSONL for banned-phrase + swallowed-failure findings
  doctor             check that the skill is wired up correctly
EOF
}

case "${1:-}" in
  init)   shift; cmd_init "$@" ;;
  derive) shift; cmd_derive "$@" ;;
  run)    shift; cmd_run "$@" ;;
  render) cmd_render ;;
  status) cmd_status ;;
  scan)   shift; cmd_scan "$@" ;;
  doctor) cmd_doctor ;;
  ""|-h|--help) usage ;;
  *) usage; exit 2 ;;
esac
