#!/usr/bin/env bash
# Prod freeze provenance check (QUA-1509). Run as the first step of
# actions/docker-build-push and actions/ssh-deploy.
#
# Why here: GitHub runs a workflow from the ref it was started on. A repo can
# put a prod freeze gate into its own deploy workflow (rk9-ai/quantimodo-rust
# did in QUA-1508), but any ref whose workflow predates that gate still runs
# without it: a dispatch on a stale branch, a v* tag pushed to an old sha, or a
# re-run of a run made before the gate. Those old workflows still call
# mv50000/cicd/actions/*@v1, and an action tag is resolved when the job starts,
# so a job that goes through docker-build-push or ssh-deploy cannot skip this.
# It closes only that path: a job that pushes an image or touches the host
# without these actions (a repo-local deploy action, a direct
# docker/build-push-action, other workflows) is not covered.
#
# What it checks: for an opted-in repo and a prod target, the workflow file of
# THIS run (github.workflow_ref at github.workflow_sha, read through the
# contents API) must call the repo's own gate action
# ./.github/actions/prod-freeze-gate. If it does, that gate already decided
# the freeze in the same run (it reads the repo variable PROD_FREEZE_UNTIL), so
# this check passes. If it does not, the run is refused, frozen or not.
#
# Why not read PROD_FREEZE_UNTIL here: a composite action has no `vars`
# context (actions/runner action_yaml.json), and GITHUB_TOKEN has no
# Variables permission, so the variable is not readable from an action that
# old workflows call without inputs.
#
# Every other repo and every non-prod target is a no-op: no API call, exit 0.
#
# Inputs (environment):
#   PFP_REPOSITORY_ID   github.repository_id
#   PFP_REPOSITORY      github.repository (owner/name)
#   PFP_TARGET          dev | prod. Anything but "dev" counts as prod.
#   PFP_DEPLOY_PATH     used only when PFP_TARGET is empty: a path whose last
#                       component is "dev" counts as dev, anything else as prod
#   PFP_WORKFLOW_REF    github.workflow_ref (owner/name/.github/workflows/x.yml@ref)
#   PFP_WORKFLOW_SHA    github.workflow_sha
#   PFP_TOKEN           a token with contents:read on the repo (GITHUB_TOKEN)
#   GITHUB_API_URL      set by the runner; must be https
#
# Exit codes: 0 = proceed, 1 = refused. Any error in an opted-in prod run is a
# refusal (fail closed).
set -euo pipefail

# Opted-in repos: "<repository_id> <owner/name>". The id survives a rename or
# a transfer; the name is a second key in case the id is ever missing.
COVERED_REPOS=(
  "1122181777 rk9-ai/quantimodo-rust"
)

# A step that calls the repo's own freeze gate. Block-style `uses:` line,
# optionally after "- ", optionally quoted, optionally a trailing comment. A
# commented-out line does not match.
GATE_RE='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*["'"'"']?\./\.github/actions/prod-freeze-gate["'"'"']?[[:space:]]*(#.*)?$'

REPO_ID="${PFP_REPOSITORY_ID:-}"
REPO="${PFP_REPOSITORY:-}"
TARGET="${PFP_TARGET:-}"
DEPLOY_PATH="${PFP_DEPLOY_PATH:-}"
WF_REF="${PFP_WORKFLOW_REF:-}"
WF_SHA="${PFP_WORKFLOW_SHA:-}"
TOKEN="${PFP_TOKEN:-}"
API="${GITHUB_API_URL:-https://api.github.com}"

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# One line, printable ASCII only: values below come from refs and inputs and
# are echoed into workflow commands and the step summary.
clean() {
  printf '%s' "$1" | tr -c '[:alnum:]/._@:+= -' '?'
}

refuse() {
  local why=$1
  echo "::error title=Prod freeze provenance (QUA-1509)::$why"
  summary "### Prod freeze provenance: refused" "" "$why" "" \
    "Deploy prod from a ref whose workflow calls \`./.github/actions/prod-freeze-gate\` (master or the current release branch)."
  exit 1
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# --- 1. Is this repo opted in? ----------------------------------------------
covered=0
for entry in "${COVERED_REPOS[@]}"; do
  id=${entry%% *}
  name=${entry#* }
  if { [ -n "$REPO_ID" ] && [ "$REPO_ID" = "$id" ]; } || [ "$(lower "$REPO")" = "$(lower "$name")" ]; then
    covered=1
  fi
done
if [ "$covered" != 1 ]; then
  echo "prod-freeze-provenance: skipped: $(clean "$REPO") has not opted in."
  exit 0
fi

# --- 2. Is the target prod? -------------------------------------------------
if [ -z "$TARGET" ] && [ -n "$DEPLOY_PATH" ]; then
  trimmed=${DEPLOY_PATH%/}
  if [ "${trimmed##*/}" = "dev" ]; then
    TARGET=dev
  else
    TARGET=prod
  fi
fi
if [ "$TARGET" = "dev" ]; then
  echo "prod-freeze-provenance: skipped: target is dev."
  exit 0
fi

# --- 3. Which workflow file is this run executing? --------------------------
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  refuse "Repository name '$(clean "$REPO")' is not owner/name."
fi
if ! [[ "$WF_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  refuse "github.workflow_sha '$(clean "$WF_SHA")' is not a 40-character commit sha."
fi
prefix="$REPO/"
if [ "$(lower "${WF_REF:0:${#prefix}}")" != "$(lower "$prefix")" ]; then
  refuse "github.workflow_ref '$(clean "$WF_REF")' is not a workflow of $(clean "$REPO")."
fi
rest=${WF_REF:${#prefix}}
WF_PATH=${rest%%@*}
if ! [[ "$WF_PATH" =~ ^\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$ ]]; then
  refuse "Workflow path '$(clean "$WF_PATH")' is not a file under .github/workflows/."
fi
if ! [[ "$API" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$ ]]; then
  refuse "GITHUB_API_URL '$(clean "$API")' is not an https URL."
fi
if [ -z "$TOKEN" ]; then
  refuse "No token to read the workflow file with."
fi

# --- 4. Does that file call the freeze gate? --------------------------------
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
url="${API%/}/repos/${REPO}/contents/${WF_PATH}?ref=${WF_SHA}"
fetched=0
for attempt in 1 2 3; do
  # The token goes in through a config on stdin, not argv: argv is visible to
  # other processes on a self-hosted runner.
  if printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -fsS --proto '=https' \
      --max-time 20 --config - \
      -H "Accept: application/vnd.github.raw" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -o "$tmp" "$url"; then
    fetched=1
    break
  fi
  [ "$attempt" = 3 ] || sleep $((attempt * 2))
done
if [ "$fetched" != 1 ]; then
  refuse "Could not read $(clean "$WF_PATH") at $(clean "$WF_SHA") from the contents API. Refusing a prod run whose workflow cannot be checked."
fi

if grep -Eq "$GATE_RE" "$tmp"; then
  echo "prod-freeze-provenance: ok: $(clean "$WF_PATH")@${WF_SHA:0:12} calls ./.github/actions/prod-freeze-gate."
  summary "### Prod freeze provenance: ok" "" \
    "\`$(clean "$WF_PATH")\` at \`${WF_SHA:0:12}\` calls the repo's prod freeze gate."
  exit 0
fi

refuse "$(clean "$WF_PATH") at ${WF_SHA:0:12} does not call ./.github/actions/prod-freeze-gate: this ref predates the prod freeze gate (QUA-1508), so it could deploy prod past an active freeze."
