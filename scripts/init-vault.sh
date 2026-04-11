#!/bin/sh
# Vault Initialization Script for Warden Service
# This script configures Vault for use with the Warden secret management service

set -e

VAULT_ADDR="${VAULT_ADDR:-http://vault:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-dev-token}"
CREDENTIALS_DIR="${CREDENTIALS_DIR:-/vault-credentials}"

export VAULT_ADDR
export VAULT_TOKEN

echo "Initializing Vault at ${VAULT_ADDR}..."

# Wait for Vault to be ready
MAX_RETRIES=60
RETRY=0
until vault status >/dev/null 2>&1; do
    RETRY=$((RETRY + 1))
    if [ $RETRY -ge $MAX_RETRIES ]; then
        echo "ERROR: Vault not ready after ${MAX_RETRIES} attempts"
        exit 1
    fi
    echo "Waiting for Vault to be ready... (${RETRY}/${MAX_RETRIES})"
    sleep 2
done

echo "Vault is ready!"

# Enable KV v2 secrets engine for Warden
echo "Enabling KV v2 secrets engine..."
vault secrets enable -path=secret -version=2 kv 2>/dev/null || echo "KV secrets engine already enabled"

# Create policy for Warden service
echo "Creating Warden policy..."
vault policy write warden - <<'EOF'
# Warden service policy
# Allow full access to warden secrets path

# Read and write secrets
path "secret/data/warden/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Manage secret metadata (for versioning)
path "secret/metadata/warden/*" {
  capabilities = ["read", "delete", "list"]
}

# Destroy secret versions
path "secret/destroy/warden/*" {
  capabilities = ["update"]
}

# Undelete secret versions
path "secret/undelete/warden/*" {
  capabilities = ["update"]
}
EOF

# Enable AppRole authentication
echo "Enabling AppRole authentication..."
vault auth enable approle 2>/dev/null || echo "AppRole auth already enabled"

# Create AppRole for Warden
echo "Creating Warden AppRole..."
vault write auth/approle/role/warden \
    token_policies="warden" \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0

# Get role ID
ROLE_ID=$(vault read -field=role_id auth/approle/role/warden/role-id)
echo "Warden Role ID: ${ROLE_ID}"

# Generate secret ID
SECRET_ID=$(vault write -field=secret_id -force auth/approle/role/warden/secret-id)
echo "Warden Secret ID: ${SECRET_ID}"

# Save credentials to shared volume for warden service
echo "Saving credentials to ${CREDENTIALS_DIR}..."
mkdir -p "${CREDENTIALS_DIR}"

# Write individual files (easier for services to read)
printf '%s' "${ROLE_ID}" > "${CREDENTIALS_DIR}/role_id"
printf '%s' "${SECRET_ID}" > "${CREDENTIALS_DIR}/secret_id"

# Also write as env file
cat > "${CREDENTIALS_DIR}/warden.env" <<EOF
VAULT_ROLE_ID=${ROLE_ID}
VAULT_SECRET_ID=${SECRET_ID}
EOF

# Set permissions
chmod 600 "${CREDENTIALS_DIR}/role_id"
chmod 600 "${CREDENTIALS_DIR}/secret_id"
chmod 600 "${CREDENTIALS_DIR}/warden.env"

echo ""
echo "============================================"
echo "Vault initialization complete!"
echo ""
echo "Credentials saved to:"
echo "  ${CREDENTIALS_DIR}/role_id"
echo "  ${CREDENTIALS_DIR}/secret_id"
echo "  ${CREDENTIALS_DIR}/warden.env"
echo ""
echo "VAULT_ROLE_ID=${ROLE_ID}"
echo "VAULT_SECRET_ID=${SECRET_ID}"
echo "============================================"
