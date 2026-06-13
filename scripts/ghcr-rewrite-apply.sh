#!/usr/bin/env bash
# ghcr-rewrite-apply.sh — Rewrite GHCR image namespace after a GitHub org transfer.
#
# After moving a repo from `<old-owner>` to `<new-owner>`, workflows and host
# compose files still targeting `ghcr.io/<old-owner>/<pkg>` fail to PUSH with a
# 403 (the GITHUB_TOKEN is now scoped to the new owner and cannot write a
# package owned by the old account). This helper finds those refs and, with
# --apply, rewrites them to `ghcr.io/<new-owner>/<pkg>`.
#
# See docs/org-transfer-fallout.md and the vault note
# `feedback_github_org_transfer_fallout`.
#
# Usage:
#   bash ghcr-rewrite-apply.sh <repo_path> [--new-owner OWNER] [--old-owner OWNER] \
#        [--srv-company COMPANY] [--apply] [--yes]
#
#   <repo_path>        local clone whose .github/workflows/*.yml are scanned
#   --new-owner OWNER  target owner (default: auto-detected from origin remote)
#   --old-owner OWNER  source owner (default: mv50000)
#   --srv-company CO   also scan host deploy compose at
#                      /srv/CO/{dev,prod}/docker-compose.yml (run on the host)
#   --apply            rewrite files in place (.bak backups). Default is dry-run.
#   --yes              skip the interactive confirmation prompt for --apply
#
# Dry-run (default) prints a before/after diff and exits 0. --apply requires
# operator confirmation unless --yes is given. Exits 2 on usage error.

set -euo pipefail

OLD_OWNER="mv50000"
NEW_OWNER=""
REPO_PATH=""
SRV_COMPANY=""
APPLY=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --new-owner)  NEW_OWNER="${2:?--new-owner needs a value}"; shift 2 ;;
    --old-owner)  OLD_OWNER="${2:?--old-owner needs a value}"; shift 2 ;;
    --srv-company) SRV_COMPANY="${2:?--srv-company needs a value}"; shift 2 ;;
    --apply)      APPLY=1; shift ;;
    --yes)        ASSUME_YES=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "ERROR: unknown flag $1" >&2; exit 2 ;;
    *)
      if [ -z "$REPO_PATH" ]; then REPO_PATH="$1"; else echo "ERROR: unexpected arg $1" >&2; exit 2; fi
      shift ;;
  esac
done

[ -n "$REPO_PATH" ] || { echo "ERROR: repo_path required" >&2; exit 2; }
[ -d "$REPO_PATH" ] || { echo "ERROR: repo_path '$REPO_PATH' not a directory" >&2; exit 2; }

# Auto-detect new owner from the clone's origin remote if not given.
if [ -z "$NEW_OWNER" ]; then
  origin=$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null || true)
  NEW_OWNER=$(echo "$origin" | sed -nE 's#.*[:/]([^/]+)/[^/]+(\.git)?$#\1#p')
  [ -n "$NEW_OWNER" ] || { echo "ERROR: could not auto-detect --new-owner from origin ('$origin'); pass --new-owner" >&2; exit 2; }
fi
[ "$NEW_OWNER" != "$OLD_OWNER" ] || { echo "ERROR: new-owner == old-owner ($OLD_OWNER); nothing to do" >&2; exit 2; }

OLD="ghcr.io/${OLD_OWNER}/"
NEW="ghcr.io/${NEW_OWNER}/"
echo "==> ghcr-rewrite: ${OLD} → ${NEW}  (mode: $([ $APPLY -eq 1 ] && echo APPLY || echo dry-run))"

# Collect scan targets.
TARGETS=()
if [ -d "$REPO_PATH/.github/workflows" ]; then
  while IFS= read -r f; do TARGETS+=("$f"); done < <(grep -rlF "$OLD" "$REPO_PATH/.github/workflows" 2>/dev/null || true)
fi
if [ -n "$SRV_COMPANY" ]; then
  for env in dev prod; do
    cf="/srv/${SRV_COMPANY}/${env}/docker-compose.yml"
    if [ -f "$cf" ] && grep -qF "$OLD" "$cf"; then TARGETS+=("$cf"); fi
  done
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "OK     no '${OLD}' references found under ${REPO_PATH}$([ -n "$SRV_COMPANY" ] && echo " or /srv/${SRV_COMPANY}")"
  exit 0
fi

echo "--- files with ${OLD} references ---"
for f in "${TARGETS[@]}"; do
  echo "  $f"
  grep -nF "$OLD" "$f" | sed 's/^/      /'
done

# Show before/after diff (does not modify files).
echo "--- proposed diff ---"
for f in "${TARGETS[@]}"; do
  diff -u --label "a/$f" --label "b/$f" "$f" <(sed "s#${OLD}#${NEW}#g" "$f") || true
done

if [ "$APPLY" -eq 0 ]; then
  echo "==> dry-run only. Re-run with --apply to rewrite ${#TARGETS[@]} file(s)."
  exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  printf '==> Rewrite %d file(s) %s → %s in place (with .bak backups)? [y/N] ' "${#TARGETS[@]}" "$OLD" "$NEW"
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted — no changes made." >&2; exit 1 ;;
  esac
fi

for f in "${TARGETS[@]}"; do
  cp "$f" "$f.bak"
  sed -i "s#${OLD}#${NEW}#g" "$f"
  echo "==> rewrote $f (backup: $f.bak)"
done

echo "OK     rewrote ${#TARGETS[@]} file(s). Review the diff, run a dev build to create the new"
echo "       (private) package under ${NEW_OWNER}, then verify 'docker pull' auth on the host"
echo "       before tagging prod. Remove .bak files once satisfied."
