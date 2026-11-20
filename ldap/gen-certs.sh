#!/bin/sh
# Generate the dev-stack OpenLDAP test CA + server certificate (compose profile
# `ldap`). The server cert/key and the CA certificate go into the `ldap-tls`
# volume (mounted at /tls, where the openldap image's entrypoint expects
# server.crt + server.key); the CA certificate is also copied to
# ldap/ca.pem in the deployment directory (mounted at /out) — that is the PEM pasted into a
# directory connection. The CA private key is discarded after signing, so no
# CA key persists anywhere. Idempotent: regenerates only after `down -v`.
# Dev fixture only — never used outside the stack.
set -e
apk add --no-cache openssl >/dev/null 2>&1 || true
cd /tls
if [ -s server.crt ] && [ -s server.key ] && [ -s ca.crt ]; then
  echo "openldap certs already present"
else
  work=$(mktemp -d)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$work/ca.key" -out ca.crt -days 3650 -subj "/CN=freya-stack-ldap-test-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
  cat > "$work/ext.cnf" <<CNF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = DNS:openldap,DNS:localhost,IP:127.0.0.1
CNF
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout server.key -out "$work/server.csr" -subj "/CN=openldap" >/dev/null 2>&1
  openssl x509 -req -in "$work/server.csr" -CA ca.crt -CAkey "$work/ca.key" \
    -CAcreateserial -CAserial "$work/ca.srl" -out server.crt -days 730 \
    -extfile "$work/ext.cnf" >/dev/null 2>&1
  rm -rf "$work"
  chmod 0644 ca.crt server.crt
  chmod 0600 server.key
  echo "generated openldap server.crt (SAN: openldap,localhost,127.0.0.1)"
fi
# Hand the CA to the host, owned by whoever owns ./ldap.
cp ca.crt /out/ca.pem
chown "$(stat -c %u:%g /out)" /out/ca.pem
chmod 0644 /out/ca.pem
echo "wrote ldap/ca.pem"
