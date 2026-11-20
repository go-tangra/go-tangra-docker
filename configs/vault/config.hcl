# Production Vault server configuration for warden (see PRODUCTION.md).
# Used by docker-compose.production.yaml.example; the development stack keeps
# the in-memory dev-mode Vault and never reads this file.
#
# Storage: integrated storage (raft) on the vault-data volume, mounted at
# /vault/file. Single node; add retry_join blocks for an HA cluster.
# Alternative (what the v3 deployment used): replace the storage block with
#   storage "file" { path = "/vault/file" }
storage "raft" {
  path    = "/vault/file"
  node_id = "vault-1"
}

# TLS listener. The certificate (SAN "vault") comes from the internal CA,
# see scripts/gen-internal-tls.sh; it is mounted at /tls-server.
listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "/tls-server/server.crt"
  tls_key_file    = "/tls-server/server.key"
  tls_min_version = "tls13"
}

api_addr     = "https://vault:8200"
cluster_addr = "https://vault:8201"

# Integrated storage recommends disabling mlock (the container keeps IPC_LOCK
# for the file backend alternative).
disable_mlock = true
ui            = false
