# OpenLDAP test image (repo-owned)

> Copy of go-tangra-auth `tests/integration/testdata/openldap/` for the dev stack.
> Keep the two in sync; the auth repository is the source of truth.

Test fixture for the auth service LDAP-import feature (spec 016). One image,
two consumers:

- **Integration tests** — `tests/integration/ldap_import_test.go` (go-tangra-auth)
  (T064, `//go:build integration`) builds it in-repo with testcontainers
  `FromDockerfile` and mounts a test CA + server certificate generated at test
  start.
- **Dev stack** — optional `openldap` service under the compose profile `ldap`
  in `docker-compose.yaml` builds this copy (`ldap/openldap`).

Everything under this directory is a test fixture. The seeded accounts and
their passwords are throwaway and only meaningful inside the test network.

## Why a repo-owned image (research D17, re-verified 2026-09-24)

The two popular OpenLDAP images are unsuitable as a base:

- **osixia/openldap** — `latest`/`stable`/`1.5.0` were last pushed on
  **2021-02-19** (OpenLDAP 2.4-era, years of unfixed CVEs). The only newer tag
  is `2.6.10-alpha` (pushed 2026-04), i.e. alpha quality.
- **bitnami/openldap** — Broadcom moved the free Bitnami catalogue to a frozen
  `bitnamilegacy` archive / paid "Bitnami Secure Images" in Aug–Sep 2025;
  `docker.io/bitnami/openldap:latest` now returns **404** for anonymous pulls
  and the legacy archive receives no security updates.

So the image is built from **Alpine 3.24.2, pinned by digest**, with OpenLDAP
**2.6.14** from Alpine's maintained, signature-verified packages. The build
fetches nothing but those packages; the LDAP schema files come from the pinned
base image itself.

## Files

| File | Role |
|---|---|
| `Dockerfile` | Alpine-by-digest + pinned `openldap`/`openldap-back-mdb`/`openldap-overlay-memberof`/`openldap-overlay-refint`/`openldap-clients`/`su-exec`; bootstraps `cn=config` from `slapd.ldif` (schema entries generated from the image's own schema files and spliced in); seeds `people.ldif`; generates the 1 MiB description; validates the final config with `slaptest`. |
| `slapd.ldif` | `cn=config` config: mdb database, TLS paths, modules (back_mdb, memberof, refint), indexes, ACLs, root DN. |
| `people.ldif` | The seed directory (see inventory below). The 1 MiB `description` on `uid=eng5` is generated at build time (kept out of this file so it stays reviewable). |
| `entrypoint.sh` | Waits for the mounted TLS material, stages it ldap-owned into `/run/openldap/tls`, starts `slapd` in the foreground as the `ldap` user: **StartTLS on 389, LDAPS on 636**. |

## Seed inventory (base `dc=example,dc=test`)

The connection base used throughout quickstart.md / the integration tests is
`ou=Engineering,dc=example,dc=test`.

| Entry | Purpose |
|---|---|
| `uid=eng1, eng2, eng5, eng6, eng7` | Engineering people **with mail** (eng6+eng7 share `eng-twins@example.test` — `duplicate_email` fixture). All `departmentNumber: 42`. |
| `uid=eng4` | Engineering person **without mail** (`no_email` fixture), `departmentNumber: 42`. |
| `uid=eng5` | Also carries the **1 MiB `description`** (generated at build; tests assert mapped-attribute searches never transfer it). |
| `uid=eng-outlier` | Has mail but `departmentNumber: 7` — must be excluded by a `(departmentNumber=42)` base filter. |
| `cn=eng-secret-alias` | `alias` object under Engineering pointing to `cn=hidden,ou=Secret` (outside the base). Clients search with `NeverDerefAliases`; the target must never leak. |
| `ou=Partners` | `referral` object (smart referral to `ldap://directory.example.invalid/...`). Returned as a continuation reference and **never followed**. |
| `uid=sales1..3` | `ou=Sales` people with mail — outside the Engineering base (invalid-base / sibling-scope tests). |
| `cn=hidden` | Alias target in `ou=Secret`, outside the base. |
| `cn=reader` | **Service account**: bind DN `cn=reader,dc=example,dc=test`, password `reader-password`. What the auth service binds as. |
| `cn=admin` (root DN) | Config-only root DN `cn=admin,dc=example,dc=test`, password `admin-password` — debugging only; tests never use it. |

Anonymous reads are denied (`by users read`); wrong passwords fail with 49;
missing bases with 32.

## TLS contract

The image contains **no key material**. Mount a server certificate + key at
`/tls` (environment `TLS_DIR` overrides the path); `entrypoint.sh` waits for
both files and stages them into ldap-owned `/run/openldap/tls/` so mounts with
root-only modes (compose secrets) work too. `slapd.ldif` points at the staged
paths. The test harness generates the CA + certificate per run (same pattern
as `selfSigned` in `tests/integration/harness_test.go`); the dev stack keeps
its CA under `ldap/`. Both listeners verify against the
mounted key: **389 = plain LDAP + mandatory StartTLS, 636 = LDAPS**
(TLS 1.3 with the harness's EC certs).

## Manual build & smoke test

```sh
# 1. Build
docker build -t go-tangra-openldap-test ldap/openldap

# 2. Throwaway CA + server certificate (tests generate their own per run)
mkdir -p /tmp/ldap-tls
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout /tmp/ldap-tls/ca.key -out /tmp/ldap-tls/ca.crt -days 1 -nodes -subj /CN=ldap-test-ca
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout /tmp/ldap-tls/server.key \
  -out /tmp/ldap-tls/server.csr -nodes -subj /CN=openldap
printf 'subjectAltName=DNS:localhost,DNS:openldap,IP:127.0.0.1\n' > /tmp/ldap-tls/san
openssl x509 -req -in /tmp/ldap-tls/server.csr -CA /tmp/ldap-tls/ca.crt \
  -CAkey /tmp/ldap-tls/ca.key -CAcreateserial -out /tmp/ldap-tls/server.crt -days 1 -extfile /tmp/ldap-tls/san

# 3. Run (slapd stays in the foreground; -e SLAPD_LOGLEVEL=stats for logs)
docker run --rm -v /tmp/ldap-tls:/tls:ro -p 3389:389 -p 3636:636 go-tangra-openldap-test

# 4. Verify (LDAPTLS_CACERT makes the client trust the throwaway CA)
export LDAPTLS_CACERT=/tmp/ldap-tls/ca.crt
ldapwhoami -ZZ -x -H ldap://127.0.0.1:3389 \
  -D cn=reader,dc=example,dc=test -w reader-password
ldapsearch -ZZ -x -H ldap://127.0.0.1:3389 \
  -D cn=reader,dc=example,dc=test -w reader-password \
  -b ou=Engineering,dc=example,dc=test '(&(objectClass=inetOrgPerson)(mail=*))' uid mail
```

`openldap-clients` is included in the image, so the same commands work with
`docker exec <container> ...` when the ports are not published.

## Changing the seed or config

Edit `people.ldif` / `slapd.ldif` and rebuild. Gotchas learned while building
this image:

- The `cn=config` bootstrap is order-sensitive: the generated schema entries
  must land between the global config and the mdb database (whose
  `olcDbIndex` references schema attributes). The Dockerfile splits
  `slapd.ldif` at the first `dn: olcDatabase=` line and splices the schema in;
  keep that shape when editing.
- slaptest-generated schema files use **relative DNs** (`dn: cn={0}core`) and
  no blank-line separators — the Dockerfile rewrites the DN suffix and inserts
  separators when splicing.
- LDIF **modifies** to the offline database need `slapmodify`, not `slapadd`
  (used for the 1 MiB description).
- Entry timestamps come from build time; no test may assert on them.

## Supply chain

Base image digest-pinned (`alpine:3.24.2@sha256:294b683…`, bump deliberately
and re-pin); apk packages pinned to the v3.24 index versions and verified
against Alpine's signing keys at install time. No other downloads.
