# go-tangra deployment (v4)

Docker Compose deployment of the **go-tangra v4** platform: a fully containerized
stack bootstrapped end to end by **lcm** (the SPIFFE certificate authority).
Every service runs from its published image and obtains its identity
automatically; the only manual step is accepting the first operator invite.
The defaults are workstation credentials — never use them unchanged outside a
laptop or lab.

> **Looking for v3?** The v3 deployment (admin gateway, nginx front end,
> `lcm-init` certificates) lives on the
> [`main`](https://github.com/go-tangra/go-tangra-docker/tree/main) branch and
> its release tags. This `v4` branch is not compatible with it.

## What it deploys

Services: `lcm` (CA), `auth` (identity/tokens), `gateway` (edge + module proxy,
image `go-tangra-portal`), `notification`, `warden` (secrets, backed by Vault),
`deployer` (certificate deployment to infrastructure targets), `paperless`
(document management: S3 blobs, text extraction, full-text search, sharing),
`inventory` (endpoint agents report hardware/software/network snapshots; ingest
edge on `:9977`), `ipam` (subnets/IPs/devices/VLANs + active discovery and
IPMI/KVM), `asset` (IT asset management with inventory sync), `ticket` (helpdesk
with an inbound mail edge on `:9957`) and `dns` (PowerDNS management plane).
Each service's own repository (`go-tangra-<name>`, see `deploy/README.md` there)
documents its configuration in depth.

Infra: TimescaleDB, Valkey, OpenFGA, Mailpit, Vault, RustFS (object store),
Tika + Gotenberg (extraction), Pebble (test ACME CA), PowerDNS Authoritative 4.9
+ Recursor 5.3. Optional profiles: `metrics` (Prometheus for the dns dashboard)
and `ldap` (seeded test OpenLDAP for the auth directory import).

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yaml.example` | The stack. Copy to `docker-compose.yaml` (git-ignored). |
| `.env.example` | Every compose variable with its default. Copy to `.env` (git-ignored). |
| `up.sh` | One-command bring-up; prints the operator accept link. |
| `configs/<service>.yaml` | Container config of each service, mounted at `/app/deploy/container.yaml`. |
| `keys/<service>.kek` | Development key-encryption keys (see below). |
| `init-db.sql` | Databases and per-service roles, run on first database start. |
| `vault-init.sh` | Dev Vault KV mount, policy and AppRole for warden. |
| `pdns/`, `pebble/`, `prometheus/` | PowerDNS configs, Pebble config + cert job, Prometheus scrape config. |
| `ldap/` | `ldap` profile: certificate job and the test OpenLDAP build context. |
| `scripts/` | `apply-allow.sh` (re-apply the gateway allow-list), `integrity-test.sh`. |
| `Makefile` | Shortcuts (`make help`): init, up, down, reset, config, ps, logs, allow-list, integrity. |
| `ENROLLMENT.md` | How identities are issued and how to enroll a new service. |

All bind mounts are relative to the repository root, so run compose from here.

## Quick start

```sh
cp docker-compose.yaml.example docker-compose.yaml
cp .env.example .env          # optional: every value has a default
$EDITOR .env                  # at least OPERATOR_EMAIL
./up.sh                       # or: sg docker -c './up.sh'
```

`up.sh` loads `.env` (variables already set in the shell win), creates
`docker-compose.yaml` from the example if it is missing, detects the Docker
socket group for `dns`, pulls the images, brings the stack up and prints the
operator accept link. Plain compose works too:

```sh
docker compose up -d                          # project name freya-stack (from the file / .env)
docker compose --profile ldap --profile metrics up -d   # or COMPOSE_PROFILES=ldap,metrics in .env
```

> Docker note: if your shell isn't in the active `docker` group, prefix commands
> with `sg docker -c '…'`.

The project name defaults to `freya-stack` (`COMPOSE_PROJECT_NAME`); keep it
when you move an existing deployment here, or compose starts over with empty
volumes. The two PowerDNS containers have fixed names (`freya-pdns-auth`,
`freya-pdns-recursor`) because `configs/dns.yaml` restarts them by name.

## Images and versions

Every go-tangra service runs from
`${IMAGE_REGISTRY}/go-tangra-<repo>:${TANGRA_VERSION}`, by default
`ghcr.io/go-tangra/go-tangra-<repo>:4.0.0`; nothing is built here except the
optional test OpenLDAP (`ldap/openldap`). All services share one version:

```sh
TANGRA_VERSION=4.0.1 ./up.sh      # or set it in .env
```

| Compose service | Image repository | Override |
|---|---|---|
| `auth` (+ `auth-bootstrap`, `*-token` init jobs) | `go-tangra-auth` | `AUTH_IMAGE` |
| `gateway` (+ `gateway-bootstrap`) | `go-tangra-portal` | `GATEWAY_IMAGE` |
| `lcm` (+ `lcm-bootstrap`, `renewer`) | `go-tangra-lcm` | `LCM_IMAGE` |
| `notification`, `warden`, `deployer`, `paperless`, `inventory`, `ipam`, `asset`, `ticket`, `dns` | `go-tangra-<name>` | `<NAME>_IMAGE` |

Third-party images are variables too (`TIMESCALEDB_IMAGE`, `VALKEY_IMAGE`, …;
see `.env.example`). Each service image carries its own `deploy/` directory
(policy files included) at `/app/deploy`; the stack only mounts its container
config and its development key.

### Running a service from a local checkout

Build unreleased service code from a checkout of its repository with a
`docker-compose.override.yaml` (git-ignored; docker compose merges it
automatically, `up.sh` adds `--build` when it exists):

```yaml
# docker-compose.override.yaml
services:
  ipam:
    image: go-tangra/ipam:local
    build:
      context: ../go-tangra-ipam   # path to your checkout
      secrets: [npm_token]
      args: { APP_VERSION: local }
    volumes:
      # optional: use the checkout's policy instead of the one baked into the image
      - "../go-tangra-ipam/deploy/policy.yaml:/app/deploy/policy.yaml:ro"
secrets:
  npm_token: { environment: NODE_AUTH_TOKEN }
```

```sh
NODE_AUTH_TOKEN=$(gh auth token) docker compose up -d --build ipam
```

Service images install `@go-tangra/ui` from GitHub Packages during the build,
so the build needs `NODE_AUTH_TOKEN` with `read:packages` (passed as the
`npm_token` build secret; it never lands in an image layer).

### Publishing more ports

Only the gateway edge (`EDGE_PORT`, 8443), the ticket inbound mail edge
(`TICKET_INBOUND_PORT`, 9957), the inventory ingest edge
(`INVENTORY_INGEST_PORT`, 9977), Pebble (`PEBBLE_PORT`, 14000) and PowerDNS
(`PDNS_AUTH_PORT` 5300 / `PDNS_RECURSOR_PORT` 5301, loopback) are published;
each has a `*_BIND` address. Mailpit, RustFS, Vault and Prometheus stay on the
internal network. Publish one locally with the override file, e.g.:

```yaml
services:
  mailpit:
    ports: ["127.0.0.1:8025:8025"]      # web UI: http://localhost:8025
```

## Bring-up order

`up` is idempotent (safe to re-run). In order:

1. **infra** — TimescaleDB (+ `init-db.sql`), Valkey (ACL users), OpenFGA, Mailpit, Vault.
2. **`lcm-bootstrap`** — ensures the ONE DB-sealed **mesh root** and its default
   issuer, and mints the bootstrap SVIDs the control plane reads (`auth`).
3. **`gateway-bootstrap`** — seeds the gateway route allow-list (idempotent).
4. **`auth-bootstrap`** — seeds the platform tenant, roles, signing key and the
   first **operator invitation** for `OPERATOR_EMAIL` (idempotent; reuses a
   pending invite, never double-sends).
5. **`vault-init`** — sets up warden's Vault KV mount, policy and AppRole.
6. **`*-token`** init jobs — mint each workload's single-use join token.
7. **services start**: `lcm` self-issues; `gateway` and the workloads **enroll**
   over the network; `auth` reads its bootstrap SVID. All register with the
   gateway; the `renewer` keeps the file-based bootstrap certs fresh.

See **[ENROLLMENT.md](ENROLLMENT.md)** for how identities are issued and how to
enroll a new service.

## Sign in

The accept link is printed by `up.sh`, is in
`docker compose logs auth-bootstrap`, and is emailed to Mailpit (its UI is not
published on the host; see [Publishing more ports](#publishing-more-ports)). Open it to set a password + TOTP for the operator,
then sign in at <https://localhost:8443> (accept the dev self-signed cert).

### The browser certificate stays the same

`edge-cert-init` generates the gateway's browser certificate (`CN=localhost`,
SANs `localhost` + `127.0.0.1`, ~2 years) **once** into the `edge-cert` volume;
restarts and image rebuilds reuse it, so a browser exception you accepted keeps
working. It changes only after `down -v` (or deleting the `edge-cert` volume).

To stop seeing the warning at all, trust it once on the host:

```sh
docker compose cp edge-cert-init:/edge/tls.crt ./freya-dev-edge.crt
# Linux (Chrome/Chromium use the NSS store):
certutil -d sql:$HOME/.pki/nssdb -A -t "P,," -n "go-tangra dev stack" -i ./freya-dev-edge.crt
# macOS: open the file in Keychain Access and set it to "Always Trust".
```

Only trust it on your own development machine; the private key lives in the
Docker volume.

## Certificate lifetime / modes

- **Default:** SVIDs ~12 h, refreshed well before expiry, under a stable root.
- **Integrity mode** (short-lived SVIDs, proves non-disruptive rotation):
  ```sh
  CERT_TTL=5m RENEW_INTERVAL=210 docker compose up -d   # or set both in .env
  bash scripts/integrity-test.sh   # leaves rotate; root stays constant; leases hold
  ```

## Two kinds of certificate

lcm issues both:

1. **SVIDs** (`kind: svid`) — SPIFFE identities for mesh workloads
   (`spiffe://<trust-domain>/...`), used for service-to-service mTLS. This is
   what bootstrap and enrollment mint.
2. **Generic certificates** (`kind: generic`) — public/web certs for DNS names,
   obtained from an **ACME** issuer (Let's Encrypt-style, DNS-01).

Both appear in **Certificates** with a Kind chip; the "Request" dialog has an
**SVID (mesh)** tab and an **ACME / public** tab.

## ACME demo (Pebble)

The stack ships **Pebble**, a tiny test ACME CA, because no real CA is reachable
in the dev network. It runs with `PEBBLE_VA_ALWAYS_VALID=1`, so it skips the real
DNS-01 lookup and lcm's built-in **manual** DNS provider completes the order end
to end. `pebble-certs` mints Pebble a TLS cert whose SAN is `pebble`, and lcm
trusts it through `SSL_CERT_FILE` — TLS is verified, not disabled.

To issue a generic certificate from the UI:

1. **Issuers → New issuer**
   - Type **ACME**
   - Trust domain: `example.org`
   - ACME directory URL: `https://pebble:14000/dir`
   - DNS provider: **Manual / Out-of-band**
   - Save. (The ACME account key is generated server-side and sealed; you never
     handle key material.)
2. **Certificates → Request → ACME / public**
   - Pick the ACME issuer
   - Domains: e.g. `demo.example.com`
   - Request. A `kind: generic` certificate is issued by Pebble and listed.

Pebble's ACME directory is also exposed on the host at
<https://localhost:14000/dir> (self-signed; dev only).

## Web UI

Every module's UI is a federated remote on the shared kit `@go-tangra/ui`
(FlyonUI + Zod, published from the go-tangra platform repository). Each service image embeds its
UI, built against the published kit, so a UI change ships with a new service
image (or a local build through `docker-compose.override.yaml`, above). The shell lists a module in its navigation once the
module registers (`registered:true` in its health output); a remote built against
another kit major shows an error card with a retry in its own area only.

Browser flows (`ui/tests/e2e/*-flow.spec.ts`, `a11y.spec.ts` in each service repository)
run against this stack with `E2E_OPERATOR_EMAIL` / `E2E_OPERATOR_PASSWORD`
(`PW_CHANNEL=chrome` to use the system Chrome).

## Reset / teardown

```sh
docker compose down -v   # wipes DB, CA, tokens, SVID state
```

## Troubleshooting

- **A module shows `registered:false` / `identity_not_allowed` / `prefix_not_granted`:**
  its SPIFFE id or route prefix isn't in the gateway allow-list. Re-apply:
  `bash scripts/apply-allow.sh` (re-runs the idempotent `gateway-bootstrap` job).
  The allow-list is idempotent **per SPIFFE id** — to change an existing entry's
  prefixes you must update the `allow_list` row (see ENROLLMENT.md).
- **`lcm-bootstrap` (or another init) fails with `connection refused` to timescaledb on a *fresh* `up`:** a rare Postgres init-server race. The healthcheck is hardened (TCP probe) to prevent it; if you still hit it, just re-run `docker compose up -d` — timescaledb is healthy by then and the idempotent init containers complete.
- **Disk fills up after many local builds** (`ENOSPC`): `docker builder prune -af`.
- **`pull access denied` / `manifest unknown` for a `ghcr.io/go-tangra/...` image:**
  that `TANGRA_VERSION` is not published for the service; pick a released version
  or build it locally with `docker-compose.override.yaml`.
- **A restarted workload can't enroll:** its single-use token was already burned.
  With SVID persistence (a `*-state` volume) a restart reuses the stored SVID; a
  hard reset (`down -v`) clears state + mints a fresh token.

## Ticket inbound mail (dev)

`ticket` publishes its inbound mail edge on the host (`:9957`, TLS with the same
dev edge certificate as the gateway). `ticket-secrets-init` generates the relay
token once into the `ticket-secrets` volume; replies and acknowledgements go to
Mailpit. After creating a mailbox (Tickets → Mailboxes, e.g. `support@example.org`):

```sh
TOKEN=$(docker compose exec -T ticket cat /secrets/relay.token)
curl -sk https://localhost:9957/inbound/mail \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: message/rfc822" \
  -H "X-Iris-Recipient: support@example.org" \
  --data-binary @testdata/mail/plain.eml   # from a go-tangra-ticket checkout
# -> 202 {"outcome":"created","ticket_id":"…"}
```


## DNS (dev)

`dns-secrets-init` generates the PowerDNS and recursor API keys once into the
`dns-secrets` volume and writes the API include snippets for `pdns-auth` /
`pdns-recursor`; their HTTP APIs stay on the internal network. DNS is published
on **loopback only, on alternative ports** (host :53 is systemd-resolved,
:5353 is mDNS):

```sh
dig @127.0.0.1 -p 5300 example.test SOA        # authoritative (pdns-auth)
dig @127.0.0.1 -p 5301 www.example.test A      # resolver (pdns-recursor)
```

`dns` mounts the Docker socket (`DOCKER_SOCKET`) **read-write** (`group_add: ${DOCKER_GID}`,
detected by `up.sh`) so a platform admin's Configuration save can restart
`freya-pdns-auth` / `freya-pdns-recursor` — and nothing else. The socket is
root-equivalent on the host; see the risk note in
`deploy/README.md` in go-tangra-dns. Prometheus for the DNS dashboard:
`docker compose --profile metrics up -d prometheus` (without it
the dashboard shows "metrics unavailable").

## LDAP directory import (dev, optional profile `ldap`)

The `ldap` profile adds a seeded test OpenLDAP (`openldap`, built from
`ldap/openldap/` — a copy of go-tangra-auth
`tests/integration/testdata/openldap/`, the image the auth integration tests use) for trying the auth console's Directories → import flow:

```sh
docker compose --profile ldap up -d --build openldap
```

`ldap-certs` mints a stack test CA + server certificate (SANs `openldap`,
`localhost`, `127.0.0.1`) once into the `ldap-tls` volume and writes the CA to
**`ldap/ca.pem`** (git-ignored; the CA key is discarded, a new CA
only after `down -v`). Connection settings for the console:

| Field | Value |
|---|---|
| URL | `ldaps://openldap:636` (or `ldap://openldap:389` with StartTLS) |
| CA PEM | contents of `ldap/ca.pem` |
| Bind DN / password | `cn=reader,dc=example,dc=test` / `reader-password` |
| Base DN | `ou=Engineering,dc=example,dc=test` |

`openldap` publishes no host ports and shares the isolated `ldap` network
(`172.31.250.0/29`, fixed address `172.31.250.2`) with `auth` only.
`configs/auth.yaml` keeps `directory.allow_plaintext: false`, refuses the Docker
bridge ranges (`deny_cidrs: 172.16.0.0/12`) and re-allows exactly
`172.31.250.2/32` — auth logs the matching `allow_cidrs` warning at startup.
Without the profile the `ldap` network still exists but is empty. The console
e2e `console/tests/e2e/directory.spec.ts` (go-tangra-auth) uses these defaults
(Mailpit's UI is not published by default — publish it with an override and
point `E2E_MAILPIT_URL` at it).

## Development encryption keys

Service images never contain key material. The stack mounts each service's
development key-encryption key from `keys/<service>.kek` at the path
its config names (`/app/deploy/kek.dev`, or `/app/deploy/dev-kek.b64` for auth).
These keys are public development fixtures: never reuse them outside this stack.

## Credentials inside configs/

The compose-level credentials (`POSTGRES_PASSWORD`, `VALKEY_PASSWORD`,
`OPENFGA_PRESHARED_KEY`, `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY`,
`VAULT_DEV_ROOT_TOKEN`) are variables in `.env`. The mounted files below carry
the matching development values as plain text and are **not** templated;
change them together with the variables:

| Where | Credential (dev value) | Matches |
|---|---|---|
| `configs/<service>.yaml` `database.migrate_dsn` | `postgres:dev` | `POSTGRES_PASSWORD` |
| `configs/<service>.yaml` `database.dsn` + `init-db.sql` | `<service>_app` role password `dev` | each other |
| `configs/<service>.yaml` `valkey.password` | `dev` (user = service name) | `VALKEY_PASSWORD` |
| `configs/auth.yaml` `openfga.preshared_key` | `dev-openfga-key` | `OPENFGA_PRESHARED_KEY` |
| `configs/{paperless,asset,ticket}.yaml` `access_key` / `secret_key` | `paperless` / `paperless-dev-secret` | `RUSTFS_ACCESS_KEY` / `RUSTFS_SECRET_KEY` |
| `keys/<service>.kek` | development key-encryption keys | — |
| `ldap/openldap/people.ldif`, `slapd.ldif` (profile `ldap`) | `cn=reader` / `reader-password`, `cn=admin` / `admin-password` | the `openldap` healthcheck |

Generated at runtime into volumes and never committed: the mesh CA and SVIDs
(`certs`), join tokens (`tokens`), the edge certificate (`edge-cert`), warden's
AppRole credentials (`vault-creds`), the ticket relay token
(`ticket-secrets`), the PowerDNS API keys (`dns-secrets`) and the LDAP test CA
(`ldap-tls`, plus the git-ignored `ldap/ca.pem`). Production deployments
replace the file references with warden references (see each service's
`deploy/README.md`).
