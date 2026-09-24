#!/usr/bin/env sh
# Production counterpart of vault-init.sh (see PRODUCTION.md, "Vault").
#
# Runs in the hashicorp/vault image as the vault-init service. It never
# initialises or unseals Vault and never stores a Vault token:
#
#   * warden's AppRole credentials already in $OUT  -> nothing to do (exit 0),
#     so every "docker compose up" passes without an operator token;
#   * otherwise, with VAULT_TOKEN set (a short-lived admin token supplied on
#     the command line), it creates the same objects as the development
#     vault-init.sh - KV v2 mount "warden", policy "warden", AppRole "warden" -
#     and writes role_id / secret_id to $OUT, the vault-creds volume warden
#     reads (configs: vault.role_id_file / vault.secret_id_file);
#   * ROTATE_SECRET_ID=1 issues a new secret_id (and destroys the old one).
#
#   VAULT_TOKEN=<admin token> docker compose run --rm vault-init
set -eu
OUT="${OUT:-/vault-creds}"
: "${VAULT_ADDR:=https://vault:8200}"
export VAULT_ADDR

if [ -s "$OUT/role_id" ] && [ -s "$OUT/secret_id" ] && [ "${ROTATE_SECRET_ID:-0}" != "1" ]; then
  echo "vault-init: warden AppRole credentials present in $OUT"
  exit 0
fi
if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "vault-init: no warden AppRole credentials in $OUT and no VAULT_TOKEN." >&2
  echo "  Initialise and unseal Vault, then run once:" >&2
  echo "  VAULT_TOKEN=<admin token> docker compose run --rm vault-init" >&2
  exit 1
fi
export VAULT_TOKEN

i=0
until vault status >/dev/null 2>&1; do
  i=$((i+1))
  if [ "$i" -ge 60 ]; then echo "vault-init: Vault at $VAULT_ADDR is not initialised/unsealed" >&2; exit 1; fi
  sleep 2
done

vault secrets list -format=json | grep -q '"warden/"' || vault secrets enable -path=warden kv-v2 >/dev/null
vault policy write warden - >/dev/null <<'POL'
path "warden/data/*" { capabilities = ["create","read","update","delete"] }
path "warden/metadata/*" { capabilities = ["read","delete","list"] }
path "auth/token/renew-self" { capabilities = ["update"] }
POL
vault auth list -format=json | grep -q '"approle/"' || vault auth enable approle >/dev/null
vault write auth/approle/role/warden token_policies=warden token_ttl=1h token_max_ttl=24h \
  secret_id_ttl=0 secret_id_num_uses=0 >/dev/null

umask 077
mkdir -p "$OUT"
OLD_ACCESSOR=""
if [ -s "$OUT/secret_id" ]; then
  OLD_ACCESSOR=$(vault write -field=secret_id_accessor auth/approle/role/warden/secret-id/lookup \
    secret_id="$(cat "$OUT/secret_id")" 2>/dev/null || true)
fi
vault read -field=role_id auth/approle/role/warden/role-id > "$OUT/role_id.tmp"
vault write -force -field=secret_id auth/approle/role/warden/secret-id > "$OUT/secret_id.tmp"
mv "$OUT/role_id.tmp" "$OUT/role_id"
mv "$OUT/secret_id.tmp" "$OUT/secret_id"
if [ -n "$OLD_ACCESSOR" ]; then
  vault write auth/approle/role/warden/secret-id-accessor/destroy secret_id_accessor="$OLD_ACCESSOR" >/dev/null || true
  echo "vault-init: previous secret_id destroyed (restart warden to pick up the new one)"
fi
echo "vault-init: warden AppRole -> $OUT/{role_id,secret_id}"
