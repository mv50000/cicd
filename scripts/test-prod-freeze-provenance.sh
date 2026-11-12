#!/usr/bin/env bash
# Tests for scripts/prod-freeze-provenance.sh (QUA-1509). curl is replaced by
# a stub on PATH, so no network is used. Run: bash scripts/test-prod-freeze-provenance.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/prod-freeze-provenance.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# --- curl stub ----------------------------------------------------------------
# STUB_MODE: ok (write $STUB_BODY to -o), fail (exit 22), flaky (fail once).
# Every call appends its argv and stdin to $TMP/calls.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = "-o" ] && out="${args[$((i + 1))]}"
done
{ printf 'ARGV:'; printf ' %q' "$@"; printf '\n'; printf 'URL: %s\n' "${args[-1]}"; printf 'STDIN: %s\n' "$(cat)"; } >> "$STUB_DIR/calls"
n=$(grep -c '^ARGV:' "$STUB_DIR/calls")
case "$STUB_MODE" in
  ok) cat "$STUB_BODY" > "$out" ;;
  fail) exit 22 ;;
  flaky) [ "$n" -ge 2 ] || exit 22; cat "$STUB_BODY" > "$out" ;;
esac
STUB
chmod +x "$TMP/bin/curl"
# sleep stub so retries do not slow the suite down
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/sleep"; chmod +x "$TMP/bin/sleep"

GATED="$TMP/gated.yml"
cat > "$GATED" <<'YML'
jobs:
  build-rust:
    steps:
      - uses: actions/checkout@v4
      - name: Prod freeze gate (re-check)
        uses: ./.github/actions/prod-freeze-gate
        with:
          scope: deploy
YML
UNGATED="$TMP/ungated.yml"
cat > "$UNGATED" <<'YML'
jobs:
  build-rust:
    steps:
      - uses: actions/checkout@v4
      - uses: mv50000/cicd/actions/docker-build-push@v1
YML

SHA=0123456789abcdef0123456789abcdef01234567
REPO=rk9-ai/quantimodo-rust

# run_ NAME WANT_RC WANT_RE [VAR=value ...] — runs the script with a clean
# environment plus the given variables.
run_() {
  local name=$1 want_rc=$2 want_re=$3; shift 3
  : > "$TMP/calls"
  : > "$TMP/summary"
  local out rc
  out=$(env -i PATH="$TMP/bin:/usr/bin:/bin" STUB_DIR="$TMP" STUB_MODE=ok STUB_BODY="$GATED" \
    PFP_REPOSITORY_ID=1122181777 PFP_REPOSITORY="$REPO" PFP_TARGET=prod \
    PFP_WORKFLOW_REF="$REPO/.github/workflows/deploy-prod.yml@refs/heads/master" \
    PFP_WORKFLOW_SHA="$SHA" PFP_TOKEN=tok-secret-123 GITHUB_STEP_SUMMARY="$TMP/summary" \
    "$@" bash "$SCRIPT" 2>&1)
  rc=$?
  if [ "$rc" != "$want_rc" ] || ! grep -Eq -- "$want_re" <<<"$out"; then
    echo "FAIL $name: rc=$rc (want $want_rc), output did not match /$want_re/"
    sed 's/^/    /' <<<"$out"
    FAILS=$((FAILS + 1))
    return
  fi
  echo "ok   $name"
}

calls() { grep -c '^ARGV:' "$TMP/calls" || true; }

expect_calls() {
  local name=$1 want=$2 got
  got=$(calls)
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: $got curl call(s) (want $want)"; FAILS=$((FAILS + 1))
  else
    echo "ok   $name: $want curl call(s)"
  fi
}

# --- opt-in scope -------------------------------------------------------------
run_ "other repo is a no-op" 0 'skipped: .* has not opted in' \
  PFP_REPOSITORY_ID=999 PFP_REPOSITORY=rk9-ai/saatavilla STUB_BODY="$UNGATED"
expect_calls "other repo makes no API call" 0
run_ "other repo with an invalid sha is still a no-op" 0 'has not opted in' \
  PFP_REPOSITORY_ID=999 PFP_REPOSITORY=rk9-ai/bk PFP_WORKFLOW_SHA=bogus
run_ "dev target is a no-op" 0 'skipped: target is dev' PFP_TARGET=dev STUB_BODY="$UNGATED"
expect_calls "dev target makes no API call" 0
run_ "covered by id after a rename" 1 'does not call' \
  PFP_REPOSITORY=rk9-ai/quantimodo-renamed \
  PFP_WORKFLOW_REF="rk9-ai/quantimodo-renamed/.github/workflows/deploy-prod.yml@refs/heads/master" \
  STUB_BODY="$UNGATED"
run_ "covered by name when the id is missing" 1 'does not call' PFP_REPOSITORY_ID= STUB_BODY="$UNGATED"
run_ "covered by name, case-insensitive" 1 'does not call' \
  PFP_REPOSITORY_ID= PFP_REPOSITORY=RK9-AI/Quantimodo-Rust \
  PFP_WORKFLOW_REF="RK9-AI/Quantimodo-Rust/.github/workflows/deploy-prod.yml@refs/heads/master" \
  STUB_BODY="$UNGATED"

# --- target is fail closed ----------------------------------------------------
for t in Prod staging DEV "" ; do
  run_ "target '$t' counts as prod" 1 'does not call' PFP_TARGET="$t" STUB_BODY="$UNGATED"
done
run_ "deploy_path .../dev is dev" 0 'target is dev' PFP_TARGET= PFP_DEPLOY_PATH=/srv/quantimodo/dev STUB_BODY="$UNGATED"
run_ "deploy_path .../dev/ is dev" 0 'target is dev' PFP_TARGET= PFP_DEPLOY_PATH=/srv/quantimodo/dev/ STUB_BODY="$UNGATED"
run_ "deploy_path .../prod is prod" 1 'does not call' PFP_TARGET= PFP_DEPLOY_PATH=/srv/quantimodo/prod STUB_BODY="$UNGATED"
run_ "deploy_path .../devx is prod" 1 'does not call' PFP_TARGET= PFP_DEPLOY_PATH=/srv/quantimodo/devx STUB_BODY="$UNGATED"
run_ "deploy_path .../dev/../prod is prod" 1 'does not call' PFP_TARGET= PFP_DEPLOY_PATH=/srv/quantimodo/dev/../prod STUB_BODY="$UNGATED"
run_ "explicit target wins over deploy_path" 1 'does not call' PFP_TARGET=prod PFP_DEPLOY_PATH=/srv/quantimodo/dev STUB_BODY="$UNGATED"

# --- the decision ---------------------------------------------------------------
run_ "gated workflow passes" 0 'ok: .github/workflows/deploy-prod.yml@0123456789ab calls'
expect_calls "gated workflow is read once" 1
run_ "ungated workflow is refused" 1 '::error title=Prod freeze provenance.*predates the prod freeze gate' STUB_BODY="$UNGATED"
if grep -q 'refused' "$TMP/summary"; then echo "ok   refusal is in the step summary"; else echo "FAIL refusal is not in the step summary"; FAILS=$((FAILS + 1)); fi

for variant in \
  '        uses: "./.github/actions/prod-freeze-gate"' \
  "        uses: './.github/actions/prod-freeze-gate'" \
  '      - uses: ./.github/actions/prod-freeze-gate' \
  '        uses: ./.github/actions/prod-freeze-gate   # QUA-1508' ; do
  printf 'jobs:\n  a:\n    steps:\n%s\n' "$variant" > "$TMP/v.yml"
  run_ "gate form passes: $variant" 0 'ok:' STUB_BODY="$TMP/v.yml"
done
for variant in \
  '        # uses: ./.github/actions/prod-freeze-gate' \
  '        uses: ./.github/actions/prod-freeze-gate-disabled' \
  '        uses: ./.github/actions/prod-freeze-gate@v1' \
  '        uses: other/.github/actions/prod-freeze-gate' \
  '        run: echo uses: ./.github/actions/prod-freeze-gate' ; do
  printf 'jobs:\n  a:\n    steps:\n%s\n' "$variant" > "$TMP/v.yml"
  run_ "not a gate call: $variant" 1 'does not call' STUB_BODY="$TMP/v.yml"
done
: > "$TMP/empty.yml"
run_ "empty file is refused" 1 'does not call' STUB_BODY="$TMP/empty.yml"
printf '{"content":"%s","encoding":"base64"}\n' "$(base64 -w0 < "$GATED")" > "$TMP/json.yml"
run_ "a JSON (non-raw) answer is refused" 1 'does not call' STUB_BODY="$TMP/json.yml"

# --- API failures are refusals ------------------------------------------------
run_ "API failure is refused" 1 'Could not read' STUB_MODE=fail
expect_calls "API failure is retried" 3
run_ "one transient failure is retried" 0 'ok:' STUB_MODE=flaky
run_ "missing token is refused" 1 'No token' PFP_TOKEN=
expect_calls "missing token makes no API call" 0

# --- input validation -----------------------------------------------------------
run_ "short sha is refused" 1 'not a 40-character' PFP_WORKFLOW_SHA=0123456
run_ "uppercase sha is refused" 1 'not a 40-character' PFP_WORKFLOW_SHA=0123456789ABCDEF0123456789ABCDEF01234567
run_ "empty sha is refused" 1 'not a 40-character' PFP_WORKFLOW_SHA=
run_ "workflow of another repo is refused" 1 'is not a workflow of' \
  PFP_WORKFLOW_REF="rk9-ai/other/.github/workflows/deploy-prod.yml@refs/heads/master"
run_ "empty workflow_ref is refused" 1 'is not a workflow of' PFP_WORKFLOW_REF=
run_ "path traversal is refused" 1 'is not a file under' \
  PFP_WORKFLOW_REF="$REPO/.github/workflows/../../x.yml@refs/heads/master"
run_ "path outside workflows is refused" 1 'is not a file under' \
  PFP_WORKFLOW_REF="$REPO/deploy/x.yml@refs/heads/master"
run_ "query injection in path is refused" 1 'is not a file under' \
  PFP_WORKFLOW_REF="$REPO/.github/workflows/x.yml?ref=master@refs/heads/master"
run_ "bad repo name is refused" 1 'is not owner/name' PFP_REPOSITORY_ID=1122181777 PFP_REPOSITORY='rk9-ai/q r'
run_ "http API URL is refused" 1 'is not an https URL' GITHUB_API_URL=http://api.github.com
run_ "newline in a value cannot start a workflow command" 1 'is not a workflow of' \
  PFP_WORKFLOW_REF=$'x\n::warning::injected'
if grep -q '^::warning::injected' <<<"$(env -i PATH="$TMP/bin:/usr/bin:/bin" PFP_REPOSITORY_ID=1122181777 PFP_REPOSITORY="$REPO" PFP_TARGET=prod PFP_WORKFLOW_SHA="$SHA" PFP_TOKEN=t PFP_WORKFLOW_REF=$'x\n::warning::injected' bash "$SCRIPT" 2>&1)"; then
  echo "FAIL a newline in workflow_ref reached the log as its own line"; FAILS=$((FAILS + 1))
else
  echo "ok   a newline in workflow_ref does not reach the log as its own line"
fi

# --- the request ----------------------------------------------------------------
run_ "request shape" 0 'ok:' PFP_WORKFLOW_REF="$REPO/.github/workflows/deploy-prod.yml@refs/tags/v1.2.3"
if grep -qxF "URL: https://api.github.com/repos/$REPO/contents/.github/workflows/deploy-prod.yml?ref=$SHA" "$TMP/calls" \
  && grep -q 'application/vnd.github.raw' "$TMP/calls"; then
  echo "ok   request reads the workflow file at workflow_sha as raw"
else
  echo "FAIL request URL or Accept header is wrong:"; sed 's/^/    /' "$TMP/calls"; FAILS=$((FAILS + 1))
fi
if grep '^ARGV:' "$TMP/calls" | grep -q -- ' -fsS ' && grep '^ARGV:' "$TMP/calls" | grep -q -- ' --proto =https '; then
  echo "ok   curl fails on HTTP errors and allows only https"
else
  echo "FAIL curl is missing -fsS or --proto =https"; FAILS=$((FAILS + 1))
fi
if grep '^ARGV:' "$TMP/calls" | grep -q 'tok-secret-123'; then
  echo "FAIL the token is in curl's argv"; FAILS=$((FAILS + 1))
elif grep '^STDIN:' "$TMP/calls" | grep -q 'Authorization: Bearer tok-secret-123'; then
  echo "ok   the token goes in on stdin, not argv"
else
  echo "FAIL the token is not sent at all"; FAILS=$((FAILS + 1))
fi
run_ "GHES API URL is used" 0 'ok:' GITHUB_API_URL=https://ghe.example.com/api/v3
if grep -q 'https://ghe.example.com/api/v3/repos/' "$TMP/calls"; then
  echo "ok   GITHUB_API_URL is honoured"
else
  echo "FAIL GITHUB_API_URL is not honoured"; FAILS=$((FAILS + 1))
fi

# --- the actions call the check first -----------------------------------------
for action in docker-build-push ssh-deploy; do
  f="$HERE/../actions/$action/action.yml"
  first=$(grep -n -m1 -E '^    - name:' "$f" | cut -d: -f1)
  hook=$(grep -n -m1 -E '^    - name: Prod freeze provenance \(QUA-1509\)$' "$f" | cut -d: -f1)
  if [ -n "$first" ] && [ "$first" = "$hook" ] \
    && grep -qE '^      run: bash "\$GITHUB_ACTION_PATH/\.\./\.\./scripts/prod-freeze-provenance\.sh"$' "$f" \
    && grep -qE '^        PFP_WORKFLOW_SHA: \$\{\{ github\.workflow_sha \}\}$' "$f" \
    && grep -qE '^        PFP_WORKFLOW_REF: \$\{\{ github\.workflow_ref \}\}$' "$f" \
    && grep -qE '^        PFP_REPOSITORY_ID: \$\{\{ github\.repository_id \}\}$' "$f" \
    && ! sed -n "${hook},/^    - name: [^P]/p" "$f" | grep -qE '^      (if|continue-on-error):'; then
    echo "ok   $action runs the provenance check as its first step"
  else
    echo "FAIL $action does not run the provenance check as its first step"; FAILS=$((FAILS + 1))
  fi
done
if grep -qE '^        PFP_TARGET: \$\{\{ inputs\.environment \}\}$' "$HERE/../actions/docker-build-push/action.yml"; then
  echo "ok   docker-build-push passes inputs.environment"
else
  echo "FAIL docker-build-push does not pass inputs.environment"; FAILS=$((FAILS + 1))
fi
if grep -qE '^        PFP_DEPLOY_PATH: \$\{\{ inputs\.deploy_path \}\}$' "$HERE/../actions/ssh-deploy/action.yml"; then
  echo "ok   ssh-deploy passes inputs.deploy_path"
else
  echo "FAIL ssh-deploy does not pass inputs.deploy_path"; FAILS=$((FAILS + 1))
fi

echo
if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS test(s) failed"
  exit 1
fi
echo "all tests passed"
