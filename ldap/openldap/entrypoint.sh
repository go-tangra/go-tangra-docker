#!/bin/sh
# Entrypoint for the Freya test OpenLDAP image.
#
# The TLS certificate/key are generated per test run (or per dev-stack boot)
# and mounted at $TLS_DIR — the image deliberately contains no key material.
# Wait briefly for the mount, stage it into a ldap-owned tmpfs copy (so mounts
# with root-only modes work regardless of ownership), then run slapd in the
# foreground as the unprivileged ldap user: plain LDAP on 389 (clients must
# use StartTLS; TLS is configured in slapd.ldif) and LDAPS on 636.
set -eu

TLS_DIR=${TLS_DIR:-/tls}
SLAPD_LOGLEVEL=${SLAPD_LOGLEVEL:-stats}

i=0
while [ ! -s "$TLS_DIR/server.crt" ] || [ ! -s "$TLS_DIR/server.key" ]; do
    i=$((i + 1))
    if [ "$i" -gt 250 ]; then
        echo "openldap-test: timed out waiting for server.crt/server.key in $TLS_DIR" >&2
        exit 1
    fi
    sleep 0.2
done

mkdir -p /run/openldap
install -d -o ldap -g ldap /run/openldap/tls
install -m 0444 -o ldap -g ldap "$TLS_DIR/server.crt" /run/openldap/tls/server.crt
install -m 0400 -o ldap -g ldap "$TLS_DIR/server.key" /run/openldap/tls/server.key
chown ldap:ldap /run/openldap

# -d keeps slapd in the foreground (PID 1) and logs to stderr.
exec su-exec ldap slapd -F /etc/openldap/slapd.d -h 'ldap:/// ldaps:///' -d "$SLAPD_LOGLEVEL"
