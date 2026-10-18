# Deploy-runner policy (RK9-37)

**Rule:** deploy jobs that **contact a dev/prod host** (SSH/scp/rsync, the cicd
`build-and-deploy` reusable's deploy step, or `wait-for-health`/`docker compose
pull|up` against a remote) **MUST run on a self-hosted runner**. Cloud runners
(`blacksmith-*`, `ubuntu-*`, `macos-*`) **cannot** deploy because:

- the nginx dev-proxy (`nginx.rk9.fi`) returns **403 to cloud runner IPs** (see
  vault `feedback_dev_proxy_blocks_cloud_runners`), and
- the deploy SSH keys live on the self-hosted runners / hosts, not in cloud VMs.

**Nuance — build-on-cloud is allowed.** A *build* job inside a deploy workflow
MAY use a cloud runner (e.g. `quantimodo deploy-dev` builds the image on
`blacksmith-4vcpu`, pushes to GHCR, then a separate **self-hosted** job SSHes to
the host). Only **host-contacting** jobs are constrained. The guard
(`scripts/check-deploy-labels.py`) flags cloud runners **only** on jobs that
contact a host, so it never false-positives on build jobs.

## Gate mode (v4, RK9-545)

`build-and-deploy.yml@v4` with `deploy_transport: gate` (or a job that uses
`actions/gated-deploy` directly) talks only to the server-side deploy-gate
(verb contract v1: `deploy <tag>`, `health`, `rollback`, `status`). The gate
key is a forced-command key, so the runner never gets a shell on the host.

- **Runner:** gate-mode deploy jobs MUST run on a `lan-deploy` runner
  (`lan-deploy` or `lan-deploy-<suffix>`; the job uses
  `[self-hosted, <label>]`). These are the low-privilege, per-repo LAN runners.
  `runner_label` has no effective default in gate mode: empty, `self-hosted`,
  `paperclip`, `docker` or a cloud label fails the build job's first step, so the
  deploy job never queues and the gate key never lands on a shared or cloud
  runner.
- **Host key:** pinned via the `DEPLOY_GATE_KNOWN_HOSTS` secret. No scanning,
  no TOFU; a missing pin fails.
- **Key handling:** `mktemp -p "$RUNNER_TEMP"` (600), removed in an
  `if: always()` step; the last step fails if the key file still exists.
- **Registry token:** the job's `GITHUB_TOKEN` (job permissions
  `packages: read`) goes to ssh stdin only.
- **Rollback:** a failed `deploy` is restored by the gate itself (`restored`
  field). The client sends `rollback` only when the post-deploy health poll
  fails after a deploy that switched the tag (`"changed":true`).
- **Compose files (K4):** gate mode does not sync `deploy/`. The host owns the
  compose files; changes go through the operator runbook by hand until a
  validating sync verb exists.
- **Manual rollback:** `rollback.yml` stays ssh-only. Gate consumers use their
  own `workflow_dispatch` job calling `gated-deploy@v4` with `verb: rollback`.

## Enforcement
- `scripts/check-deploy-labels.py <repo_dir>` — exit 1 on violation.
- `.github/workflows/guard-deploy-labels.yml` — reusable; consumer repos call it
  from `pr-checks` to fail PRs that introduce a cloud label on a host-contacting
  deploy job. The v4 guard fetches the script from the `v4` tag (not `v1`) and
  also fails gate-mode calls without a literal lan-deploy `runner_label`, and
  `gated-deploy` jobs whose `runs-on` lacks a lan-deploy label.
- `scripts/test_check_deploy_labels.py` — unit tests
  (`python3 -m unittest discover -s scripts`). **Single enforcement owner (RK9-37)** — the cicd templates'
  deploy-stub references this guard, it does not reimplement it.

## Audit (2026-06-13) — all host-contacting deploy jobs self-hosted ✓

| Repo | Workflow | Host-contacting deploy job runner | Build job (if any) |
|------|----------|-----------------------------------|--------------------|
| sunspot | deploy-dev / deploy-prod | `[self-hosted, docker]` / `[self-hosted, rk9-prod]` | (host-build) |
| bk (Ololla) | deploy-dev / deploy-prod | `[self-hosted, docker]` / `[self-hosted, rk9-prod]` | (legacy native) |
| alli-audit | deploy-dev / deploy-prod | `[self-hosted, docker]` / `[self-hosted, alli-audit-dev]` | — |
| saatavilla | deploy-dev / deploy-prod | `self-hosted` / `[self-hosted, rk9-prod]` | — |
| quantimodo-rust | deploy-dev / deploy-prod | `[self-hosted, docker]` | `blacksmith-4vcpu` (build → GHCR, OK) |

The cicd `build-and-deploy.yml` reusable pins the deploy job's runner via its
`runner_label` input (`self-hosted` → `[self-hosted, paperclip]`), so repos using
the reusable are guarded by construction.

## Audit (2026-10-18, RK9-545) — no consumer on gate mode yet

| Repo | Workflow | cicd ref | Host-contacting deploy job runner | Planned |
|------|----------|----------|-----------------------------------|---------|
| saatavilla | deploy-dev | `build-and-deploy.yml@v2` | `runner_label: docker` (ssh mode) | v4 gate + lan-deploy (RK9-546) |
| bk (Ololla) | deploy-dev | `build-and-deploy.yml@v2` | `runner_label: docker` (ssh mode); seed job `[self-hosted, docker]` | v4 gate + lan-deploy (RK9-218) |
| alli-audit | deploy-dev | `build-and-deploy.yml@v2` | `runner_label: docker` (ssh mode) | stays on v2 |
| uutisvertailu | deploy-dev | `build-and-deploy.yml@v2` | `runner_label: docker` (ssh mode) | stays on v2 |
| sunspot | deploy-dev | `wait-for-health@v3` | `[self-hosted, docker]` | stays on v3 |
| quantimodo-rust | deploy-dev / deploy-prod | actions `@v1` | `[self-hosted, docker]` | stays on v1 |
| rk9-site | deploy | `wait-for-health@v1` | `[self-hosted, docker]` | stays on v1 |

v1, v2 and v3 are frozen; none of these consumers changes when v4 ships.

## /implement runner-offline gate (operator tooling)
`pcp-wait.sh` / `pcp-unjam.sh` treat a deploy job stuck because its **target
self-hosted runner is offline** as an *actionable* state (escalate to operator to
bring the runner online), not an indefinite queue wait. See the pcp-* tooling.

## Follow-up
- Per-repo `pr-checks` wiring of `guard-deploy-labels.yml` (one job line each).
- Slack alert when a deploy runner is offline >15 min (cicd `actions/slack-notify`
  + a process-adapter watch) — deferred, low priority.
- paperclip deploy-workflow coverage added when/if RK9-32 (org transfer) happens.
