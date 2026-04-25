#!/usr/bin/env bash
# healthcheck.sh — Poll a URL until 200 OK or timeout.
#
# Usage:
#   bash healthcheck.sh <url> [<timeout_s>] [<interval_s>]

set -euo pipefail

URL="${1:?health URL required}"
TIMEOUT="${2:-60}"
INTERVAL="${3:-3}"

DEADLINE=$(( $(date +%s) + TIMEOUT ))

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if curl -sSf -o /dev/null -m 5 "$URL"; then
    echo "OK $URL"
    exit 0
  fi
  sleep "$INTERVAL"
done

echo "FAIL $URL (timeout ${TIMEOUT}s)" >&2
exit 1
