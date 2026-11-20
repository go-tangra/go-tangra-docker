#!/usr/bin/env sh
# Prepare dev Vault for warden: KV v2 mount "warden", policy, AppRole, and the
# role_id/secret_id files warden reads. Idempotent. Writes to $OUT (a shared
# volume). Runs in the hashicorp/vault image (vault CLI + sh).
set -e
export VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-dev-root}"
OUT="${OUT:-/vault-creds}"
mkdir -p "$OUT"
i=0; while [ $i -lt 30 ]; do vault status >/dev/null 2>&1 && break; i=$((i+1)); sleep 1; done
vault secrets enable -path=warden kv-v2 >/dev/null 2>&1 || true
vault policy write warden - >/dev/null <<'POL'
path "warden/data/*" { capabilities = ["create","read","update","delete"] }
path "warden/metadata/*" { capabilities = ["read","delete","list"] }
path "auth/token/renew-self" { capabilities = ["update"] }
POL
vault auth enable approle >/dev/null 2>&1 || true
vault write auth/approle/role/warden token_policies=warden token_ttl=1h token_max_ttl=24h secret_id_num_uses=0 >/dev/null
vault read -field=role_id auth/approle/role/warden/role-id > "$OUT/role_id"
vault write -force -field=secret_id auth/approle/role/warden/secret-id > "$OUT/secret_id"
echo "vault-init: warden approle -> $OUT/{role_id,secret_id}"
