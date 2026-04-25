#!/usr/bin/env bash
# server-bootstrap.sh — Provision /srv/{company}/{env}/ on a new deploy host
#
# Usage (on the deploy host, as root or with sudo):
#   sudo bash server-bootstrap.sh <company> <env> [<deploy_user>]
#
# Idempotent: safe to re-run.

set -euo pipefail

COMPANY="${1:?company name required (e.g. saatavilla)}"
ENV="${2:?environment required (dev|prod)}"
DEPLOY_USER="${3:-deploy}"

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "ERROR: env must be 'dev' or 'prod' (got: $ENV)" >&2
  exit 1
fi

DEPLOY_PATH="/srv/${COMPANY}/${ENV}"

echo "==> Bootstrapping ${DEPLOY_PATH} for user ${DEPLOY_USER}"

# 1. Ensure deploy user exists
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "==> Creating user ${DEPLOY_USER}"
  useradd -m -s /bin/bash "$DEPLOY_USER"
fi

# 2. Ensure deploy user is in docker group
if getent group docker >/dev/null; then
  if ! id -nG "$DEPLOY_USER" | grep -qw docker; then
    echo "==> Adding ${DEPLOY_USER} to docker group"
    usermod -aG docker "$DEPLOY_USER"
  fi
else
  echo "WARNING: docker group not found; install Docker first" >&2
fi

# 3. Create deploy path
echo "==> Creating ${DEPLOY_PATH}"
mkdir -p "${DEPLOY_PATH}"/{data,logs}
touch "${DEPLOY_PATH}/current-tag" "${DEPLOY_PATH}/previous-tag"

# 4. Create .env stub if missing (DO NOT overwrite)
if [ ! -f "${DEPLOY_PATH}/.env" ]; then
  cat > "${DEPLOY_PATH}/.env" <<EOF
# /srv/${COMPANY}/${ENV}/.env
# IMAGE_TAG is rewritten by ssh-deploy action on each deploy.
# Add company-specific env vars below this line.
IMAGE_TAG=
EOF
  echo "==> Created ${DEPLOY_PATH}/.env stub (fill in env vars manually)"
fi

# 5. Ownership
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_PATH}"
chmod 700 "${DEPLOY_PATH}/.env"

# 6. SSH authorized_keys
mkdir -p "/home/${DEPLOY_USER}/.ssh"
chmod 700 "/home/${DEPLOY_USER}/.ssh"
touch "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"

echo "==> Done. Next steps:"
echo "    1. Add the deploy public key to /home/${DEPLOY_USER}/.ssh/authorized_keys"
echo "    2. Edit ${DEPLOY_PATH}/.env with company-specific variables"
echo "    3. Verify Docker daemon has live-restore enabled (/etc/docker/daemon.json)"
echo "    4. Add DEPLOY_SSH_KEY secret to the company's GitHub repo"
echo "    5. Push to main and watch the deploy workflow run"
