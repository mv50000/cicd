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

Usage: check-deploy-labels.py [<repo_dir>]   (default: cwd)
Exit 0 = clean, 1 = violation(s) found, 2 = usage error.
"""
import sys, os, re, glob

CLOUD = re.compile(r'blacksmith-|ubuntu-|macos-|windows-')
# Markers that mean "this job talks to a deploy host"
HOST_CONTACT = re.compile(
    r'\bssh\b|\bscp\b|\brsync\b|deploy_host|DEPLOY_HOST|E2E_BASE_URL|'
    r'ssh-deploy|wait-for-health|docker\s+compose\s+(pull|up)|knownhosts|ssh-keyscan',
    re.I)
# cicd reusable deploy whose runner is controlled by runner_label input
REUSABLE = re.compile(r'uses:\s*\S*cicd/\.github/workflows/build-and-deploy\.yml')

def parse_jobs(text):
    """Yield (job_name, job_body_lines) for each job under top-level jobs:."""
    lines = text.split('\n')
    # find 'jobs:' at col 0
    n = len(lines)
    i = 0
    while i < n and not re.match(r'^jobs:\s*$', lines[i]): i += 1
    i += 1
    jobs = []
    cur = None; body = []
    while i < n:
        l = lines[i]
        if re.match(r'^\S', l):  # dedent to col 0 -> end of jobs:
            break
        m = re.match(r'^  ([A-Za-z0-9_-]+):\s*$', l)
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

def runner_label_input(body):
    for l in body:
        m = re.search(r'runner_label:\s*([\'"]?)([A-Za-z0-9_-]+)\1', l)
        if m: return m.group(2)
    return None

def main():
    repo = sys.argv[1] if len(sys.argv) > 1 else '.'
    wfdir = os.path.join(repo, '.github', 'workflows')
    files = sorted(glob.glob(os.path.join(wfdir, 'deploy*.yml')) +
                   glob.glob(os.path.join(wfdir, 'release*.yml')))
    if not files:
        print(f"[check-deploy-labels] no deploy/release workflows in {wfdir} — nothing to check")
        return 0
    violations = []
    for f in files:
        text = open(f).read()
        for name, body in parse_jobs(text):
            bodytext = '\n'.join(body)
            ro = job_runs_on(body)
            is_reusable = bool(REUSABLE.search(bodytext))
            contacts = bool(HOST_CONTACT.search(bodytext)) or is_reusable
            if not contacts:
                continue  # pure build/test job — cloud runner OK
            if is_reusable:
                rl = runner_label_input(body)
                if rl and CLOUD.search(rl):
                    violations.append(f"{f}::{name} calls cicd deploy reusable with cloud runner_label '{rl}'")
                # self-hosted or default -> ok
            elif ro and CLOUD.search(ro):
                violations.append(f"{f}::{name} host-contacting job on cloud runner '{ro}' (must be self-hosted — dev-proxy 403s cloud IPs)")
    if violations:
        print("DEPLOY-RUNNER GUARD: violation(s) found — deploy jobs that contact a host must be self-hosted:")
        for v in violations: print(f"  ✗ {v}")
        return 1
    print(f"[check-deploy-labels] OK — {len(files)} deploy workflow(s), all host-contacting jobs self-hosted")
    return 0

if __name__ == '__main__':
    sys.exit(main())
