#!/usr/bin/env bash
# Bootstrap the production Teleport cluster (teleport-cluster in
# docker-compose.production.yaml.example) for the teleport module. Run from
# the repository root after prod-init.sh, once the stack is up:
#
#   docker compose up -d teleport-cluster
#   ./scripts/teleport-cluster-init.sh
#
# It creates (idempotently) the least-privilege tangra-manager role
# (configs/teleport/tangra-manager-role.yaml) and the tangra-mgmt user, and
# writes a fresh management identity to prod/teleport-cluster/tangra-mgmt.identity
# (root-owned, 0600). Register the cluster in the portal (Teleport > Register
# cluster) with proxy address PUBLIC_HOST:TELEPORT_PUBLIC_PORT and that file;
# re-run the script before the identity expires and rotate it in the portal
# (Credential > Rotate). PRODUCTION.md, "4.14 Teleport cluster".
#
# Inputs (environment, else .env):
#   PUBLIC_HOST, TELEPORT_PUBLIC_PORT   as written by prod-init.sh
#   TELEPORT_IDENTITY_TTL  lifetime of the management identity (default 2160h = 90 days)
#   TELEPORT_ADMIN_USER    optional: also create this human administrator
#                          (roles editor, access, auditor) and print its sign-up link
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "teleport-cluster-init: $*" >&2; exit 1; }

env_value() { # <key>: from the environment, else .env (parsed, never sourced)
  local k="$1" line
  if [ -n "${!k:-}" ]; then printf '%s' "${!k}"; return; fi
  [ -f .env ] || return 0
  line=$(grep -E "^(export[[:space:]]+)?${k}=" .env | tail -n1 || true)
  line="${line#export }"; line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"; line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}
PUBLIC_HOST=$(env_value PUBLIC_HOST)
TELEPORT_PUBLIC_PORT=$(env_value TELEPORT_PUBLIC_PORT)
TELEPORT_PUBLIC_PORT="${TELEPORT_PUBLIC_PORT:-3443}"
TTL=$(env_value TELEPORT_IDENTITY_TTL); TTL="${TTL:-2160h}"
ADMIN=$(env_value TELEPORT_ADMIN_USER)
[ -n "$PUBLIC_HOST" ] || die "PUBLIC_HOST is not set (run scripts/prod-init.sh first)"
[ -s prod/teleport-cluster.yaml ] || die "prod/teleport-cluster.yaml is missing (run scripts/prod-init.sh)"
[[ "$TTL" =~ ^[0-9]+h$ ]] || die "TELEPORT_IDENTITY_TTL must be hours, e.g. 2160h"
if [ -n "$ADMIN" ] && ! [[ "$ADMIN" =~ ^[a-z][a-z0-9._-]{0,62}$ ]]; then
  die "TELEPORT_ADMIN_USER must be a lowercase user name"
fi

tctl() { docker compose exec -T teleport-cluster tctl "$@"; }

echo "waiting for teleport-cluster..."
for _ in $(seq 1 60); do
  tctl status >/dev/null 2>&1 && break
  sleep 2
done
tctl status >/dev/null 2>&1 || die "teleport-cluster is not ready (docker compose logs teleport-cluster)"

tctl create -f /etc/teleport/tangra-manager-role.yaml
if ! tctl get user/tangra-mgmt >/dev/null 2>&1; then
  # Machine user: no password, so the printed invitation is discarded.
  tctl users add tangra-mgmt --roles=tangra-manager >/dev/null
  echo "created user tangra-mgmt"
fi
tctl auth sign --user=tangra-mgmt --format=file --ttl="$TTL" \
  --out=/out/tangra-mgmt.identity --overwrite >/dev/null
echo "wrote prod/teleport-cluster/tangra-mgmt.identity (valid ${TTL})"

if [ -n "$ADMIN" ]; then
  if tctl get "user/$ADMIN" >/dev/null 2>&1; then
    echo "user $ADMIN exists; reset it with: docker compose exec teleport-cluster tctl users reset $ADMIN"
  else
    echo "administrator $ADMIN - open the sign-up link below within an hour:"
    tctl users add "$ADMIN" --roles=editor,access,auditor
  fi
fi

cat <<EOF

Next, in the portal (Teleport > Register cluster):
  proxy address  ${PUBLIC_HOST}:${TELEPORT_PUBLIC_PORT}
  identity file  prod/teleport-cluster/tangra-mgmt.identity  (sudo cat it to upload)
Re-run this script before the identity expires and rotate the credential.
EOF
