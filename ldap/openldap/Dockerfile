# syntax=docker/dockerfile:1
# Repo-owned OpenLDAP test image for the auth service LDAP-import integration
# tests (tests/integration, research D17) and the optional dev-stack `ldap`
# profile. Test fixture only — the credentials seeded here are throwaway and
# valid only inside the test network.
#
# Base: Alpine pinned by digest (Constitution VI); OpenLDAP 2.6 comes from
# Alpine's maintained, signed packages — not from the osixia/bitnami images
# (stale/unavailable, see README.md). The TLS certificate is intentionally NOT
# baked in: the test harness generates a fresh test CA + server certificate per
# run and mounts it at /tls (see entrypoint.sh).
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# Pinned to the versions in the v3.24 stable index at authoring time.
RUN apk add --no-cache \
      openldap=2.6.14-r0 \
      openldap-back-mdb=2.6.14-r0 \
      openldap-overlay-memberof=2.6.14-r0 \
      openldap-overlay-refint=2.6.14-r0 \
      openldap-clients=2.6.14-r0 \
      su-exec=0.3-r0

WORKDIR /seed
COPY slapd.ldif people.ldif ./
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# Bootstrap cn=config. slapadd resolves everything in file order, so the
# schema entries must land between the global config and the mdb database
# (whose olcDbIndex references schema attributes). The schema entries (core,
# cosine, inetorgperson) are converted at build time from the schema files
# shipped INSIDE the pinned base image; nothing is fetched from anywhere but
# Alpine's package index. slapd.ldif stays the single readable config source —
# it is split at the first "dn: olcDatabase=" line for the splice.
RUN set -eux; \
    mkdir -p /tmp/gen; \
    { \
      echo 'include /etc/openldap/schema/core.schema'; \
      echo 'include /etc/openldap/schema/cosine.schema'; \
      echo 'include /etc/openldap/schema/inetorgperson.schema'; \
    } > /tmp/gen/schema.conf; \
    mkdir -p /tmp/gen/slapd.d; \
    slaptest -f /tmp/gen/schema.conf -F /tmp/gen/slapd.d; \
    awk '/^dn: olcDatabase=/{db=1} !db' slapd.ldif > /tmp/gen/00-global.ldif; \
    awk '/^dn: olcDatabase=/{db=1} db' slapd.ldif > /tmp/gen/40-database.ldif; \
    : > /tmp/gen/bootstrap.ldif; \
    for f in /tmp/gen/00-global.ldif \
        /tmp/gen/slapd.d/cn=config/cn=schema/cn={0}core.ldif \
        /tmp/gen/slapd.d/cn=config/cn=schema/cn={1}cosine.ldif \
        /tmp/gen/slapd.d/cn=config/cn=schema/cn={2}inetorgperson.ldif \
        /tmp/gen/40-database.ldif; \
    do \
      sed 's|^dn: cn={\([0-9]\)}\([A-Za-z0-9-]*\)$|dn: cn={\1}\2,cn=schema,cn=config|' "$f" >> /tmp/gen/bootstrap.ldif; \
      printf '\n' >> /tmp/gen/bootstrap.ldif; \
    done; \
    mkdir -p /etc/openldap/slapd.d /var/lib/ldap; \
    slapadd -F /etc/openldap/slapd.d -n 0 -l /tmp/gen/bootstrap.ldif

# Seed the directory (people.ldif) and attach the 1 MiB description fixture to
# uid=eng5 as a folded base64 LDIF modify. Content is deterministic (1 MiB of
# 'x') so image builds are reproducible; only the size matters to the tests.
RUN set -eux; \
    { \
      printf 'dn: uid=eng5,ou=Engineering,dc=example,dc=test\n'; \
      printf 'changetype: modify\n'; \
      printf 'add: description\n'; \
      head -c 1048576 /dev/zero | tr '\0' 'x' | base64 | fold -w 76 \
        | awk 'NR == 1 { print "description:: " $0; next } { print " " $0 }'; \
      printf '-\n\n'; \
    } > /tmp/gen/99-bigdesc.ldif; \
    slapadd -F /etc/openldap/slapd.d -l people.ldif; \
    slapmodify -F /etc/openldap/slapd.d -l /tmp/gen/99-bigdesc.ldif; \
    chown -R ldap:ldap /etc/openldap/slapd.d /var/lib/ldap; \
    mkdir -p /run/openldap; \
    chown ldap:ldap /run/openldap; \
    rm -rf /seed /tmp/gen

WORKDIR /
EXPOSE 389 636
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
