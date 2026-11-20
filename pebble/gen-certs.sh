#!/bin/sh
# Generate a dev CA + a Pebble listener cert whose SAN includes the container
# hostname "pebble", so lcm can VERIFY Pebble's TLS through the normal system
# trust pool (no InsecureSkipVerify). Idempotent: regenerates only if absent.
# The bundle = the base OS roots + this dev CA, so lcm keeps trusting public CAs
# while also trusting Pebble. Dev fixture only — never used outside the stack.
set -e
apk add --no-cache openssl ca-certificates >/dev/null 2>&1 || true
cd /certs
if [ -f pebble.crt ] && [ -f pebble.key ] && [ -f bundle.pem ]; then
  echo "pebble certs already present"; exit 0
fi
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt \
  -subj "/CN=pebble-dev-ca" -days 3650 >/dev/null 2>&1
cat > san.cnf <<CNF
[req]
distinguished_name = dn
[dn]
[v3]
subjectAltName = @alt
[alt]
DNS.1 = pebble
DNS.2 = localhost
IP.1  = 127.0.0.1
CNF
openssl req -newkey rsa:2048 -nodes -keyout pebble.key -out pebble.csr \
  -subj "/CN=pebble" >/dev/null 2>&1
openssl x509 -req -in pebble.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out pebble.crt -days 3650 -extfile san.cnf -extensions v3 >/dev/null 2>&1
cat /etc/ssl/certs/ca-certificates.crt ca.crt > bundle.pem
chmod 0644 *.crt *.pem pebble.key
echo "generated pebble.crt (SAN: pebble,localhost,127.0.0.1) + bundle.pem"
