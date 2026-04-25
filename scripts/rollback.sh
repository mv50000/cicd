#!/usr/bin/env bash
# rollback.sh — Roll a stack back to the previous-tag on the deploy host.
# Run on the deploy host as the deploy user.
#
# Usage:
#   bash rollback.sh <company> <env> [<compose_file>]

set -euo pipefail

COMPANY="${1:?company required}"
ENV="${2:?env required}"
COMPOSE_FILE="${3:-docker-compose.yml}"

DEPLOY_PATH="/srv/${COMPANY}/${ENV}"
cd "$DEPLOY_PATH"

PREV=$(cat previous-tag 2>/dev/null || true)
if [ -z "$PREV" ]; then
  echo "ERROR: previous-tag is empty in ${DEPLOY_PATH}; cannot rollback" >&2
  exit 1
fi

CURRENT=$(cat current-tag 2>/dev/null || true)
echo "==> Rolling back ${COMPANY}/${ENV}: ${CURRENT} → ${PREV}"

# Update .env IMAGE_TAG
grep -v '^IMAGE_TAG=' .env > .env.tmp 2>/dev/null || true
mv .env.tmp .env
echo "IMAGE_TAG=${PREV}" >> .env

# Pull and up
docker compose -f "$COMPOSE_FILE" pull
docker compose -f "$COMPOSE_FILE" up -d --wait --remove-orphans

# Swap tag history (current ↔ previous)
echo "$CURRENT" > previous-tag
echo "$PREV" > current-tag

echo "==> Rollback done. Now running ${PREV}; failed tag ${CURRENT} stored as previous-tag for forward-roll if needed."
