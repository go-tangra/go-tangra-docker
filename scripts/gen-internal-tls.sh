#!/usr/bin/env bash
# Internal TLS for the production stack (see PRODUCTION.md, "Internal TLS").
#
# Creates a private CA and one server certificate per infrastructure service
# (SAN = its compose service name, plus localhost/127.0.0.1 for in-container
# health checks), under $OUT (default prod/tls):
#
#   ca-private/ca.key, ca.srl   CA private key - move it OFF the host after use
#   ca/ca.crt                   CA certificate (mounted into every container at /tls)
#   ca/bundle.pem               OS roots + ca.crt (SSL_CERT_FILE for Go clients
#                               that have no CA-file option: OpenFGA, S3)
#   timescaledb/ valkey/ openfga/ vault/   server.crt + server.key
#   rustfs/                     rustfs_cert.pem + rustfs_key.pem (RustFS naming)
#
# Keys are handed to the uid each image runs as (via a throwaway container, so
# no sudo is needed). Existing files are kept; delete a directory to re-issue.
# Needs: openssl, docker.
set -euo pipefail
OUT="${OUT:-prod/tls}"
DAYS="${DAYS:-825}"
ALPINE_IMAGE="${ALPINE_IMAGE:-alpine:3.20}"
ROOTS_IMAGE="${ROOTS_IMAGE:-${ALPINE_IMAGE}}"
mkdir -p "$OUT/ca" "$OUT/ca-private"
cd "$OUT"
umask 077

if [ -s ca/ca.crt ] && [ ! -s ca-private/ca.key ]; then
  echo "error: $OUT/ca/ca.crt exists but ca-private/ca.key is missing; restore the CA key from offline storage first" >&2
  exit 1
fi
if [ ! -s ca-private/ca.key ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -subj "/CN=go-tangra internal CA" -keyout ca-private/ca.key -out ca/ca.crt \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  echo "internal CA created"
fi

issue() { # <host> <cert file> <key file>
  local h=$1 crt=$2 key=$3
  if [ -s "$h/$crt" ] && [ -s "$h/$key" ]; then echo "$h: certificate present, keeping it"; return; fi
  mkdir -p "$h"
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$h" \
    -keyout "$h/$key" -out "$h/server.csr" 2>/dev/null
  printf 'subjectAltName=DNS:%s,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\n' "$h" > "$h/ext.cnf"
  openssl x509 -req -in "$h/server.csr" -CA ca/ca.crt -CAkey ca-private/ca.key \
    -CAserial ca-private/ca.srl -CAcreateserial -days "$DAYS" -extfile "$h/ext.cnf" -out "$h/$crt" 2>/dev/null
  rm -f "$h/server.csr" "$h/ext.cnf"
  echo "$h: certificate issued"
}
for h in timescaledb valkey openfga vault; do issue "$h" server.crt server.key; done
issue rustfs rustfs_cert.pem rustfs_key.pem

# OS roots + internal CA. SSL_CERT_FILE replaces the system pool, so the public
# roots must stay in it (public SMTP relays, Let's Encrypt).
docker run --rm "$ROOTS_IMAGE" cat /etc/ssl/certs/ca-certificates.crt > ca/bundle.pem.tmp
cat ca/ca.crt >> ca/bundle.pem.tmp
mv ca/bundle.pem.tmp ca/bundle.pem

# Ownership: postgres (70) in timescale/timescaledb, valkey (999), vault (100),
# openfga (65532), rustfs (10001). Check with: docker run --rm --entrypoint id <image>
docker run --rm -v "$PWD:/t" "$ALPINE_IMAGE" sh -c '
  chmod 0755 /t /t/ca /t/timescaledb /t/valkey /t/openfga /t/vault /t/rustfs
  chmod 0644 /t/ca/ca.crt /t/ca/bundle.pem /t/*/server.crt /t/rustfs/rustfs_cert.pem
  chown 70:70       /t/timescaledb/server.key && chmod 0600 /t/timescaledb/server.key
  chown 999:999     /t/valkey/server.key      && chmod 0600 /t/valkey/server.key
  chown 100:1000    /t/vault/server.key       && chmod 0600 /t/vault/server.key
  chown 65532:65532 /t/openfga/server.key     && chmod 0600 /t/openfga/server.key
  chown 10001:10001 /t/rustfs/rustfs_key.pem  && chmod 0600 /t/rustfs/rustfs_key.pem'
echo "done: $OUT (move $OUT/ca-private to offline storage)"
