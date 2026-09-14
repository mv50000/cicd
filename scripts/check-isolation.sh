#!/usr/bin/env bash
# RK9-213: assert the current self-hosted runner runs as a NON-root-equivalent user.
# Emits a JSON verdict and exits non-zero if the runner has sudo, docker-group
# membership, runs as root, or can read the operator's private trees.
set -u
fail=0; reasons=()
u=$(id -un); uid=$(id -u); grp=$(id -nG 2>/dev/null | tr ' ' ',')
[ "$uid" = 0 ] && { reasons+=("running as root (uid 0)"); fail=1; }
if sudo -n true 2>/dev/null; then reasons+=("passwordless sudo available"); fail=1; fi
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then reasons+=("member of docker group"); fail=1; fi
for d in /home/rk9admin /var/lib/paperclip; do
  if [ -d "$d" ] && ls "$d" >/dev/null 2>&1; then reasons+=("can read $d"); fail=1; fi
done
pass=$([ "$fail" = 0 ] && echo true || echo false)
rj=$(printf '%s\n' "${reasons[@]:-}" | sed '/^$/d' | sed 's/\\/\\\\/g;s/"/\\"/g;s/.*/"&"/' | paste -sd, -)
printf '{"runner":"%s","user":"%s","uid":%s,"groups":"%s","pass":%s,"reasons":[%s]}\n' \
  "${RUNNER_NAME:-unknown}" "$u" "$uid" "$grp" "$pass" "$rj"
[ "$fail" = 0 ] || echo "::error::runner isolation check FAILED as user $u"
exit "$fail"
