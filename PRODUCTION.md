# Production installation (go-tangra v4, Docker Compose)

This guide turns the development stack of this repository into a production
installation on **one Docker host**. Every statement about what a service
accepts or refuses is taken from the service code at `4.0.0`; anything that
could not be confirmed there is marked **(verify)**.

What you add on top of the development stack:

| File | Purpose |
|---|---|
| `docker-compose.production.yaml.example` | Production overlay; copied to `docker-compose.override.yaml` (merged automatically by compose). |
| `scripts/prod-init.sh` | Generates the git-ignored `prod/` tree: passwords, key-encryption keys, `init-db.sql` and production service configs. |
| `scripts/gen-internal-tls.sh` | Internal CA and server certificates for TimescaleDB, Valkey, OpenFGA, Vault, RustFS. |
| `configs/vault/config.hcl`, `scripts/vault-init-prod.sh` | Real (non-dev) Vault server and warden's AppRole setup. |

Contents:

1. [Overview and architecture](#1-overview-and-architecture)
2. [Host requirements](#2-host-requirements)
3. [Get the deployment](#3-get-the-deployment)
4. [Secrets and hardening](#4-secrets-and-hardening)
5. [Persistent data and backups](#5-persistent-data-and-backups)
6. [First start](#6-first-start)
7. [Operations](#7-operations)
8. [Security notes](#8-security-notes)
9. [Troubleshooting](#9-troubleshooting)
10. [Known limitations](#10-known-limitations)

---

## 1. Overview and architecture

```
                      Internet / LAN
                            |
          443 (-> 8443)     |        9957 (ticket inbound, MTA only)   53 (only if serving DNS)
     +----------------------+----------------+-------------------------+
     |                                       |                         |
+----v-------------------------+   +---------v---------+   +-----------v-----------+
| gateway  (image go-tangra-   |   | ticket inbound    |   | pdns-auth (PowerDNS   |
| portal) edge :8443 TLS 1.3,  |   | edge :9957 (TLS)  |   | Authoritative 4.9)    |
| public cert, UI shell, API   |   +---------+---------+   +-----------+-----------+
| proxy, module registry       |             |                         |  pdns-recursor 5.3
+----+------------------------+              |                         |  (internal only)
     |  SPIFFE mTLS (SVIDs issued by lcm; one mesh root sealed in lcm's database)
     |
     +--> auth (identity, tokens, operator invites, OpenFGA)      control plane
     +--> lcm  (mesh CA + certificate lifecycle, ACME)            CA
     +--> notification  warden  deployer  paperless  inventory    modules
          ipam  asset  ticket  dns                                (inventory ingest :9977)
                         |
  ---------------------- internal compose network only ----------------------
  TimescaleDB (one instance, 13 databases)   Valkey (cache, leases, event bus)
  OpenFGA (auth's authorization store)       Vault (warden's secret store)
  RustFS (S3: paperless, asset, ticket)      Tika + Gotenberg (paperless extraction)
  External: SMTP relay (mail out), MTA (mail in -> ticket), Let's Encrypt (lcm ACME)
```

- **Edge**: only the gateway faces browsers (`edge.addr: 0.0.0.0:8443`,
  TLS 1.3 only). In production it requires a certificate file
  (`edge.cert_file`/`edge.key_file`; the framework refuses to generate a
  self-signed one when `env: production`, `transport/edge/cert.go`). The file is
  re-read every minute, so renewals need no restart.
- **Mesh**: lcm holds the one mesh root (sealed in its database with its
  key-encryption key). `lcm-bootstrap` mints the file SVIDs for `auth` (and the
  renewer keeps them fresh); every other workload generates its own key and
  enrolls with a single-use join token minted by the `*-token` jobs, then renews
  over mTLS. See [ENROLLMENT.md](ENROLLMENT.md).
- **Registration**: modules register with the gateway only if their SPIFFE id
  and route prefixes are in the gateway allow-list (`gateway-bootstrap`, run on
  every `up`).

### Components: required, optional, development-only

| Component | Production status |
|---|---|
| `lcm`, `lcm-bootstrap`, `renewer`, `auth`, `auth-bootstrap`, `gateway`, `gateway-bootstrap`, `certs-init`, `*-token` jobs | **Required** (platform core) |
| TimescaleDB, Valkey, OpenFGA (+ `openfga-migrate`) | **Required** |
| `notification`, `warden`, `deployer`, `paperless`, `inventory`, `ipam`, `asset`, `ticket`, `dns` | Modules. `ipam` depends on `warden`; `asset` on `inventory`; `dns` on `ipam`, `pdns-*`. Removing one means editing the compose file (verify dependencies before you drop any). |
| Vault (+ `vault-init`) | **Required** for `warden`; must run as a real server (section 4.7), never in dev mode |
| RustFS | Required for `paperless`, `asset`, `ticket` (or point them at another S3 endpoint with TLS) |
| Tika, Gotenberg | Required for `paperless` |
| PowerDNS `pdns-auth`, `pdns-recursor` (+ `dns-secrets-init`) | Required for `dns` |
| `edge-cert-init` | Harmless in production: it still fills the `edge-cert` volume, but the overlay mounts your public certificate at `/edge` instead |
| `ticket-secrets-init` | Generates the inbound relay token (section 4.8) |
| **Mailpit** | **Development only** - replaced by a real SMTP relay; the overlay never starts it |
| **Pebble**, `pebble-certs` | **Development only** - replaced by Let's Encrypt; the overlay never starts them |
| `openldap`, `ldap-certs` (profile `ldap`) | **Development only** - test directory |
| Prometheus (profile `metrics`) | Optional - only feeds the dns dashboard (PowerDNS metrics) |

---

## 2. Host requirements

| Item | Guidance |
|---|---|
| Architecture | **linux/amd64** - the published `ghcr.io/go-tangra/*:4.0.0` images are amd64 only |
| CPU / RAM | Minimum 4 vCPU / 8 GB. Recommended 8 vCPU / 16 GB if paperless processes many documents (Tika is a JVM, Gotenberg runs LibreOffice/Chromium). The whole stack idles at roughly 1.1 GB RSS (measured on the development stack; TimescaleDB ~350 MB, Tika ~180 MB, each Go service 15-35 MB). |
| Disk | ~9 GB of images (TimescaleDB 2.4 GB, Gotenberg 2.4 GB, Tika 1.3 GB, Vault 0.7 GB) plus database, documents (RustFS) and logs. Start with 100 GB SSD for `/var/lib/docker`; size RustFS for your documents. |
| Docker | Docker Engine with Compose v2 **>= 2.24.4** (the overlay uses the `!override`/`!reset` merge tags). Validated with Docker 29.1.3 / Compose 5.5.1. |
| Time | NTP-synchronised clock (tokens and SVIDs are time-bound). |
| DNS | A public DNS name for the edge, e.g. `tangra.example.com`, pointing at the host. |

Docker log rotation (the stack sets no logging options; the default json-file
driver grows without limit). `/etc/docker/daemon.json`:

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "5" } }
```

`sudo systemctl restart docker` (applies to containers created afterwards).

### Firewall

Docker publishes ports through its own iptables rules, which **bypass ufw/firewalld
INPUT rules**. Control exposure with the `*_BIND` variables in `.env` (bind to a
specific address) and, for source filtering, the `DOCKER-USER` chain.

| Port | Expose publicly? | Variable |
|---|---|---|
| 443 -> gateway 8443 | **Yes** - browsers and API clients | `EDGE_PORT=443`, `EDGE_BIND` |
| 80 -> http-redirect | **Yes** - plain-HTTP visitors get a `301` to `PUBLIC_ORIGIN` (path and query kept; the target never comes from the Host header), and Let's Encrypt HTTP-01 challenges are served from `prod/acme` | `HTTP_PORT=80`, `HTTP_BIND` |
| 9957 ticket inbound mail edge | Only to your MTA's addresses, and only if you use ticket email intake | `TICKET_INBOUND_PORT`, `TICKET_INBOUND_BIND` |
| 53 udp+tcp PowerDNS Authoritative | Only if pdns-auth serves public zones (and for Let's Encrypt DNS-01 via `freya-dns`) | `PDNS_AUTH_PORT=53`, `PDNS_AUTH_BIND=<public IP>` |
| PowerDNS Recursor | **Never** publicly (open resolver). Keep `PDNS_RECURSOR_BIND=127.0.0.1` or an internal address | `PDNS_RECURSOR_*` |
| 9977 inventory ingest | Not until you put a TLS proxy in front (section 10). Keep `INVENTORY_INGEST_BIND=127.0.0.1` | `INVENTORY_INGEST_*` |
| 25 | Not by this stack. Inbound mail is received by **your** MTA, which then posts to 9957 | - |
| everything else | No. TimescaleDB, Valkey, OpenFGA, Vault, RustFS, Tika, Gotenberg, Prometheus and the PowerDNS HTTP APIs are not published | - |

For `PDNS_AUTH_BIND` use the concrete public address: on hosts running
systemd-resolved, `0.0.0.0:53` collides with its stub listener on 127.0.0.53.
An empty `PDNS_*_BIND` does **not** mean "all interfaces" (the compose file
falls back to `127.0.0.1`).

---

## 3. Get the deployment

```sh
git clone -b v4 https://github.com/go-tangra/go-tangra-docker.git /opt/tangra
cd /opt/tangra
git checkout <release-tag>        # optional: pin the deployment files to a tag
cp docker-compose.yaml.example docker-compose.yaml
cp .env.example .env
cp docker-compose.production.yaml.example docker-compose.override.yaml
```

Edit `.env`:

```sh
COMPOSE_PROJECT_NAME=tangra        # prefixes containers/volumes; never change it later
TANGRA_VERSION=4.2.0               # pin; the go-tangra services share it...
GATEWAY_IMAGE=ghcr.io/go-tangra/go-tangra-portal:4.3.0     # ...except where a service's release
AUTH_IMAGE=ghcr.io/go-tangra/go-tangra-auth:4.4.0          # differs (.env.example)
LCM_IMAGE=ghcr.io/go-tangra/go-tangra-lcm:4.3.0
NOTIFICATION_IMAGE=ghcr.io/go-tangra/go-tangra-notification:4.4.0
WARDEN_IMAGE=ghcr.io/go-tangra/go-tangra-warden:4.4.0
OPERATOR_EMAIL=ops@example.com     # first operator (invite goes here)
TZ=Europe/Sofia
EDGE_PORT=443
EDGE_BIND=                         # or the public address
TICKET_INBOUND_BIND=<address your MTA reaches>   # or 127.0.0.1 if unused
INVENTORY_INGEST_BIND=127.0.0.1
PDNS_AUTH_BIND=127.0.0.1           # or the public IP with PDNS_AUTH_PORT=53
PDNS_RECURSOR_BIND=127.0.0.1
#COMPOSE_PROFILES=metrics          # optional Prometheus for the dns dashboard
```

Pin the third-party images too: `.env.example` uses moving tags
(`timescale/timescaledb:latest-pg16`, `rustfs/rustfs:latest`,
`apache/tika:latest-full`, ...). Set `TIMESCALEDB_IMAGE`, `RUSTFS_IMAGE`,
`TIKA_IMAGE`, `VALKEY_IMAGE`, `VAULT_IMAGE`, `GOTENBERG_IMAGE` to exact versions
or digests. The TimescaleDB extension version must match between backup and
restore.

`up.sh` is a workstation helper (it prints a `localhost` sign-in URL and adds
`--build` when an override file exists). In production use `docker compose`
directly.

---

## 4. Secrets and hardening

### 4.1 What `env: production` enforces

Every service config has `env:`. Production mode (`env: production`,
case-insensitive) makes `Validate()` refuse the development conveniences at
start-up. Taken from each service's `internal/config/config.go`:

| Service | Refused when `env: production` |
|---|---|
| all (framework) | `WithInsecureLocalDev` / `WithAllowAllPolicy`; edge listener without `cert_file`/`key_file` |
| auth | `db.dsn` without `sslmode=verify-full`/`verify-ca`; `valkey.allow_plaintext`; `openfga.allow_plaintext` (an `http://` OpenFGA URL needs it); `email.allow_plaintext`; `email.transport: log`; `directory.allow_plaintext` |
| gateway | `edge.cert_file`/`key_file` missing; `valkey.allow_plaintext`; `db.dsn` without verify-full/verify-ca |
| lcm | db sslmode; `valkey.allow_plaintext`; `acme.allow_plaintext_dns` |
| warden | db sslmode; `valkey.allow_plaintext`; `vault.allow_plaintext` (an `http://` Vault needs it); `mail.allow_plaintext` |
| notification | db sslmode; `valkey.allow_plaintext`; `smtp.allow_plaintext` (email channels with `tls: none`) |
| deployer, paperless | db sslmode; `valkey.allow_plaintext` |
| inventory | db sslmode; `valkey.allow_plaintext`; `ingest.insecure` |
| ipam | db sslmode; `valkey.allow_plaintext`; `mesh_enroll.insecure` |
| asset | db sslmode; `valkey.allow_plaintext`; `object_store.use_ssl: false`; `mesh_enroll.insecure` |
| ticket | db sslmode; `valkey.allow_plaintext`; `object_store.use_ssl: false`; `inbound.insecure_dev`; `smtp.tls: none`; `mesh_enroll.insecure`; **`file:` secret references are rejected when resolved** |
| dns | db sslmode; `valkey.allow_plaintext`; `mesh_enroll.insecure`; **`file:` secret references are rejected when resolved** |

The development configs trip these immediately; for example every service
except the gateway stops with `config: db.dsn must use sslmode=verify-full (or
verify-ca) in production`, and the gateway with `config: production refuses
valkey.allow_plaintext`. So production mode **requires TLS to TimescaleDB,
Valkey, OpenFGA and Vault** (and to the S3 store for asset/ticket). This guide
sets that up (section 4.4).

Not using production mode and relying on network isolation instead is possible
(the compose network is not published), but you then lose every guard in the
table, including the edge-certificate check; this guide does not recommend it.
**ticket** and **dns** are the exception: they cannot run in production mode
yet (section 10), so `prod-init.sh` keeps `env: dev` for them and sets
production-equivalent values (TLS everywhere) by hand.

### 4.2 Generate the production tree (`scripts/prod-init.sh`)

```sh
PUBLIC_HOST=tangra.example.com TRUST_DOMAIN=infra.example.com \
SMTP_HOST=smtp.example.com SMTP_PORT=587 \
SMTP_USERNAME=tangra@example.com SMTP_PASSWORD='relay-password' \
MAIL_FROM=tangra@example.com \
./scripts/prod-init.sh
```

(`PUBLIC_PORT=8443` if browsers use a non-443 port; omit `SMTP_USERNAME` /
`SMTP_PASSWORD` for an IP-allow-listed relay; `TRUST_DOMAIN`: section 4.12.)

It creates `prod/` (git-ignored, mode 0700/0600):

| Path | Content |
|---|---|
| `prod/credentials.env` | Generated `POSTGRES_PASSWORD`, `VALKEY_PASSWORD`, `OPENFGA_PRESHARED_KEY`, `RUSTFS_ACCESS_KEY`/`SECRET_KEY` and one password per database role. Generated **once**, never replaced. |
| `prod/keys/<svc>.kek` | Fresh key-encryption keys (section 4.3). Generated once, never replaced. |
| `prod/init-db.sql` | `init-db.sql` with the generated role passwords. |
| `prod/configs/<svc>.yaml` | Copies of `configs/` with the production settings below. Rewritten only with `FORCE=1`. |
| `prod/secrets/smtp.password` | Relay password for notification's `platform_email` (`password_file: /run/secrets/smtp.password`). |
| `prod/secrets/ticket-smtp.password` | Relay password for ticket (`smtp.password_ref: file:/run/secrets/smtp.password`). |
| `prod/edge/` | Empty: put the public certificate here (section 4.5). |
| `prod/policies/<svc>.yaml` | `policies/<svc>.yaml` with `TRUST_DOMAIN`; rewritten on every run (section 4.12). |

It also writes those compose credentials and `PUBLIC_HOST` into `.env`.

Changes it makes in `prod/configs/`:

- `env: production` (ticket, dns: `env: dev` with a comment, see 4.1).
- `db.dsn` = `postgres://<svc>_app:<generated>@timescaledb:5432/<svc>?sslmode=verify-full&sslrootcert=/tls/ca.crt`;
  `db.migrate_dsn` = the same with the `postgres` superuser (migrations run as it).
- `valkey`: generated password, `allow_plaintext: false`, `ca_file: /tls/ca.crt`.
- every `https://localhost:8443` (auth `issuer`, gateway `public_origin`,
  `edge.allowed_origins`, `auth.issuer`, each module's `gateway.issuer`, warden
  `share.public_origin`) -> `https://<PUBLIC_HOST>`; all must be identical, the
  token issuer is compared literally.
- workload enrollment: `enroll_url: https://<PUBLIC_HOST>:8443/api/lcm/v1/enroll`
  and `insecure: false` (section 4.10). The gateway enrolls at lcm with
  `ca_file: /certs/ca.pem` instead of `insecure` (section 4.10).
- auth: `openfga: { url: https://openfga:8080, ..., allow_plaintext: false }`,
  `email: { transport: notification }`, directory `allow_cidrs: []` (the test
  LDAP address is gone).
- warden: `vault.address: https://vault:8200`, `allow_plaintext: false`,
  `ca_file: /tls/ca.crt`; `mail: { transport: notification }`.
- notification `smtp.allow_plaintext: false`, `platform_email` from `SMTP_*`
  (section 4.6); lcm `acme.allow_plaintext_dns: false`;
  inventory `ingest.insecure: false`.
- paperless/asset/ticket `object_store`: `use_ssl: true`, generated keys.
- ticket `smtp`: real relay, `tls: starttls` (587) or `implicit` (465),
  `allow_plaintext: false`, `mail_domain` from `MAIL_FROM`.
- dns `docker.enabled: false` (section 8).
- `discovery.static.warden: ["warden:9843"]` for ipam/ticket/dns (the
  development configs name port 9743; warden listens on 9843,
  `configs/warden.yaml` `server.grpc_addr`).

All production configs produced this way pass each service's `Validate()`
(checked by starting every 4.0.0 image against them without network).

Review the result before the first start:

```sh
git diff --no-index configs prod/configs
```

> `prod/` holds every secret of the installation. Back it up encrypted and off
> the host (section 5). The overlay mounts these files into containers that run
> as root (`user: "0:0"` in `docker-compose.yaml`), so 0600 files owned by your
> deploy user are readable.

### 4.3 Key-encryption keys (KEKs)

Every service except gateway and warden seals its secrets (CA keys, issuer and
provider credentials, tenant secrets, agent credentials, ...) with a 32-byte
key-encryption key. Format accepted by the loaders (`internal/sealed` in the
modules, `internal/config` KEK.Load in auth): **base64 (standard encoding) of
exactly 32 random bytes**, surrounding whitespace ignored (modules also accept
unpadded base64 or 32 raw bytes; auth only padded base64). `prod-init.sh`
creates them with:

```sh
openssl rand -base64 32 > prod/keys/<svc>.kek
```

- The overlay mounts `prod/keys/<svc>.kek` at the path the config names
  (`/app/deploy/kek.dev`, for auth `/app/deploy/dev-kek.b64`). The bind mount
  replaces the development key at the same target, so `keys/*.kek` are never
  mounted. (The file name still says "dev"; only the content matters.)
- **Never reuse `keys/*.kek`.** They are public development fixtures (two of
  them, `deployer.kek` and `notification.kek`, are even identical).
- **Losing a KEK loses the data it sealed.** The lcm KEK protects the mesh root
  CA; without it the lcm database backup is useless.
- `kek.source: env` (with `kek.env: VAR_NAME`) is the alternative to a file.
- There is no in-place KEK rotation command yet (lcm `docs/operations.md`:
  export a backup with credentials under the old key and import it under the new).

### 4.4 Internal TLS (TimescaleDB, Valkey, OpenFGA, Vault, RustFS)

```sh
./scripts/gen-internal-tls.sh      # writes prod/tls
```

It creates a private CA and server certificates whose SAN is the compose
service name (plus `localhost`/`127.0.0.1` for health checks), sets key ownership
to the uid each image runs as (postgres 70, valkey 999, vault 100, openfga
65532, rustfs 10001), and builds `prod/tls/ca/bundle.pem` = OS roots + the
internal CA. Then **move `prod/tls/ca-private/` (the CA key) off the host**; you
need it back only to issue new certificates.

How the overlay uses it (all verified with the images: TLS handshakes with
hostname verification for Postgres `verify-full`, Valkey, OpenFGA, Vault and
RustFS):

| Server | Server side | Clients verify with |
|---|---|---|
| TimescaleDB | `postgres -c ssl=on -c ssl_cert_file=... -c ssl_key_file=...` | `sslrootcert=/tls/ca.crt` in every DSN (incl. OpenFGA's datastore URI) |
| Valkey | `--port 0 --tls-port 6379 --tls-cert-file ... --tls-auth-clients no` | `valkey.ca_file: /tls/ca.crt` |
| OpenFGA | `OPENFGA_HTTP_TLS_ENABLED/CERT/KEY` | auth has no CA option: `SSL_CERT_FILE=/tls/bundle.pem` |
| Vault | `tls_cert_file`/`tls_key_file` in `configs/vault/config.hcl` | warden `vault.ca_file: /tls/ca.crt`; CLI `VAULT_CACERT` |
| RustFS | `RUSTFS_TLS_PATH=/tls-server` (`rustfs_cert.pem`, `rustfs_key.pem`) | S3 client has no CA option: `SSL_CERT_FILE=/tls/bundle.pem` |

`SSL_CERT_FILE` replaces Go's system pool, which is why the bundle keeps the OS
roots (public SMTP relays, Let's Encrypt, the public edge certificate). The
overlay sets it on every go-tangra container.

Valkey note: the overlay keeps the development ACL layout (one user per
service, all with `~* &* +@all`, one shared password). Per-service passwords
and narrower ACLs are possible but need matching edits in each
`prod/configs/<svc>.yaml` and the Valkey command (verify).

### 4.5 Public edge certificate

The gateway needs a certificate for `PUBLIC_HOST` from a publicly trusted CA
(workloads verify it when they enroll, section 4.10). Place the full chain and
key at:

```
prod/edge/tls.crt   # full chain, PEM
prod/edge/tls.key   # private key, PEM
```

Example with certbot on the host. Port 80 belongs to the `http-redirect`
service (HTTP -> HTTPS), which also serves the HTTP-01 challenge files from
`prod/acme`, so certbot runs in **webroot** mode against that directory:

```sh
sudo certbot certonly --webroot -w /opt/tangra/prod/acme -d tangra.example.com \
  --deploy-hook 'install -m 0644 "$RENEWED_LINEAGE/fullchain.pem" /opt/tangra/prod/edge/tls.crt &&
                 install -m 0600 "$RENEWED_LINEAGE/privkey.pem"   /opt/tangra/prod/edge/tls.key &&
                 cd /opt/tangra && docker compose restart ticket'
```

Copy the files (do not bind-mount `/etc/letsencrypt/live`, its entries are
symlinks). The gateway re-reads the files every minute; ticket reads its
inbound certificate only at start (hence the restart). The same files serve the
ticket inbound edge (`inbound.tls_cert_file`/`tls_key_file`), so your MTA must
connect to `https://<PUBLIC_HOST>:9957`. The inventory agent ingest edge
(`ingest.tls_cert_file`/`tls_key_file`, port 9977) uses them too and re-reads
them every minute; agents connect to `https://<PUBLIC_HOST>:9977`. This needs
inventory 4.1.0 or later (4.0.0 served ingest in plaintext and connected its
registry to Valkey without TLS).

**HTTP -> HTTPS.** The `http-redirect` service (unprivileged nginx, read-only
root, all capabilities dropped) answers every request on port 80 with a `301`
to `PUBLIC_ORIGIN` plus the original path and query. `prod-init.sh` writes
`PUBLIC_ORIGIN` into `.env` (`https://PUBLIC_HOST`, with `:PUBLIC_PORT` when that
is not 443). Only `/.well-known/acme-challenge/` is served instead, from
`prod/acme`, for certbot. For the very first certificate, start just this
service (`docker compose up -d http-redirect`), run certbot, then start the rest.

The edge speaks **TLS 1.3 only**. Behind a TLS-terminating load balancer add its
address to `edge.trusted_proxies` (CIDRs allowed to set `X-Forwarded-For`) in
`prod/configs/gateway.yaml`; the gateway itself must still terminate TLS.

### 4.6 Real SMTP (Mailpit is never used in production)

Operator prerequisites for the sending domain (the platform does not sign mail;
there is no DKIM code in any service - your relay must sign):

- **SPF**: `v=spf1 include:<your relay> -all` (or the relay's IPs) on the
  `MAIL_FROM` domain.
- **DKIM**: signing enabled on the relay for that domain, public key published.
- **DMARC**: `_dmarc.<domain> TXT "v=DMARC1; p=quarantine; rua=mailto:..."`.
- **Reverse DNS**: the relay's sending IP has a PTR matching its HELO name (your
  provider's job if you use a hosted relay).

**One relay for the platform (notification ≥ 4.2.0, auth/warden ≥ 4.2.0).**
The platform's outbound mail - invitations, account resets, password recovery
(auth) and share links (warden) - goes through the notification module. The
relay is configured once, in `prod/configs/notification.yaml`:

```yaml
platform_email:
  host: mx01.example.net          # a HOST NAME that matches the relay certificate
  port: 587                       # 587 = STARTTLS, 465 = implicit TLS
  tls: starttls
  username: 'tangra@example.net'  # omit (with password_file) for an IP-allow-listed relay
  password_file: /run/secrets/smtp.password   # overlay mounts prod/secrets/smtp.password
  from: 'tangra@example.net'
  allow_plaintext: false
```

At every start notification turns this into the **Platform email** channel
(Notification -> channels, marked *Managed*: read-only, test send allowed).
auth and warden have no relay settings (`email`/`mail: { transport:
notification }`); old relay keys there are ignored with a start-up warning.
The wording of the mails is editable under Notification -> templates
(`auth.invite`, `auth.account_reset`, `auth.recovery`, `warden.share`; *System*
templates can be restored to the built-in text). Links in those mails are
stored as `[redacted]` in the notification log.

TLS rules: the certificate is verified against `host` - use the relay's name
(e.g. `mx01.kumo.example.net` for a `*.kumo.example.net` certificate), never
its IP address; add an `extra_hosts` entry to notification if that name does
not resolve inside the containers. STARTTLS never falls back to plaintext.
`tls: none` needs `allow_plaintext: true` (warned at every start) and cannot be
combined with a username.

Verify delivery: Notification -> channels -> Platform email -> **Test**, then
invite a user; the notification log shows the entry (`sent` / the relay's
reason). auth keeps undelivered invitations queued and retries with backoff
(30 s doubling up to 1 h); a message that can never be sent is reported once
(`email_given_up`).

| Service | What it sends | Settings | TLS rules |
|---|---|---|---|
| notification | platform mail (above) and tenant email channels | `platform_email` in the config; tenant channels **per channel in the UI** (host, port, `tls: implicit/starttls/none`, username, password sealed with the notification KEK, from, reply-to); `smtp.allow_plaintext` refuses `tls: none` tenant channels | as above |
| ticket | public replies, acknowledgements | `smtp: { host, port, tls: implicit/starttls, allow_plaintext: false, username, password_ref, mail_domain, timeout_seconds }`. From = the mailbox address. `password_ref: file:/run/secrets/smtp.password` (the overlay mounts `prod/secrets/ticket-smtp.password`) | `tls: none` refused in production; PLAIN auth only over TLS |

`prod-init.sh` fills notification's `platform_email` and ticket from
`SMTP_*`/`MAIL_FROM` (password into `prod/secrets/smtp.password` and
`prod/secrets/ticket-smtp.password`). Without `smtp.host`, ticket refuses
public replies (`reply_unavailable`) and skips acknowledgements.

**Upgrading an installation that still has relay settings in auth/warden**:
copy host, port, username and from from `prod/configs/auth.yaml` (`email:`)
into `platform_email` in `prod/configs/notification.yaml` (tls: `starttls` for
587, `implicit` for 465), write the password to `prod/secrets/smtp.password`
(`install -m 0600`), set `email: { transport: notification }` in auth and
`mail: { transport: notification }` in warden, add
`notification: ["notification:9943"]` under `discovery.static` in both auth
and warden (without it auth logs `discovery: unknown service "notification"`
and keeps the mail queued), add the secret mount to notification in
`docker-compose.override.yaml` if the relay needs a login, then upgrade
notification first and auth/warden after it.

### 4.7 Vault (warden's secret store)

The development stack runs Vault in **dev mode: in memory, auto-unsealed, root
token `dev-root`**. Every warden secret is lost when that container restarts.
Production uses a real server:

- `configs/vault/config.hcl`: integrated storage (`storage "raft"`,
  recommended; path `/vault/file` on the `vault-data` named volume), TLS
  listener on 8200 with the internal-CA certificate (`tls_min_version = "tls13"`),
  `api_addr = "https://vault:8200"`. The v3 deployment used
  `storage "file" { path = "/vault/file" }` - still valid, swap the block if you
  prefer it.
- overlay: `command: ["server"]` (the image entrypoint runs
  `vault server -config=/vault/config`), `IPC_LOCK` (already in the base file),
  `VAULT_ADDR=https://127.0.0.1:8200`, `VAULT_CACERT=/tls/ca.crt`. The base
  healthcheck `vault status` exits 0 only when Vault is **initialised and
  unsealed** (2 while sealed), so `vault-init`, `warden` and everything that
  depends on warden (`ipam`, then `dns`) wait until Vault is unsealed.
- `vault-init` runs `scripts/vault-init-prod.sh`: it never initialises or
  unseals Vault and stores no token. If warden's AppRole files exist in the
  `vault-creds` volume it exits 0 (so every `up` passes); otherwise it needs a
  one-time admin token and creates exactly what the development
  `vault-init.sh` creates and `prod/configs/warden.yaml` expects: KV v2 mount
  `warden` (`vault.mount`), policy `warden`, AppRole `warden`, files
  `/vault-creds/role_id` and `/vault-creds/secret_id`
  (`vault.role_id_file`/`secret_id_file`).

Keeping Vault on the internal network only (it is not published) is not a
substitute for TLS here: warden refuses `vault.allow_plaintext` in production.

#### Initialisation and unseal - choose one

**(a) Recommended: Shamir shares held by operators.**

```sh
docker compose up -d vault
docker compose exec vault vault operator init -key-shares=5 -key-threshold=3
# -> 5 unseal keys + initial root token. Give each key to a different person;
#    store them offline (password manager / sealed envelopes). Never on this host.
docker compose exec vault vault operator unseal      # repeat 3 times, 3 different keys
VAULT_TOKEN=<root token> docker compose run --rm vault-init
docker compose exec -e VAULT_TOKEN=<root token> vault vault token revoke -self
```

After **every** Vault restart (host reboot, upgrade) Vault comes up sealed:
warden stays unhealthy and its dependants wait until three key holders run
`docker compose exec vault vault operator unseal`. A new root token, when
needed, is created with `vault operator generate-root` and the key quorum.

**(b) Auto-unseal** with a cloud KMS (`seal "awskms"`, `"gcpckms"`,
`"azurekeyvault"`) or another Vault's Transit engine (`seal "transit"`): add the
seal stanza to `configs/vault/config.hcl` and pass its credentials to the
`vault` service. `vault operator init` then returns recovery keys instead of
unseal keys (keep them offline too). See the HashiCorp seal documentation
(verify the stanza for your provider).

**(c) Accepted-risk single key (small installs only).** The v3 deployment
initialised with `-key-shares=1 -key-threshold=1` and stored the unseal key and
root token in the credentials volume, unsealing itself on start. That puts the
key **next to the data it protects**: anyone who can read the Docker volumes
(host root, a backup) can unseal and read every secret. If you accept that,
write it down, keep the root token out of the volume, and still back up the key
separately.

#### Rotating warden's AppRole secret

```sh
ROTATE_SECRET_ID=1 VAULT_TOKEN=<admin token> docker compose run --rm vault-init
docker compose restart warden
```

The previous `secret_id` is destroyed. (Verify whether warden re-reads the
file without a restart; the restart is the safe path.)

### 4.8 Ticket inbound mail and the relay token

`ticket-secrets-init` generates the relay token once into the `ticket-secrets`
volume (`inbound.relay_token_ref: file:/secrets/relay.token`). Read it with:

```sh
docker compose exec ticket cat /secrets/relay.token
```

Rotate it by deleting that file (`docker compose run --rm --entrypoint sh
ticket-secrets-init -c 'rm /secrets/relay.token'`), then `docker compose up -d`
(the init recreates it; ticket re-reads references every
`secrets.refresh_seconds`) and update the MTA.

Inbound mail needs **your own MTA** (Postfix, KumoMTA, a hosted inbound
service, ...) that accepts mail for the support addresses (MX records point at
it) and posts each message to the ticket inbound edge
(`go-tangra-ticket` `deploy/README.md`):

```
POST https://<PUBLIC_HOST>:9957/inbound/mail
Authorization: Bearer <relay token>
Content-Type: message/rfc822
X-Ticket-Recipient: support@example.com      (or X-Iris-Recipient)
<raw RFC 822 message>
```

`202` = accepted (also for a duplicate Message-Id, safe to retry), `503` =
retry later. Only addresses configured as active mailboxes (Tickets ->
Mailboxes) are routed. A Postfix sketch (verify for your setup):

```
# /etc/postfix/master.cf
tangra   unix  -  n  n  -  -  pipe
  flags=Rq user=nobody argv=/usr/local/bin/tangra-deliver ${recipient}
# /etc/postfix/transport:  support@example.com  tangra:
```

```sh
#!/bin/sh
# /usr/local/bin/tangra-deliver <recipient>; exit 75 = defer (Postfix retries)
curl -sS --fail --max-time 60 -X POST "https://tangra.example.com:9957/inbound/mail" \
  -H "Authorization: Bearer $(cat /etc/tangra/relay.token)" \
  -H "Content-Type: message/rfc822" -H "X-Ticket-Recipient: $1" \
  --data-binary @- >/dev/null || exit 75
```

### 4.9 PowerDNS API keys and the dns module

`dns-secrets-init` generates the PowerDNS and recursor API keys once into the
`dns-secrets` volume and writes the API include snippets; the APIs listen only
on the internal network (`pdns.allow_plaintext: true` is accepted, with a
warning, because PowerDNS has no mTLS). dns reads them through `file:`
references, which is why dns keeps `env: dev` (section 10). Rotate by removing
the `dns-secrets` volume and re-running `dns-secrets-init`, `pdns-auth`,
`pdns-recursor` and `dns` (go-tangra-dns `deploy/README.md`).

### 4.10 Enrollment TLS (`enroll.insecure` / `mesh_enroll.insecure`)

`insecure: true` skips server verification on the **first-enroll** HTTPS call
only (renewals are always SPIFFE-verified). ipam, asset, ticket and dns refuse
it in production. With `insecure: false` the dial uses the system trust pool
and the host name of `enroll_url`, so:

- workloads enroll at `https://<PUBLIC_HOST>:8443/api/lcm/v1/enroll`;
- the overlay gives the gateway the network alias `${PUBLIC_HOST}`, so that name
  resolves to the gateway inside the compose network (container port 8443) and
  the public certificate matches (verify on your first start: look for
  `identity ready` in each module's log);
- the **gateway** enrolls directly at lcm's keyless listener
  (`https://lcm:9947`), which presents lcm's own SVID (no DNS name, mesh root).
  It verifies that SVID with the mesh trust bundle: `enroll.ca_file:
  /certs/ca.pem` (written by `lcm-bootstrap` into the `certs` volume, which the
  base compose file mounts into the gateway) and the expected id
  `spiffe://<TRUST_DOMAIN>/svc/lcm` (`enroll.server_spiffe_id`, default).
  Portal 4.2.0 and later refuse `enroll.insecure` in production; 4.0.x/4.1.x
  do not know `ca_file` and refuse the config, so change both together.

### 4.11 ACME (Let's Encrypt) in lcm instead of Pebble

The overlay removes Pebble and lcm's `SSL_CERT_FILE=/pebble-ca/bundle.pem`
(lcm now uses the bundle with the OS roots). Create the issuer in the UI
(**Issuers -> New issuer**, type ACME):

- ACME directory URL: `https://acme-staging-v02.api.letsencrypt.org/directory`
  for testing, then `https://acme-v02.api.letsencrypt.org/directory`.
- DNS provider (lcm ≥ 4.3.0 offers only providers with an implementation):
  - **Cloudflare**: API token with **Zone → DNS → Edit** on the zone; set the
    Zone ID, or also grant **Zone → Zone → Read** so lcm can find the zone.
    lcm creates the `_acme-challenge` TXT record, waits up to 2 minutes until
    the zone's name servers serve it, and deletes it afterwards.
  - **Tangra DNS** (`freya-dns`): the platform dns module writes the record
    into PowerDNS - requires pdns-auth to be the publicly delegated
    authoritative server for the zone, i.e. port 53 public.
  - **Manual**: a no-op; the TXT record must be published out of band.

  Provider secrets are sealed and shown as `__set__`. lcm before 4.3.0 listed
  Cloudflare, Route 53, ... without an implementation (orders failed silently)
  and kept provider tokens readable in the issuer settings: after upgrading,
  **rotate any DNS provider token entered with an older lcm**. A failed order
  is logged (`docker compose logs lcm | grep "acme issuance failed"`) with the
  reason and audited.

This is independent of the edge certificate (section 4.5).

### 4.11a Security keys (WebAuthn)

auth ≥ 4.3.0 lets users register security keys (YubiKey and other
FIDO2/WebAuthn authenticators) as a second factor next to the authenticator
app (Account → Second factors). No configuration is needed: the relying party
is derived from `issuer` — the host name of `PUBLIC_HOST`
(`portal.infra.verax.net`) and the origin including `PUBLIC_PORT`
(`https://portal.infra.verax.net:8443`). Optional overrides live in the
`webauthn:` block of `prod/configs/auth.yaml` (`rp_id`, `origins`,
`display_name`, `user_verification: preferred|required`, `timeout_seconds`).

Keys are **bound to that host name**: opening the console by IP address or
another name refuses key registration and sign-in, and if `PUBLIC_HOST`
ever changes, every user must register their keys again (the authenticator
app and recovery codes keep working meanwhile). Administrators can view a
user's second factors and reset them (Users → user → Second factors).

### 4.12 Trust domain

Every workload identity is `spiffe://<TRUST_DOMAIN>/svc/<service>`, and lcm
keeps one mesh root per trust domain. The development stack uses `example.org`;
production uses a domain you control, e.g. `infra.example.com` (it is an
identifier only: nothing is resolved in DNS and no public certificate is
involved).

`TRUST_DOMAIN` in `.env` is a required `prod-init.sh` input (`example.org` is
refused). The script writes it into every `prod/configs/*.yaml`
(`trust_domain`, dns `acme.allowed_caller`), into `prod/policies/*.yaml` (the
service-to-service policies: every image ships a `deploy/policy.yaml` naming
`spiffe://example.org/...` callers, and the overlay mounts these copies over
it; `policies/` holds the copies from the current releases) and into `.env`, where the gateway
allow-list (`gateway-bootstrap`) and the `*-token` jobs of the base compose
file pick it up. A re-run refuses kept configs whose trust domain differs from
`TRUST_DOMAIN`. Choose it before the first start.

**Changing it on a running stack** (e.g. an install that started with
`example.org`). Users, data, secrets and the Vault state are unaffected; the
mesh gets a new root and every service enrolls again.
In the deployment directory:

```sh
NEW=infra.example.com           # the new trust domain
P=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$(docker compose ps -q timescaledb)")

# 1. stop the application services (databases, Valkey, OpenFGA, Vault keep running;
#    restarting Vault would seal it)
APPS="renewer lcm auth gateway notification warden deployer paperless inventory ipam asset ticket dns"
docker compose stop $APPS

# 2. configs and .env
sed -i -E -e "s#^trust_domain: .*#trust_domain: ${NEW}#" \
          -e "s#spiffe://example\.org/#spiffe://${NEW}/#g" prod/configs/*.yaml
grep -n 'example\.org' prod/configs/*.yaml | grep -v '@'   # expect no output
grep -q '^TRUST_DOMAIN=' .env && sed -i "s#^TRUST_DOMAIN=.*#TRUST_DOMAIN=${NEW}#" .env \
  || echo "TRUST_DOMAIN=${NEW}" >> .env
docker compose config | grep -c "spiffe://${NEW}/"          # allow-list + token jobs

# 2b. service-to-service policies for the new domain (keeps configs and
#     credentials; the overlay must mount prod/policies - current example does)
./scripts/prod-init.sh

# 3. drop the persisted SVIDs of the old trust domain (services enroll afresh)
for v in $(docker volume ls -q --filter "label=com.docker.compose.project=$P" | grep -- '-state$'); do
  docker run --rm -v "$v:/s" alpine rm -f /s/svid.json /s/svid.json.tmp
done

# 4. retire the old allow-list rows (gateway-bootstrap adds the new ones)
docker compose exec timescaledb psql -U postgres -d gateway -c \
  "UPDATE allow_list SET revoked_at = now() WHERE spiffe_id LIKE 'spiffe://example.org/%' AND revoked_at IS NULL;"

# 4b. free the issuer name "mesh" for the new domain (lcm up to 4.0.0 always
#     names the mesh issuer "mesh", and names are unique)
docker compose exec timescaledb psql -U postgres -d lcm -c \
  "UPDATE issuers SET name = 'mesh-example.org' WHERE lower(name) = 'mesh' AND trust_domain = 'example.org';"

# 5. start: lcm-bootstrap creates the new root and file SVIDs, the *-token jobs
#    mint tokens for the new ids, gateway-bootstrap seeds the allow-list
docker compose up -d
docker compose logs gateway auth lcm --since 5m | grep -i 'trust\|x509\|refused' | head
```

Replace `example.org` in steps 2, 4 and 4b when moving away from another trust
domain. The old root stays in the lcm database, unused. Step 3 is needed
because services up to lcm sdk 4.0.0 reuse a saved SVID without checking its
identity.

### 4.13 Checklist

- [ ] `prod-init.sh` run; `git diff --no-index configs prod/configs` reviewed
- [ ] `gen-internal-tls.sh` run; `prod/tls/ca-private` moved off the host
- [ ] `prod/edge/tls.crt` + `tls.key` present (public CA, `PUBLIC_HOST`)
- [ ] `http-redirect` answers `http://PUBLIC_HOST/` with a 301 to `PUBLIC_ORIGIN`; certbot renews via `--webroot -w prod/acme`
- [ ] `TRUST_DOMAIN` set to a domain you control (4.12)
- [ ] `docker-compose.override.yaml` = the production overlay; `.env` ports, `OPERATOR_EMAIL`, image pins
- [ ] SPF/DKIM/DMARC/PTR for the sending domain; relay accepts the host
- [ ] Vault unseal model chosen (4.7); key holders named
- [ ] `docker compose config --quiet` passes
- [ ] Backups scheduled and a restore tested (section 5)

---

## 5. Persistent data and backups

### Volumes that hold state

Named volumes are `<COMPOSE_PROJECT_NAME>_<name>`.

| Volume | Content | Loss means |
|---|---|---|
| `pgdata` (overlay) | TimescaleDB: all 13 databases (`auth gateway lcm warden notification deployer paperless inventory ipam asset ticket dns openfga`), incl. the sealed mesh root CA | **everything** |
| `vault-data` (overlay) | Vault storage (warden secrets) | all warden secrets |
| `rustfs-data` | documents, asset photos, ticket attachments | all files |
| `pdns-auth-data` | PowerDNS zone database (SQLite) | served zones |
| `ticket-secrets`, `dns-secrets` | relay token, PowerDNS API keys | regenerable (reconfigure MTA / restart dns stack) |
| `vault-creds` | warden AppRole credentials | regenerable with `vault-init` + admin token |
| `certs`, `tokens`, `*-state`, `gateway-state` | bootstrap SVIDs, join tokens, persisted workload SVIDs | regenerated on the next `up` (tokens are re-minted on every `up`) |
| `pdns-auth-conf`, `pdns-recursor-conf`, `pdns-recursor-api` | rendered PowerDNS files, forward zones | re-rendered / reconciled by dns |
| `edge-cert`, `pebble-certs`, `ldap-tls` | development only | nothing |
| **`prod/`** (host directory) | configs, credentials, **KEKs**, TLS | the database and Vault become unreadable without the KEKs/credentials |
| **Vault unseal keys** (offline) | - | Vault data unrecoverable |

**The development stack stores TimescaleDB in an anonymous volume** (the image
declares `VOLUME /var/lib/postgresql/data` and `docker-compose.yaml` mounts
nothing there): `docker compose down -v` or a recreated container can lose it,
and backups cannot find it by name. The overlay mounts the named volume
`pgdata`. Moving an existing installation onto it (stop the stack first):

```sh
docker compose stop
old=$(docker inspect "$(docker compose ps -aq timescaledb)" \
      -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}')
docker volume create "${COMPOSE_PROJECT_NAME}_pgdata"
docker run --rm -v "$old":/from:ro -v "${COMPOSE_PROJECT_NAME}_pgdata":/to alpine:3.20 \
  sh -c 'cp -a /from/. /to/'
```

Then start with the overlay. (Dev-mode Vault has no data to migrate - it was in
memory.)

### Backup

```sh
B=/backup/tangra/$(date +%F); mkdir -p "$B"; cd /opt/tangra

# 1. databases (custom format, per database) + roles
docker compose exec -T timescaledb pg_dumpall -U postgres --globals-only > "$B/globals.sql"
for db in auth gateway lcm warden notification deployer paperless inventory ipam asset ticket dns openfga; do
  docker compose exec -T timescaledb pg_dump -U postgres -Fc -d "$db" > "$B/$db.dump"
done

# 2. Vault (integrated storage snapshot; needs a token allowed to read sys/storage/raft/snapshot)
docker compose exec -T -e VAULT_TOKEN="$VAULT_BACKUP_TOKEN" vault \
  sh -c 'vault operator raft snapshot save /tmp/vault.snap && cat /tmp/vault.snap && rm /tmp/vault.snap' > "$B/vault.snap"

# 3. volumes with files (stop the writer for a consistent copy, or use an S3 mirror tool for RustFS)
for v in rustfs-data pdns-auth-data ticket-secrets dns-secrets; do
  docker run --rm -v "${COMPOSE_PROJECT_NAME}_$v":/v:ro -v "$B":/b alpine:3.20 tar czf "/b/$v.tgz" -C /v .
done

# 4. the prod/ tree (KEKs, credentials, configs) - encrypt it
tar czf - prod | gpg --symmetric --cipher-algo AES256 -o "$B/prod.tgz.gpg"
```

(With `storage "file"`: stop Vault and archive the `vault-data` volume instead of
the snapshot.) Keep backups off the host; keep the unseal keys and the internal
CA key separately from the backups.

### Restore (and test it regularly)

TimescaleDB uses hypertables in most service databases, so a restore brackets
`pg_restore` with `timescaledb_pre_restore()` / `timescaledb_post_restore()`
and needs the **same TimescaleDB extension version** (pin the image). On a fresh
`pgdata` volume, `init-db.sql` has already created the databases, roles and
extensions:

```sh
docker compose up -d timescaledb
for db in auth gateway lcm warden notification deployer paperless inventory ipam asset ticket dns openfga; do
  docker compose exec -T timescaledb psql -U postgres -d "$db" -c 'SELECT timescaledb_pre_restore();'
  docker compose exec -T timescaledb pg_restore -U postgres -d "$db" --clean --if-exists < "$B/$db.dump"
  docker compose exec -T timescaledb psql -U postgres -d "$db" -c 'SELECT timescaledb_post_restore();'
done
```

(`openfga` has no TimescaleDB extension; the pre/post calls fail harmlessly
there - or skip them.) Restore `prod/`, the volumes (`tar xzf` into empty
volumes), Vault (`vault operator raft snapshot restore -force`, then unseal
with the **original** unseal keys), then `docker compose up -d`. Verify the
exact restore sequence in a test environment and record it (verify: the
bracket calls and `--clean` behaviour with your extension version).

---

## 6. First start

```sh
cd /opt/tangra
docker compose config --quiet && echo OK        # overlay + .env valid
docker compose pull

# 1. Vault: start, initialise, unseal, create warden's AppRole (section 4.7)
docker compose up -d vault
docker compose exec vault vault operator init -key-shares=5 -key-threshold=3
docker compose exec vault vault operator unseal          # x3
VAULT_TOKEN=<root token> docker compose run --rm vault-init
docker compose exec -e VAULT_TOKEN=<root token> vault vault token revoke -self

# 2. everything else
docker compose up -d
```

`up` runs, in dependency order: infra -> `lcm-bootstrap` (mesh root, bootstrap
SVIDs) -> `gateway-bootstrap` (allow-list) -> `auth-bootstrap` (platform tenant,
roles, signing key, operator invitation) -> `vault-init` (no-op now) -> the
`*-token` jobs -> lcm, auth, gateway, then the modules (enroll, register).
Database migrations run inside each service at start (below).

### Operator invitation

`auth-bootstrap` prints the accept link and queues it as mail to
`OPERATOR_EMAIL` (valid 7 days; re-running reuses a pending invitation with a
fresh link, and does nothing once an operator exists):

```sh
docker compose logs auth-bootstrap | grep -oE 'https://[^" ]*invite/accept[^" ]*' | tail -1
# -> https://tangra.example.com/console/invite/accept?token=...
```

Open it, set a password and TOTP, then sign in at `https://<PUBLIC_HOST>`.

### Verify

```sh
docker compose ps                               # long-running services "healthy"
docker compose ps -a --status exited            # one-shot jobs: exit 0
for s in notification warden deployer paperless inventory ipam asset ticket dns; do
  printf '%-13s ' "$s"; docker compose logs "$s" 2>&1 | grep '"gateway lease"' | tail -1 | grep -o '"registered":[a-z]*'
done                                            # expect "registered":true
docker compose exec lcm wget -qO- http://127.0.0.1:9591/readyz   # "ready"
curl -sS -o /dev/null -w '%{http_code}\n' https://tangra.example.com/
```

Admin (health/metrics) listeners, loopback inside each container:
lcm 9591, auth 9190, gateway 9290, warden 9490, notification 9590, deployer
9690, paperless 9790, inventory 9810, ipam 9820, asset 9830, ticket 9840, dns
9850 - `/healthz`, `/readyz`, `/metrics`.

### Gateway allow-list

The allow-list (SPIFFE id -> route prefixes) is in the `gateway-bootstrap`
command of `docker-compose.yaml` and is re-applied on every `up`
(`bash scripts/apply-allow.sh` re-runs just that job). It is idempotent **per
SPIFFE id**; changing prefixes of an existing entry needs an `UPDATE` of the
`allow_list` table (see [ENROLLMENT.md](ENROLLMENT.md)).

### Break-glass: locked-out operator

`authsvc reset-user` clears the user's credentials, revokes their sessions and
prints a fresh invitation link that keeps their roles:

```sh
docker compose run --rm auth-bootstrap reset-user -config deploy/container.yaml -email ops@example.com
```

---

## 7. Operations

### Upgrades

```sh
# 1. back up (section 5) - migrations are forward-only
# 2. bump the version
sed -i 's/^TANGRA_VERSION=.*/TANGRA_VERSION=4.2.0/' .env   # and any *_IMAGE pins
docker compose pull
docker compose up -d
docker compose ps
```

Every service applies its database migrations on start (goose `Up`, embedded
SQL, under a Postgres advisory lock; `app.Options{Migrate: true}` in each
service's `cmd/`) using `db.migrate_dsn`. auth and the gateway accept
`-no-migrate`. There are no down-migrations.

Also re-read the release notes and diff the new `configs/` against
`prod/configs/` (`git diff <old-tag> <new-tag> -- configs/ docker-compose.yaml.example`):
new required keys must be added to `prod/configs` by hand
(`prod-init.sh` does not touch existing configs without `FORCE=1`). Refresh
`docker-compose.yaml` from the example after reviewing the diff.

#### Module roles (auth 4.4.0, portal 4.3.0, modules 4.2.0+)

Permissions become module-scoped (`warden:secrets:read`) and every module
brings ready-made roles ("Warden viewer", "Tickets agent", ...). Upgrade auth
first, then the gateway, then the modules; existing access keeps working
through the old unscoped permissions until the cut-over:

```sh
docker compose exec auth authsvc permissions verify -config deploy/container.yaml -snapshot /tmp/perms.json
docker compose exec auth authsvc permissions prune-legacy -config deploy/container.yaml -dry-run
# only when the dry-run reports no finding:
docker compose exec auth authsvc permissions prune-legacy -config deploy/container.yaml
docker compose exec auth authsvc permissions verify -config deploy/container.yaml -compare /tmp/perms.json
```

A dry-run finding names a role that would lose a permission it held through an
unscoped name in another module; grant it (or accept the loss) before pruning.
Custom roles created through the API must name permissions
`module:resource:action`. The auth log line `registration: built-in grant
skipped ... role=member reason=role_missing` for the platform tenant is
expected (that tenant has no `member` role).

### Rollback

Set the previous `TANGRA_VERSION`, restore the database backup taken before the
upgrade (a newer schema is not guaranteed to work with older binaries), then
`docker compose up -d`.

### Logs

```sh
docker compose logs -f --since 10m gateway auth
docker compose logs lcm | grep -i warn            # accepted insecure settings are logged as warnings at start
```

Services log JSON (`slog`). Rotation: daemon-wide (section 2).

### Monitoring

- Container health: every go-tangra service has a Docker healthcheck on
  `/readyz`; alert on `docker compose ps` / `docker events` unhealthy status.
- Metrics: each service exposes Prometheus metrics on its admin listener
  (`/metrics`, e.g. `freya_calls_total`), bound to 127.0.0.1 inside the
  container. The framework refuses a non-loopback admin listener without mTLS
  (`observe/admin.go`), so an external Prometheus cannot scrape it as shipped
  (verify an approach, e.g. a sidecar sharing the service's network namespace).
- The `metrics` profile's Prometheus only scrapes PowerDNS for the dns
  dashboard (`metrics.prometheus_url`); it has no volume (history is lost on
  recreate).

### Certificate rotation

| Certificate | Rotation |
|---|---|
| Edge / ticket inbound (`prod/edge`) | replace files; gateway reloads within a minute; `docker compose restart ticket` |
| Workload SVIDs (enrolled) | automatic: renewed over mTLS before expiry |
| Bootstrap SVIDs (`certs` volume, e.g. auth) | `renewer` re-issues every `RENEW_INTERVAL` seconds (default 21600) with lifetime `CERT_TTL` (default 12h); keep `RENEW_INTERVAL` well below `CERT_TTL` |
| Internal TLS (`prod/tls`, 825 days) | bring the CA key back, delete the service's directory, re-run `gen-internal-tls.sh`, restart that service |
| Mesh root CA | lcm trust-bundle rotation (go-tangra-lcm `docs/operations.md`) (verify the procedure before relying on it) |

A workload that was down longer than its SVID lifetime needs a new join token:
`docker compose up -d` re-runs the `*-token` jobs.

### Scaling

The compose file is single-host: one replica per service, fixed container names
for PowerDNS (`freya-pdns-auth`, `freya-pdns-recursor`), one TimescaleDB,
Valkey and Vault. Scale vertically. Running several replicas of a module is not
covered by this deployment (verify before trying: registration leases live in
Valkey and job workers use database leases, but it is untested here).

---

## 8. Security notes

- **Containers run as root.** `docker-compose.yaml` sets `user: "0:0"` on every
  go-tangra service (the shared token/state volumes are root-owned), although
  the images define a non-root user (`app`, uid 10001). Running as 10001 needs
  every mounted volume/file chowned to it (verify).
- **Docker socket.** Only `dns` uses it, to restart the two PowerDNS containers
  after a configuration save. It is root-equivalent on the host. The overlay
  removes the mount and `group_add`, and `prod-init.sh` sets
  `docker.enabled: false`: a save then renders the files and reports
  `restart_required`; apply it with `docker compose restart pdns-auth
  pdns-recursor`. If you need automatic restarts, put an API-filtering proxy in
  front of the socket that allows only `GET /_ping` and
  `POST /containers/{freya-pdns-auth,freya-pdns-recursor}/restart`, and point
  `docker.socket` at it (go-tangra-dns `deploy/README.md`). A generic
  `docker-socket-proxy` with `CONTAINERS=1 POST=1` allows far more than that.
- **ipam** keeps `cap_add: NET_RAW` (ICMP scans) and reaches BMC/IPMI/SNMP
  targets; restrict the host's egress if needed.
- **Network exposure**: only the ports in section 2. Admin listeners are
  loopback-only inside containers. Valkey, TimescaleDB, OpenFGA, Vault, RustFS
  are unpublished and TLS-only.
- **Secrets at rest on the host**: `prod/` (0600), `.env` (0600, written by
  `prod-init.sh`). The relay passwords (`prod/secrets/`) and the Valkey/database
  passwords are plain text on the host - protect `prod/` and its backups.
- **Superuser for migrations**: `migrate_dsn` uses `postgres`; the runtime
  `dsn` uses the per-service `<svc>_app` role (`NOBYPASSRLS`, row-level
  security).
- **Accepted warnings**: each service logs its accepted deviations at start
  (e.g. raised `limits.max_request_bytes`, `file:` secret references in
  ticket/dns). Review them once.

---

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| A service exits with `config: ...` | `Validate()` refused a setting; the message names the key (section 4.1). |
| `gateway-bootstrap`: `config: open deploy/container.yaml: permission denied` | `prod/configs/*.yaml` are `0600 root`; a job that runs as the image's non-root user cannot read them. The overlay runs `gateway-bootstrap` as `0:0` (pull the latest overlay and copy it to `docker-compose.override.yaml` again). |
| Invitations/share mails not arriving; notification log entry `failed` with `x509: cannot validate certificate for <ip> because it doesn't contain any IP SANs` (or `certificate is valid for *.example.net, not ...`) | `platform_email.host` must be the relay's certificate name, not its IP: check with `openssl s_client -starttls smtp -connect <ip>:587 </dev/null \| openssl x509 -noout -subject -ext subjectAltName`, set `host` to a matching name, add `extra_hosts: ["<name>:<ip>"]` to notification if the name does not resolve, `docker compose restart notification`. Queued invitations are retried automatically. |
| After a trust domain change: gateway `enroll: http 403 {"reason":"forbidden"}` with a fresh token, or services refusing each other (`PermissionDenied`) | The images' built-in `deploy/policy.yaml` only admit `spiffe://example.org/...` callers (auth refuses lcm's token check, so lcm answers 403). Run `./scripts/prod-init.sh` (writes `prod/policies/`), make sure `docker-compose.override.yaml` mounts `./prod/policies/<svc>.yaml:/app/deploy/policy.yaml:ro` for every service (current overlay example), then `docker compose up -d`. |
| Gateway exits: `config: enroll.insecure is refused in production; set enroll.ca_file ...` | Portal 4.2.0+ verifies lcm on first enrollment. In `prod/configs/gateway.yaml` replace `  insecure: true` under `enroll:` with `  ca_file: /certs/ca.pem`, and make sure the gateway mounts the `certs` volume (`certs:/certs:ro`, in the current base `docker-compose.yaml.example`; refresh your `docker-compose.yaml`). The reverse error, `field ca_file not found`, means an older portal image: use `GATEWAY_IMAGE=...go-tangra-portal:4.2.0`. |
| Inventory restarts: `registry valkey: ... connection reset by peer`, Valkey logs `SSL routines::wrong version number` | Inventory 4.0.0 connected its registry to Valkey without TLS. Use inventory 4.1.0 or later (`INVENTORY_IMAGE` / `TANGRA_VERSION`). 4.1.0 also serves the agent ingest edge over TLS and refuses to start without its certificate: in an existing `prod/configs/inventory.yaml` set `ingest: { addr: 0.0.0.0:9977, insecure: false, tls_cert_file: /edge/tls.crt, tls_key_file: /edge/tls.key }` and mount `./prod/edge:/edge:ro` into inventory (current overlay does). |
| Gateway: `edge: cert: open /edge/tls.crt: no such file or directory` although `prod/edge/tls.crt` exists | `prod/edge/` holds **symlinks** (e.g. into `/etc/letsencrypt/archive/`). Only `prod/edge` is mounted, so the link targets do not exist inside the container. Copy the files instead: `install -m 0644 fullchain.pem prod/edge/tls.crt` and `install -m 0600 privkey.pem prod/edge/tls.key` (the certbot deploy hook in section 4.5 does exactly this on every renewal). |
| `service "<name>" has neither an image nor a build context specified` | Compose is reading the production overlay on its own (for example it was copied to `docker-compose.yaml`). The overlay only adds to the base stack: `docker-compose.yaml` must be a copy of `docker-compose.yaml.example` and `docker-compose.override.yaml` a copy of `docker-compose.production.yaml.example`. |
| `config: kek: open deploy/dev-kek.b64: no such file or directory` in a `*-token` job | The job runs without the auth KEK. Both compose files mount it (`./keys/auth.kek` in the base, `./prod/keys/auth.kek` in the overlay); check that `docker-compose.override.yaml` is the production overlay and that `prod-init.sh` has created `prod/keys/auth.kek`. |
| Browser/API gets **503 `temporarily_unavailable`** for one module | The gateway cannot reach the endpoint the module advertised. A container on several networks advertises its first IPv4 address by kernel interface order, which may be on a network the gateway cannot reach. Set `FREYA_ADVERTISE_HOST=<compose service name>` on that service (auth already has it because of the `ldap` network). |
| Module log `registered":false`, `identity_not_allowed` / `prefix_not_granted` | Its SPIFFE id / prefix is not in the allow-list: `bash scripts/apply-allow.sh` (section 6). |
| Module never logs `identity ready`; enroll errors with `x509` | First enroll with `insecure: false` could not verify the edge: `prod/edge/tls.crt` must be a publicly trusted full chain for `PUBLIC_HOST`, and the gateway must carry the `PUBLIC_HOST` alias (overlay). |
| `x509: certificate signed by unknown authority` towards OpenFGA / RustFS | `SSL_CERT_FILE=/tls/bundle.pem` missing or the bundle was built before the CA (re-run `gen-internal-tls.sh`). |
| TimescaleDB: `private key file ... has group or world access` / `Permission denied` | `prod/tls/timescaledb/server.key` must be 0600 and owned by uid 70 (the script does this; copying the tree can lose ownership). Same pattern for Valkey (999), Vault (100), OpenFGA (65532), RustFS (10001). |
| warden unhealthy, ipam/dns never start | Vault is sealed or `vault-init` failed: `docker compose exec vault vault status`; unseal (4.7). |
| `vault-init` exits 1: `no warden AppRole credentials ... and no VAULT_TOKEN` | First start: run it once with an admin token (4.7). |
| Password changes in `.env` have no effect on the database | `POSTGRES_PASSWORD` and `init-db.sql` apply only when `pgdata` is first initialised. Change them with `ALTER ROLE ... PASSWORD` and update `prod/configs` + `.env`. |
| Restarted module cannot enroll (token already used / expired) | `docker compose up -d` re-mints join tokens; a persisted, still-valid SVID in `/state` is reused. |
| ipam BMC/SNMP secrets, ticket or dns cannot reach warden (`connection refused` to warden:9743) | Development configs name port 9743; warden listens on 9843. `prod-init.sh` fixes `discovery.static.warden`; check hand-made configs. |
| Disk full (`ENOSPC`) | Log rotation (section 2); `docker system df`; `docker image prune` after upgrades; RustFS and database growth; inventory keeps snapshots `retention.days` (90). |

---

## 10. Known limitations

- **ticket and dns cannot run with `env: production`.** Production mode rejects
  `file:` secret references (ticket: relay token, SMTP password; dns: PowerDNS
  API keys), and the alternative, `warden:<id>` references, needs a platform
  token in `secrets.token_file` that warden authorises per *user*; modules have
  no long-lived service-principal token, and auth access tokens live at most
  15 minutes (`token.access_lifetime`). Both therefore run with `env: dev` and
  hardened settings (TLS DSN, Valkey TLS, S3 TLS, SMTP TLS, inbound TLS); the
  secret files live in Docker volumes / `prod/secrets` (go-tangra-ticket T069,
  go-tangra-dns `deploy/README.md` "the warden gap").
- **Inventory agent releases are not published for v4 yet**, so there are no
  agents to enroll today (the ingest edge serves TLS since inventory 4.1.0).
- **`docker-compose.yaml.example`: the `*-token` jobs do not mount the auth
  KEK.** With the 4.0.0 images (which contain no keys) they fail config
  validation on a fresh start. The production overlay mounts it; the
  development stack needs the same fix (not changed by this guide).
- **Development configs point ipam/ticket/dns at `warden:9743`** while warden
  listens on 9843; fixed in `prod/configs` by `prod-init.sh`.
- **ACME DNS-01**: only `freya-dns` and `manual` work in lcm 4.0.0 (4.11).
- **No KEK rotation command** (4.3). **No external metrics scraping** of the
  services' admin listeners without extra work (section 7).
- **Credentials inside `configs/`** are development values, listed in
  [README.md](README.md#credentials-inside-configs); `prod-init.sh` replaces
  all of them in `prod/configs`. Never deploy `configs/` or `keys/` as they are.
- **Single host**, one replica per service; containers run as root (section 8).
