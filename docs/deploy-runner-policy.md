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

## Enforcement
- `scripts/check-deploy-labels.py <repo_dir>` — exit 1 on violation.
- `.github/workflows/guard-deploy-labels.yml` — reusable; consumer repos call it
  from `pr-checks` to fail PRs that introduce a cloud label on a host-contacting
  deploy job. **Single enforcement owner (RK9-37)** — the cicd templates'
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

## /implement runner-offline gate (operator tooling)
`pcp-wait.sh` / `pcp-unjam.sh` treat a deploy job stuck because its **target
self-hosted runner is offline** as an *actionable* state (escalate to operator to
bring the runner online), not an indefinite queue wait. See the pcp-* tooling.

## Follow-up
- Per-repo `pr-checks` wiring of `guard-deploy-labels.yml` (one job line each).
- Slack alert when a deploy runner is offline >15 min (cicd `actions/slack-notify`
  + a process-adapter watch) — deferred, low priority.
- paperclip deploy-workflow coverage added when/if RK9-32 (org transfer) happens.
