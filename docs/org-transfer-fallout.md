# Org-transfer fallout playbook

What breaks (and what doesn't) when a repo is transferred from a personal
GitHub account (`mv50000`) to an org (`rk9-ai`) via **Settings → Transfer
ownership** / "Move work", and the exact per-repo steps to recover.

Canonical source: rk9-knowledge vault note `feedback_github_org_transfer_fallout`
(`/opt/repos/rk9-knowledge/rk9/resources/feedback_github_org_transfer_fallout.md`).
This doc codifies that note into a runnable checklist backed by two scripts in
`scripts/`.

## TL;DR

| | Survives transfer | Breaks |
|---|---|---|
| **Runners** | ✅ repo-level self-hosted runners follow the repo and stay online; org-level/Blacksmith runners are selected by label and are unaffected | — |
| **Git remotes** | ✅ old `mv50000/...` URLs keep working via GitHub redirect | (update local clones for cleanliness) |
| **Webhooks** | ✅ repo-level webhooks move with the repo | — |
| **GHCR image push** | — | ❌ **403** — `GITHUB_TOKEN` is now scoped to the new owner and can't write a package still owned by the old account |
| **Cross-owner reusable workflows** | ✅ **iff the called repo is PUBLIC** (`mv50000/cicd` is public) | ❌ if the called repo is PRIVATE — GitHub disallows cross-owner private reusable workflows |

**Why:** `GITHUB_TOKEN` scope and GHCR package ownership are tied to the repo's
*owner*. Transfer changes the owner, but not the hardcoded `ghcr.io/<owner>`
refs in workflows/compose, nor the package's owner. The symptom looks like
"deploy/runner broken" but the runner is fine — it's the **push** step that 403s.

## What actually breaks, in detail

### 1. GHCR image push → 403
Workflows building `ghcr.io/mv50000/<pkg>` fail at the push step because the
new-owner `GITHUB_TOKEN` cannot write a package owned by `mv50000`.
**Fix:** migrate the image namespace to `ghcr.io/rk9-ai/<pkg>` in:
- every `.github/workflows/*.yml` (tags, `cache-from`/`cache-to`, `image_name`),
- the deploy-host compose `/srv/<company>/<env>/docker-compose.yml` (NOT in git — see risks),

then run one dev build to create the new (private) package, and verify host
`docker pull` auth for the new namespace **before** tagging prod.

### 2. Cross-owner private reusable workflows
A repo now in `rk9-ai` calling `uses: mv50000/cicd/...@v1` works **only because
`mv50000/cicd` is public**. If it were private, the call would fail. Keep
`mv50000/cicd` public (it holds no secrets — everything flows via `secrets.`/
`inputs.`), or move it into `rk9-ai`. The `post-transfer-check.sh` script checks
the called repo's visibility and only fails when a cross-owner call is private.

## Per-repo fallout checklist

For each transferred repo `rk9-ai/<repo>` with a local clone at `/opt/repos/<dir>`:

1. **Run the checker** (verifies, never mutates):
   ```bash
   bash scripts/post-transfer-check.sh rk9-ai/<repo> /opt/repos/<dir>
   ```
   It checks: runners online (repo-level, falling back to org-level), webhook
   delivery status (last 5 per hook), active `ghcr.io/mv50000/` refs in
   workflows, `uses: mv50000/` refs (warn if the target is public), and the
   local clone's `origin` URL.

2. **Migrate the GHCR namespace** (only if step 1 found active refs):
   ```bash
   # dry-run first — prints a before/after diff, changes nothing
   bash scripts/ghcr-rewrite-apply.sh /opt/repos/<dir> --new-owner rk9-ai
   # apply (creates .bak backups, prompts for confirmation)
   bash scripts/ghcr-rewrite-apply.sh /opt/repos/<dir> --new-owner rk9-ai --apply
   ```
   The new owner is auto-detected from the clone's `origin` remote when
   `--new-owner` is omitted. Commit the workflow changes via a normal PR.

3. **Fix the host compose** (not managed by git). On the deploy host:
   ```bash
   bash scripts/ghcr-rewrite-apply.sh /opt/repos/<dir> --new-owner rk9-ai \
        --srv-company <company> --apply
   ```
   This also rewrites `/srv/<company>/{dev,prod}/docker-compose.yml`.

4. **Create the new package + verify pull.** Trigger one dev build/deploy so the
   `ghcr.io/rk9-ai/<pkg>` package is created (private by default), then on the
   host:
   ```bash
   docker pull ghcr.io/rk9-ai/<pkg>:<tag>
   ```
   Must succeed (host already authenticates to GHCR via the deploy login).

5. **Update the local clone remote** (cleanliness — redirect would work anyway):
   ```bash
   git -C /opt/repos/<dir> remote set-url origin https://github.com/rk9-ai/<repo>.git
   ```
   Also update any long-lived clone bases under `/tmp/paperclip-worktrees/<PREFIX>/`.

6. **Update the webhook health monitor.** In the paperclip repo,
   `server/scripts/check-github-webhook-health.ts` hardcodes the owner per repo
   in `MONITORED_HOOKS`. Change the transferred repo's entry from
   `mv50000/<repo>` to `rk9-ai/<repo>` (the hook id is stable across transfer),
   otherwise the monitor queries the wrong owner and the webhook-failure alert
   goes blind for that repo.

7. **Update `paperclip-workspaces.sh` routing.** `~/.claude/bin/paperclip-workspaces.sh`
   resolves a company prefix → local repo path and clones from that repo's
   `origin`, so it inherits the new owner automatically once the local clone's
   remote is updated (step 5). Only add a `REPO_OVERRIDES` entry if a repo lives
   at a non-conventional path or on a different host; document the reason
   (org transfer / different host) inline next to the entry.

8. **Verify the Slack / Paperclip repo→company mapping.** Webhook routing and
   `paperclip-workspaces.sh` resolution depend on the Paperclip company record
   matching the repo. If a repo→company mapping is stale after transfer, clones
   misroute and fail silently. Cross-check `paperclipai company list --json`
   against the transferred repos and fix any drift.

## Risks / gotchas

- **Host compose is not in git.** `/srv/<company>/<env>/docker-compose.yml` on
  the deploy hosts is edited in place; the transfer won't touch it and neither
  will a workflow PR. Run step 3 on each host or it will keep pulling the old
  namespace.
- **Queued workflow_dispatch.** A deploy queued before the rewrite lands will
  push to the old namespace and 403. Pause CI (or let it fail and re-run) around
  the transfer window.
- **Grep coverage.** Refs hide in inline `run: |` bash, `cache-from`/`cache-to`,
  and composite actions, not just `image:` lines. The scripts grep recursively
  across `.github/workflows/` so inline refs are caught; still eyeball the diff.
- **Benign matches.** A `sed 's|ghcr.io/mv50000/...|ghcr.io/rk9-ai/...|'`
  migration line or a comment will match the grep but is not a broken push ref.
  `post-transfer-check.sh` classifies comment / already-migrated lines as benign
  (WARN), only failing on active refs.
- **Ephemeral runners idle offline.** Org-level Blacksmith runners show
  `offline` until a job spins them up, so a repo using them legitimately reports
  0 online repo-level runners. The checker downgrades this to a WARN when the org
  has runners registered — confirm liveness via a recent workflow run.

## Scripts

- `scripts/post-transfer-check.sh <owner/repo> [<local_clone_path>]` — runnable
  per-repo verification (runners, webhooks, stale refs, remote).
- `scripts/ghcr-rewrite-apply.sh <repo_path> [--new-owner O] [--srv-company C] [--apply]`
  — GHCR namespace rewrite with dry-run diff and confirmed `--apply`.
