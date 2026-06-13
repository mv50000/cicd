#!/usr/bin/env bash
# post-transfer-check.sh — Verify a repo after a GitHub org transfer
# (e.g. personal account `mv50000` → org `rk9-ai`).
#
# Codifies the post-transfer checklist from the rk9-knowledge vault note
# `feedback_github_org_transfer_fallout` into a runnable per-repo check.
# It only VERIFIES — it never re-registers runners or rewrites anything.
# See docs/org-transfer-fallout.md for what survives vs. what breaks.
#
# Usage:
#   bash post-transfer-check.sh <owner/repo|repo> [<local_clone_path>] [--old-owner OWNER]
#
# Examples:
#   bash post-transfer-check.sh rk9-ai/quantimodo-rust /opt/repos/quantimodo
#   bash post-transfer-check.sh sunspot            # owner auto-detected via gh
#
# If <local_clone_path> is omitted it defaults to /opt/repos/<repo> and, if
# that does not exist, the workflow/remote checks that need a local clone are
# skipped with a warning (the GitHub-API checks still run).
#
# Requires: gh (authenticated), git, grep. Exits 0 if all checks pass,
# 1 if any breaking issue is found, 2 on usage/setup error.

set -euo pipefail

OLD_OWNER="mv50000"
ARG_REPO=""
LOCAL_PATH=""

# --- arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --old-owner) OLD_OWNER="${2:?--old-owner needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "ERROR: unknown flag $1" >&2; exit 2 ;;
    *)
      if [ -z "$ARG_REPO" ]; then ARG_REPO="$1"
      elif [ -z "$LOCAL_PATH" ]; then LOCAL_PATH="$1"
      else echo "ERROR: unexpected argument $1" >&2; exit 2
      fi
      shift ;;
  esac
done

[ -n "$ARG_REPO" ] || { echo "ERROR: repo required (e.g. rk9-ai/sunspot)" >&2; exit 2; }
command -v gh >/dev/null || { echo "ERROR: gh CLI not found" >&2; exit 2; }

# --- resolve owner/repo -----------------------------------------------------
if [[ "$ARG_REPO" == */* ]]; then
  OWNER="${ARG_REPO%%/*}"
  REPO="${ARG_REPO##*/}"
else
  REPO="$ARG_REPO"
  OWNER=""
  for cand in rk9-ai "$OLD_OWNER"; do
    if gh repo view "$cand/$REPO" --json name >/dev/null 2>&1; then OWNER="$cand"; break; fi
  done
  [ -n "$OWNER" ] || { echo "ERROR: could not resolve owner for '$REPO' (tried rk9-ai, $OLD_OWNER)" >&2; exit 2; }
fi
SLUG="${OWNER}/${REPO}"

# --- resolve local clone path ----------------------------------------------
if [ -z "$LOCAL_PATH" ]; then
  # repo name and local dir often differ (quantimodo-rust → quantimodo, bk → bk)
  guess="/opt/repos/${REPO}"
  [ -d "$guess" ] || guess="/opt/repos/${REPO%-rust}"
  [ -d "$guess" ] && LOCAL_PATH="$guess"
fi

FAIL=0
warn() { echo "WARN   $*" >&2; }
fail() { echo "FAIL   $*"; FAIL=1; }
pass() { echo "OK     $*"; }

echo "==> post-transfer-check ${SLUG} (old owner: ${OLD_OWNER}, local: ${LOCAL_PATH:-<none>})"

# --- 1. runner online (survives transfer — verify only) ---------------------
# Repos may use dedicated repo-level runners (e.g. paperclip-01-sunspot) OR
# org-level runners selected by label (e.g. runs-on: [self-hosted, docker], or
# ephemeral Blacksmith runners that idle OFFLINE until a job spins them up).
# So: repo-level online runner → PASS; else fall back to org-level presence
# (WARN, since ephemeral runners can't be proven live without a job).
echo "--- runners ---"
if runners_json=$(gh api "repos/${SLUG}/actions/runners" 2>/dev/null); then
  online=$(echo "$runners_json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
rs=d.get("runners",[])
on=[r for r in rs if r.get("status")=="online"]
for r in rs:
    labels=",".join(l["name"] for l in r.get("labels",[]))
    print("  {:<28} {:<8} [{}]".format(r["name"], r["status"], labels))
print("__COUNT__ {} {}".format(len(on), len(rs)))
')
  echo "$online" | grep -v '^__COUNT__' || true
  read -r _ n_online n_total < <(echo "$online" | grep '^__COUNT__') || true
  if [ "${n_online:-0}" -ge 1 ]; then
    pass "${n_online}/${n_total} repo-level runner(s) online"
  else
    # No repo-level runner online — check whether the org provides runners.
    org_total=$(gh api "orgs/${OWNER}/actions/runners" -q '.total_count' 2>/dev/null || echo "")
    if [ -n "$org_total" ] && [ "$org_total" -ge 1 ]; then
      warn "0 repo-level runners online (${n_total} registered) but ${OWNER} org has ${org_total} runner(s) registered — repo likely uses org-level/ephemeral runners (idle offline); confirm via a recent workflow run"
    else
      fail "no repo-level runners online (${n_total} registered) and no org-level runners — runners normally survive transfer; check labels/host"
    fi
  fi
else
  warn "could not read runners for ${SLUG} (token scope: needs repo admin) — skipping"
fi

# --- 2. webhook delivery status (last 5 per hook) ---------------------------
echo "--- webhooks ---"
if hooks_json=$(gh api "repos/${SLUG}/hooks" 2>/dev/null); then
  hook_ids=$(echo "$hooks_json" | python3 -c 'import json,sys; [print(h["id"], h.get("config",{}).get("url","")) for h in json.load(sys.stdin)]')
  if [ -z "$hook_ids" ]; then
    warn "no repo webhooks configured"
  else
    while read -r hid hurl; do
      [ -n "$hid" ] || continue
      deliv=$(gh api "repos/${SLUG}/hooks/${hid}/deliveries?per_page=5" 2>/dev/null || echo "[]")
      codes=$(echo "$deliv" | python3 -c 'import json,sys; print(" ".join(str(d.get("status_code")) for d in json.load(sys.stdin)))')
      bad=$(echo "$deliv" | python3 -c 'import json,sys; print(sum(1 for d in json.load(sys.stdin) if d.get("status_code")!=200))')
      if [ "${bad:-0}" -eq 0 ] && [ -n "$codes" ]; then
        pass "hook ${hid} (${hurl}) last 5: ${codes}"
      elif [ -z "$codes" ]; then
        warn "hook ${hid} (${hurl}) has no recent deliveries"
      else
        fail "hook ${hid} (${hurl}) last 5: ${codes} — ${bad} non-200"
      fi
    done <<< "$hook_ids"
  fi
else
  warn "could not read hooks for ${SLUG} (token scope: needs admin:repo_hook) — skipping"
fi

# --- 3 & 4. stale references in workflows (needs local clone) ---------------
echo "--- stale references (workflows) ---"
if [ -n "$LOCAL_PATH" ] && [ -d "$LOCAL_PATH/.github/workflows" ]; then
  wf="$LOCAL_PATH/.github/workflows"
  # 3. ghcr.io/<old-owner> — BREAKS (GHCR push 403 after transfer).
  # Split matches: a line that is a comment, or that ALSO contains the new
  # namespace (a sed/rewrite migration line like s|.../mv50000/...|.../rk9-ai/...|),
  # is benign — it won't 403. Only "active" refs trigger FAIL.
  ghcr_hits=$(grep -rn "ghcr.io/${OLD_OWNER}/" "$wf" 2>/dev/null || true)
  if [ -n "$ghcr_hits" ]; then
    echo "$ghcr_hits" | sed 's/^/  /'
    # active = match line, stripped of its "file:line:" prefix, that is not a
    # comment and does not already reference the new owner's namespace.
    active=$(echo "$ghcr_hits" | sed -E 's/^[^:]+:[0-9]+://' \
      | grep -vE "^[[:space:]]*#" \
      | grep -vF "ghcr.io/${OWNER}/" | grep -c . || true)
    total=$(echo "$ghcr_hits" | grep -c .)
    if [ "${active:-0}" -ge 1 ]; then
      fail "${active}/${total} ACTIVE ghcr.io/${OLD_OWNER}/ ref(s) in workflows — GHCR push will 403; run ghcr-rewrite-apply.sh"
    else
      warn "${total} ghcr.io/${OLD_OWNER}/ ref(s) in workflows are benign (comments / migration-rewrite lines) — no active push refs"
    fi
  else
    pass "no ghcr.io/${OLD_OWNER}/ refs in workflows"
  fi
  # 4. uses: <old-owner>/ — only breaks if the called repo is PRIVATE & cross-owner
  uses_hits=$(grep -rnE "uses:[[:space:]]*${OLD_OWNER}/" "$wf" 2>/dev/null || true)
  if [ -n "$uses_hits" ]; then
    echo "$uses_hits" | sed 's/^/  /'
    cnt=$(echo "$uses_hits" | grep -c .)
    # Determine whether the called owner's reusable-workflow repo is public.
    called_repo=$(echo "$uses_hits" | grep -oE "${OLD_OWNER}/[A-Za-z0-9_.-]+" | head -1 | cut -d/ -f2)
    vis=$(gh repo view "${OLD_OWNER}/${called_repo}" --json visibility -q .visibility 2>/dev/null || echo "UNKNOWN")
    if [ "$vis" = "PUBLIC" ]; then
      warn "${cnt} 'uses: ${OLD_OWNER}/' ref(s) — ${OLD_OWNER}/${called_repo} is PUBLIC so these still resolve; update for cleanliness"
    else
      fail "${cnt} 'uses: ${OLD_OWNER}/' ref(s) — ${OLD_OWNER}/${called_repo} is ${vis}; cross-owner private reusable workflow will FAIL"
    fi
  else
    pass "no 'uses: ${OLD_OWNER}/' refs in workflows"
  fi
  # inline bash docker refs (run: | ... ghcr.io/<old>) caught by the grep above too
else
  warn "no local clone with .github/workflows at '${LOCAL_PATH:-<none>}' — skipping workflow grep"
fi

# --- 5. local clone origin URL ----------------------------------------------
echo "--- local clone remote ---"
if [ -n "$LOCAL_PATH" ] && [ -d "$LOCAL_PATH/.git" ]; then
  origin=$(git -C "$LOCAL_PATH" remote get-url origin 2>/dev/null || echo "")
  if echo "$origin" | grep -q "[:/]${OLD_OWNER}/"; then
    fail "origin still points to ${OLD_OWNER}: ${origin} — run: git -C ${LOCAL_PATH} remote set-url origin ${origin/${OLD_OWNER}/${OWNER}}"
  elif echo "$origin" | grep -q "[:/]${OWNER}/"; then
    pass "origin points to ${OWNER}: ${origin}"
  else
    warn "origin is neither ${OLD_OWNER} nor ${OWNER}: ${origin}"
  fi
else
  warn "no local git clone at '${LOCAL_PATH:-<none>}' — skipping origin check"
fi

echo "--- result ---"
if [ "$FAIL" -eq 0 ]; then
  echo "OK     ${SLUG}: post-transfer checks passed"
  exit 0
else
  echo "FAIL   ${SLUG}: one or more breaking issues found (see above)"
  exit 1
fi
