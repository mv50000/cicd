# Onboarding a new repo to Blacksmith CI (RK9-38)

Goal: a new repo gets Blacksmith-first CI in **<30 min** by copy + customize.

## 0. Prereqs (one-time per org)
- Repo lives in the **`rk9-ai`** GitHub org (Blacksmith requires an org; personal
  repos unsupported). Transfer first if needed — see `docs/org-transfer-fallout.md`.
- Blacksmith GitHub App installed + scoped to the repo (else jobs queue forever).

## 1. Copy the templates
From `templates/workflows/` into the new repo's `.github/workflows/`:
| Template | Copy to | When |
|----------|---------|------|
| `pr-checks-rust.yml` | `pr-checks.yml` | Rust repo |
| `pr-checks-node.yml` | `pr-checks.yml` | Node/Next repo |
| `ai-auto-merge.yml`  | `ai-auto-merge.yml` | always (auto-merge AI PRs) |
| `deploy-stub.yml`    | `deploy-dev.yml` | if it deploys |

Also add `.github/CODEOWNERS` listing protected paths (the ai-auto-merge
protected-path gate mirrors it):
```
/.github/workflows/  @mv50000
/.github/CODEOWNERS  @mv50000
/deploy/             @mv50000
```

## 2. Customize the placeholders
- `pr-checks`: adjust job set; tune the Rust path-filter to your tree.
- `ai-auto-merge`: set `BASE` (main/master), `AUTHOR_ALLOWLIST`, deploy dispatch wf.
- `deploy-stub`: replace `REPLACE_ME` (company, image, paths); keep `runner_label`
  a **self-hosted** label — NEVER `blacksmith-*` (RK9-37 dev-proxy 403).

## 3. Sizing heuristic (RK9-38)
| Work | Blacksmith label |
|------|------------------|
| Rust compile / test | `blacksmith-8vcpu-ubuntu-2404` |
| lint / clippy, node build/test, docker build | `blacksmith-4vcpu-ubuntu-2404` |
| fmt / trivial lint | `blacksmith-2vcpu-ubuntu-2404` |
| **deploy (host-contacting)** | **`[self-hosted, ...]`** (never cloud) |

## 4. Wire the deploy guard (recommended)
Add to `pr-checks.yml` so a cloud label can't sneak into a deploy job:
```yaml
  deploy-guard:
    uses: mv50000/cicd/.github/workflows/guard-deploy-labels.yml@v1
```

## 5. Cost
Free tier 6000 vCPU-min/mo; cap $22/mo + 80% alert. Verify-before-expand: read
real vCPU-min before migrating heavy Rust repos (see `project_blacksmith_ci` vault
note + RK9-27 governance). npm-only repos are cheap; Rust+coverage are the drivers.
