#!/usr/bin/env python3
"""check-deploy-labels.py — RK9-37 deploy-runner guardrail.

Enforces: deploy jobs that CONTACT a dev/prod host (SSH/scp/rsync, or invoke the
cicd build-and-deploy reusable's deploy step) must run on a self-hosted runner.
Cloud runners (blacksmith-*, ubuntu-*, macos-*) cannot reach the hosts behind the
nginx dev-proxy (returns 403 to cloud IPs) and lack the deploy SSH keys.

NUANCE (verified 2026-06-13): a *build* job inside a deploy workflow MAY use a
cloud runner (e.g. quantimodo deploy-dev builds the image on blacksmith-4vcpu,
then a separate self-hosted job SSHes to the host). Only host-contacting jobs are
constrained. This guard flags cloud runners only on jobs that contact a host.

GATE MODE (v4, RK9-545): a call of the build-and-deploy reusable with
`deploy_transport: gate`, or a job that uses actions/gated-deploy directly,
must name a lan-deploy runner (`lan-deploy` or `lan-deploy-<suffix>`). A missing
runner_label (the reusable's default self-hosted), self-hosted, paperclip,
docker, a cloud label or a non-literal expression is a violation: the gate key
must never land on a shared or cloud runner. A deploy_transport that is not the
literal `ssh` counts as gate. Gate checks cover every workflow file (a manual
gate rollback workflow need not be called deploy*); the RK9-37 checks keep
their deploy*/release* scope.

Usage: check-deploy-labels.py [<repo_dir>]   (default: cwd)
Exit 0 = clean, 1 = violation(s) found, 2 = usage error.
"""
import sys, os, re, glob

CLOUD = re.compile(r'blacksmith-|ubuntu-|macos-|windows-')
# Markers that mean "this job talks to a deploy host"
HOST_CONTACT = re.compile(
    r'\bssh\b|\bscp\b|\brsync\b|deploy_host|DEPLOY_HOST|E2E_BASE_URL|'
    r'ssh-deploy|gated-deploy|wait-for-health|docker\s+compose\s+(pull|up)|knownhosts|ssh-keyscan',
    re.I)
# cicd reusable deploy whose runner is controlled by runner_label input
REUSABLE = re.compile(r'uses:\s*\S*cicd/\.github/workflows/build-and-deploy\.yml', re.I)
GATED_ACTION = re.compile(r'gated-deploy@', re.I)
DEPLOY_TRANSPORT = re.compile(r'[\'"]?deploy_transport[\'"]?\s*:\s*([^,}\n#]*)', re.I)
LAN_DEPLOY = re.compile(r'^lan-deploy(-[a-z0-9]+)*$')

def parse_jobs(text):
    """Yield (job_name, job_body_lines) for each job under top-level jobs:."""
    lines = text.split('\n')
    # find 'jobs:' at col 0
    n = len(lines)
    i = 0
    while i < n and not re.match(r'^[\'"]?jobs[\'"]?:\s*(#.*)?$', lines[i]): i += 1
    i += 1
    jobs = []
    cur = None; body = []
    indent = None  # indentation of job keys, taken from the first one
    while i < n:
        l = lines[i]
        if re.match(r'^\S', l):  # dedent to col 0 -> end of jobs:
            break
        if indent is None and l.strip() and not l.lstrip().startswith('#'):
            indent = len(l) - len(l.lstrip(' '))
        m = re.match(r'^ {%d}[\'"]?([A-Za-z0-9_-]+)[\'"]?:\s*(#.*)?$' % (indent or 2), l)
        if m:
            if cur is not None: jobs.append((cur, body))
            cur = m.group(1); body = []
        elif cur is not None:
            body.append(l)
        i += 1
    if cur is not None: jobs.append((cur, body))
    return jobs

def job_runs_on(body):
    for l in body:
        m = re.search(r'runs-on:\s*(.+)', l)
        if m: return m.group(1).strip()
    # reusable-call jobs have no runs-on; check runner_label input
    return None

def job_runs_on_labels(body):
    """Labels of runs-on, inline ([a, b] / "x") or as a block list (- a)."""
    for idx, l in enumerate(body):
        m = re.match(r'^(\s*)runs-on:\s*(.*)$', l)
        if not m: continue
        val = m.group(2).split('#')[0].strip()
        if val:
            return [t for t in re.split(r'[\s,\[\]\'"]+', val) if t]
        labels = []
        for nxt in body[idx + 1:]:
            lm = re.match(r'^\s*-\s*([\'"]?)([^\'"#\s]+)\1', nxt)
            if not lm: break
            labels.append(lm.group(2))
        return labels
    return []

def is_gate_call(bodytext):
    """True unless every deploy_transport value is the literal ssh."""
    for m in DEPLOY_TRANSPORT.finditer(bodytext):
        if m.group(1).strip().strip('\'"') != 'ssh':
            return True
    return False

def runner_label_raw(body):
    """Literal runner_label value, '' for a non-literal expression, None if absent."""
    for l in body:
        m = re.match(r'^\s*runner_label:\s*(.*?)\s*(#.*)?$', l)
        if m:
            val = m.group(1).strip().strip('\'"')
            return val if re.fullmatch(r'[A-Za-z0-9_.-]+', val) else ''
    return None

def runner_label_input(body):
    for l in body:
        m = re.search(r'runner_label:\s*([\'"]?)([A-Za-z0-9_-]+)\1', l)
        if m: return m.group(2)
    return None

def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else '.'
    wfdir = os.path.join(repo, '.github', 'workflows')
    deploy_files = set()
    for pat in ('deploy*.yml', 'deploy*.yaml', 'release*.yml', 'release*.yaml'):
        deploy_files.update(glob.glob(os.path.join(wfdir, pat)))
    gate_files = set()
    for f in glob.glob(os.path.join(wfdir, '*.yml')) + glob.glob(os.path.join(wfdir, '*.yaml')):
        with open(f) as fh:
            text = fh.read()
        if GATED_ACTION.search(text) or DEPLOY_TRANSPORT.search(text):
            gate_files.add(f)
    files = sorted(deploy_files | gate_files)
    if not files:
        print(f"[check-deploy-labels] no deploy/release workflows in {wfdir} — nothing to check")
        return 0
    violations = []
    for f in files:
        with open(f) as fh:
            text = fh.read()
        # Fail closed: a file that looks like it holds a gate job must yield
        # a parsed gate job, or it is a violation.
        file_has_gate = bool(GATED_ACTION.search(text)) or is_gate_call(text)
        gate_job_seen = False
        for name, body in parse_jobs(text):
            bodytext = '\n'.join(body)
            ro = job_runs_on(body)
            is_reusable = bool(REUSABLE.search(bodytext))
            contacts = bool(HOST_CONTACT.search(bodytext)) or is_reusable
            if not contacts:
                continue  # pure build/test job — cloud runner OK
            if f not in deploy_files and not (GATED_ACTION.search(bodytext) or (is_reusable and is_gate_call(bodytext))):
                continue  # outside deploy*/release* only gate jobs are checked
            if GATED_ACTION.search(bodytext) or (is_reusable and is_gate_call(bodytext)):
                gate_job_seen = True
            if is_reusable and is_gate_call(bodytext):
                rl = runner_label_raw(body)
                if not rl or not LAN_DEPLOY.match(rl):
                    shown = 'missing (default self-hosted)' if rl is None else (f"'{rl}'" if rl else 'a non-literal expression')
                    violations.append(f"{f}::{name} calls cicd deploy reusable with deploy_transport: gate but runner_label is {shown} (must be a lan-deploy label)")
            elif GATED_ACTION.search(bodytext):
                labels = job_runs_on_labels(body)
                if ('${{' in (ro or '') or not any(LAN_DEPLOY.match(x) for x in labels)
                        or any(CLOUD.search(x) for x in labels)):
                    violations.append(f"{f}::{name} uses actions/gated-deploy on runner '{ro}' (must include a lan-deploy label)")
            elif is_reusable:
                rl = runner_label_input(body)
                if rl and CLOUD.search(rl):
                    violations.append(f"{f}::{name} calls cicd deploy reusable with cloud runner_label '{rl}'")
                # self-hosted or default -> ok
            elif ro and CLOUD.search(ro):
                violations.append(f"{f}::{name} host-contacting job on cloud runner '{ro}' (must be self-hosted — dev-proxy 403s cloud IPs)")
        if file_has_gate and not gate_job_seen:
            violations.append(f"{f} mentions gated-deploy or a gate deploy_transport, but no gate job could be parsed (check the jobs: layout)")
    if violations:
        print("DEPLOY-RUNNER GUARD: violation(s) found — deploy jobs that contact a host must be self-hosted (gate mode: lan-deploy):")
        for v in violations: print(f"  ✗ {v}")
        return 1
    print(f"[check-deploy-labels] OK — {len(files)} deploy workflow(s), all host-contacting jobs self-hosted")
    return 0

if __name__ == '__main__':
    sys.exit(main())
