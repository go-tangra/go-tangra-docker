# Migration: registration-rework Phase 1

This guide walks through migrating an existing Tangra deployment from the
legacy `lcm-init`-based certificate flow to the new self-signed CSR flow
introduced in `go-tangra-common v1.17.1` and module `v3.0.0` releases.

If you are spinning up a fresh stack, skip to [Fresh install](#fresh-install).
If you are upgrading an existing one, read [Upgrade path](#upgrade-path) first.

---

## What changed

### Before

Modules trusted certificates that **LCM minted server-side** during a
one-shot `lcm-init` container, baked into a shared `lcm-data:/app/lcm-certs:ro`
volume that every module mounted read-only. Each module pointed at
`/app/lcm-certs/{module}/{module}.{crt,key}` via per-module env vars
(`{MODULE}_CA_CERT_PATH`, etc).

Pain points:
- Private keys lived on a shared filesystem mount controlled by LCM.
- Adding a new module meant editing `lcm.yaml`'s `bootstrap_modules:` list,
  redeploying lcm-init, then bringing up the module.
- Cert rotation needed an `lcm-init` rerun across the whole stack.
- Admin's gateway needed a per-module `_CERT_PATH` env triplet for every
  registered module.

### After

Each module **generates its own RSA keypair locally**, builds a PKCS#10 CSR,
and submits it to LCM's new `LcmBootstrapService.SignModuleCertificate` RPC
on `lcm-service:9101` (a dedicated non-mTLS port). The private key never
crosses the wire. The signed cert + CA bundle are persisted into a
**per-service private named volume** at `${CERTS_DIR}/{ca,server,client}/`.

Trust is anchored by **a pre-shared SHA-256 fingerprint of LCM's root CA**
(`LCM_CA_FINGERPRINT`). Every module verifies LCM's TLS leaf against the pin
before exchanging the CSR — no TOFU, no first-use trust window.

Implementation lives in `go-tangra-common/cert/`:
- `ensure.go` — `Ensure(EnsureConfig)` top-level entry point
- `csr.go` — RSA-2048 keypair + PKCS#10 CSR generation
- `pinned_dialer.go` — pinned-fingerprint TLS verifier
- `validity.go` — local-cert validation (chain + expiry + renewal window)

Each module's `internal/cert/cert_manager.go` is now a thin wrapper that
calls `commonCert.Ensure(...)` at boot.

### Side effects

- **`lcm-init` is deleted entirely.** No more shared `lcm-data:/app/lcm-certs:ro`
  mount on modules. Each module owns a private `*-certs` named volume.
- **Admin's `:7787` gRPC port is now plaintext** for module registration. The
  earlier mTLS layer broke registration across the board; module auth happens
  via `AuthToken` in the request body. Admin's outbound mTLS to modules
  (through the transcoder) is unchanged.
- **The transcoder's convention path moved** from `/app/certs/admin/admin.crt`
  to `/app/certs/client/client.crt` (the cert.Ensure layout). The old
  `{MODULE}_CA_CERT_PATH` / `{MODULE}_CLIENT_CERT_PATH` env vars on
  admin-service are no longer needed — they still work as a fallback.
- **`{MODULE}_SERVER_NAME` env override** still applies on the convention
  path so lcm's `CN=lcm-server` (not `lcm-service`) keeps validating.
- **CertificateKind enum values renamed** to satisfy buf lint:
  `CERT_KIND_*` → `CERTIFICATE_KIND_*`. Wire-compatible — tag numbers
  unchanged.
- **`google.protobuf.Empty` → `UnregisterTaskTypesResponse`** in scheduler's
  TaskTypeRegistrationService. If you had a custom adapter, swap the return
  type.

---

## Required environment variables

The new flow needs three secrets/values wired into every migrated module
(via the docker-compose `.env` or your orchestrator's secret store):

| Variable | Purpose | Example |
|---|---|---|
| `LCM_BOOTSTRAP_ENDPOINT` | Where modules dial LCM to sign certs | `lcm-service:9101` |
| `MODULE_BOOTSTRAP_SECRET` | Shared secret in every SignModuleCertificate body. LCM verifies against `module_registration_secret` in `configs/lcm/lcm.yaml`. | (any string ≥ 16 chars) |
| `LCM_CA_FINGERPRINT` | SHA-256 hex of LCM's root CA DER bytes. **Mandatory pin — no TOFU.** A missing or wrong pin is a fatal error at boot. | 64 hex chars |
| `CERTS_DIR` | Where `cert.Ensure` writes the issued files | `/app/certs` |
| `REGISTRATION_INSECURE=1` | Tells the registration client to skip mTLS when dialing admin's plaintext :7787 | `1` |
| `GRPC_ADVERTISE_ADDR` | Routable address admin's gateway uses to dial back. Without this the module registers at its bind addr (`0.0.0.0:port`) which from inside admin's container points at admin's loopback → 504. | `<service>:<port>` |
| `HTTP_ADVERTISE_ADDR` + `FRONTEND_ENTRY_URL` | Used by admin's `/modules/<id>/*` proxy to fetch the federated frontend bundle. Without these the SPA logs `Component view not found` for every route the module registers. | `<service>:<http-port>` and `/modules/<id>/remoteEntry.js` |

The compose file in this repo wires all of these from `.env`. Copy
`.env.example` → `.env` and edit.

---

## Prerequisites

Use **Docker Compose v2** — the Go-based plugin invoked as `docker compose`
(no hyphen). The legacy Python `docker-compose` (v1, last released
2021-05) crashes on container recreation against any Docker Engine ≥ 25:

```
KeyError: 'ContainerConfig'
  File ".../compose/service.py", line 1579, in get_container_data_volumes
    container.image_config['ContainerConfig'].get('Volumes') or {}
```

The image-inspect API stopped populating `ContainerConfig` and v1 was
never updated. Install the plugin:

```bash
# Debian/Ubuntu
apt-get install -y docker-compose-plugin

# RHEL/Rocky
dnf install -y docker-compose-plugin

# Verify
docker compose version    # → Docker Compose version v2.x
```

All commands in this document use `docker compose` (v2), not
`docker-compose` (v1).

## Compose file layout

There are two compose files — copy each `.example` to the unsuffixed name on
first install (both are gitignored, edits stay local):

| File | Purpose |
|---|---|
| `docker-compose.yaml.example` | **Production base.** `image:` only — no `build:`. Pulls every module image from `${IMAGE_REGISTRY}/go-tangra-<module>:${IMAGE_TAG}` (defaults to `ghcr.io/go-tangra` and `3.0.0` from `.env`). |
| `docker-compose.dev.yaml.example` | **Dev overlay.** Adds `build:` directives so contributors can build module images locally from the sibling `go-tangra-*` repos. Layered on top of the base file. |

For local development:

```bash
docker compose -f docker-compose.yaml -f docker-compose.dev.yaml build
docker compose -f docker-compose.yaml -f docker-compose.dev.yaml up -d
```

Or set `COMPOSE_FILE=docker-compose.yaml:docker-compose.dev.yaml` in your
`.env` so every compose invocation picks up both.

For production deployments, **only the base file is needed** — no sibling
repos required, just `docker login ghcr.io && docker compose pull && docker
compose up -d`.

## Fresh install

```bash
cp docker-compose.yaml.example docker-compose.yaml
cp .env.example .env

# Edit .env to set real secrets:
#   POSTGRES_PASSWORD       (used by every module's DSN)
#   MODULE_BOOTSTRAP_SECRET (must match configs/lcm/lcm.yaml)
#   SHARING_ENCRYPTION_KEY  (64-char hex)
#   SMS_GW_JWT_SECRET       (≥ 32 bytes)
$EDITOR .env

# Bring lcm-service up first; wait for it to generate its CA; write the
# fingerprint into .env (this is what LCM_CA_FINGERPRINT pins against).
make lcm-bootstrap

# Now bring up the rest of the stack.
make up
```

The first time each module boots, `cert.Ensure` will dial LCM:9101, mint the
server + client certs, and write them to the module's private `*-certs`
volume. Subsequent boots find valid certs on disk and skip the network call.

---

## Upgrade path

Existing deployments can migrate in stages. The legacy `BootstrapCertificates`
RPC still exists on LCM (deprecated) so a partial cutover is safe.

### 1. Update LCM

```bash
docker compose pull lcm-service
docker compose up -d lcm-service
```

LCM v3.0.0 exposes the new `:9101` bootstrap port alongside the legacy mTLS
`:9100`. Both work concurrently.

### 2. Generate the CA fingerprint

```bash
make lcm-fingerprint WRITE=1
```

This script reads `lcm-data:/app/data/ca/ca.crt`, computes the SHA-256 of its
DER bytes, and writes it to `.env` as `LCM_CA_FINGERPRINT=`.

### 3. Update one module at a time

Each module's `v3.0.0` release pulls in `cert.Ensure` and reads the new env
vars. Pull the image, set the env vars, replace its compose entry's volume
mount:

```yaml
# Before
warden-service:
  environment:
    - WARDEN_CA_CERT_PATH=/app/lcm-certs/ca/ca.crt
    - WARDEN_SERVER_CERT_PATH=/app/lcm-certs/warden/warden.crt
    - WARDEN_SERVER_KEY_PATH=/app/lcm-certs/warden/warden.key
  volumes:
    - lcm-certs:/app/lcm-certs:ro
  depends_on:
    lcm-init:
      condition: service_completed_successfully

# After
warden-service:
  environment:
    - CERTS_DIR
    - LCM_BOOTSTRAP_ENDPOINT
    - MODULE_BOOTSTRAP_SECRET
    - LCM_CA_FINGERPRINT
    - REGISTRATION_INSECURE=1
    - GRPC_ADVERTISE_ADDR=warden-service:9300
    - HTTP_ADVERTISE_ADDR=warden-service:9301
    - FRONTEND_ENTRY_URL=/modules/warden/remoteEntry.js
  volumes:
    - warden-certs:/app/certs    # private named volume
  depends_on:
    lcm-service:
      condition: service_started
    admin-service:
      condition: service_healthy
```

Add the new named volume to the top-level `volumes:` block:

```yaml
volumes:
  warden-certs:
```

Bring up the module:

```bash
docker compose up -d warden-service
docker compose logs --tail 30 warden-service | grep cert/ensure
```

You should see something like:

```
INFO module=cert/ensure msg=re-issuing certs for warden: missing /app/certs/ca/ca.crt
INFO module=cert/ensure msg=certs provisioned for warden in /app/certs
INFO module=cert/ensure msg=Server TLS config created with mTLS enabled
```

### 4. Once every module is migrated, remove `lcm-init`

```yaml
# Delete these blocks from compose:
lcm-init:
  ...

# Delete this volume:
volumes:
  lcm-certs:
```

And from `configs/lcm/lcm.yaml` set `bootstrap_modules: []` — LCM no longer
needs to mint certs on startup.

### 5. Update admin-service

Admin's `v3.0.x` calls `cert.Ensure` itself (it dials its own modules over
mTLS through the transcoder). Apply the same env vars + private named
volume change as above. The per-module `_CA_CERT_PATH` / `_CLIENT_CERT_PATH`
env vars in admin's compose entry can be deleted — the transcoder's
convention path now finds `/app/certs/client/client.crt` automatically.

---

## Verifying the migration

For each migrated module:

```bash
# 1. cert.Ensure ran and persisted certs
docker compose exec <module> ls -la /app/certs/{ca,server,client}/

# 2. The module registered with admin under its routable address
curl -s http://localhost:8080/admin/admin/v1/registration/modules?status=MODULE_STATUS_ACTIVE \
  | jq '.modules[] | {id: .moduleId, grpc: .grpcEndpoint, http: .httpEndpoint, fe: .frontendEntryUrl}'

# 3. Admin can dial it over mTLS through the transcoder
docker compose logs admin-service | grep "Loaded TLS credentials for module <module>"
# Expected: `... CA=/app/certs/ca/ca.crt, Cert=/app/certs/client/client.crt, ServerName=<module>-service`

# 4. Browse to the module's UI through the gateway
xdg-open "http://localhost:8080/#/<module>"
```

If any step fails, check:
- `LCM_CA_FINGERPRINT` in `.env` matches the actual LCM CA. Re-run
  `make lcm-fingerprint`.
- The module's private cert volume isn't being shared with another module.
- The module isn't trying to reuse a stale cert from a previous failed run —
  delete the volume and let `cert.Ensure` re-issue.

---

## Rollback

If a module's v3.0.x release misbehaves, you can roll it back to its previous
v2.x image without affecting the rest of the stack — the legacy
`BootstrapCertificates` flow on LCM still works. You'll need to:

1. Restore the module's old compose entry (volume mount + env vars).
2. Re-add it to LCM's `bootstrap_modules:` list in `configs/lcm/lcm.yaml`.
3. `docker compose up -d lcm-init <module>`.

This is intentional — Phase 1 of the rework is additive on the LCM side so
mixed-version deployments can coexist while you migrate module by module.

---

## Standalone (systemd) modules

Some modules — currently `asterisk` and `backup` — are deployed in
production as standalone systemd services on bare-metal hosts rather than in
docker. The unit files in each module's `deploy/<module>.service` ship the
cert.Ensure-flavoured environment block. To migrate an existing standalone
deployment from the legacy lcm-init flow:

### 1. Update the binary

```bash
# On the bare-metal host:
systemctl stop tangra-asterisk        # or tangra-backup
curl -SL https://github.com/go-tangra/go-tangra-asterisk/releases/download/v3.0.0/tangra-asterisk-linux-amd64 \
  -o /usr/local/bin/tangra-asterisk
chmod +x /usr/local/bin/tangra-asterisk
```

### 2. Update the unit file

The shipped unit (`deploy/tangra-asterisk.service` / `tangra-backup.service`)
adds the new env vars and removes the legacy ones. Copy it over and reload:

```bash
cp deploy/tangra-asterisk.service /etc/systemd/system/
systemctl daemon-reload
```

Key changes vs the legacy unit:

| Old | New | Notes |
|---|---|---|
| `MODULE_REGISTRATION_SECRET` | `MODULE_BOOTSTRAP_SECRET` | renamed, same purpose |
| `<MODULE>_CA_CERT_PATH` etc. (per-module triplet) | `CERTS_DIR=/var/lib/tangra-<module>/certs` | cert.Ensure writes the whole layout under one root |
| (none) | `LCM_BOOTSTRAP_ENDPOINT=lcm.example.local:9101` | new bootstrap port |
| (none) | `LCM_CA_FINGERPRINT=<64-hex>` | mandatory CA pin |
| (none) | `REGISTRATION_INSECURE=1` | admin's :7787 is plaintext now |
| (none) | `HTTP_ADVERTISE_ADDR`, `FRONTEND_ENTRY_URL` | so admin's gateway can proxy `/modules/<id>/*` |

### 3. Edit `/etc/tangra-<module>/env` with real values

```bash
cat > /etc/tangra-asterisk/env <<EOF
ADMIN_GRPC_ENDPOINT=admin.example.local:7787
LCM_BOOTSTRAP_ENDPOINT=lcm.example.local:9101
MODULE_BOOTSTRAP_SECRET=<copy from lcm.yaml's module_registration_secret>
LCM_CA_FINGERPRINT=<64 hex chars — get from \`make lcm-fingerprint\` on the lcm host>
GRPC_ADVERTISE_ADDR=$(hostname -f):9800
HTTP_ADVERTISE_ADDR=$(hostname -f):9801
ASTERISK_CDR_DSN=root:<password>@tcp(127.0.0.1:3306)/asteriskcdrdb?parseTime=true&loc=UTC
ASTERISK_CONFIG_DSN=root:<password>@tcp(127.0.0.1:3306)/asterisk?parseTime=true&loc=UTC
EOF
chmod 600 /etc/tangra-asterisk/env
```

### 4. Pre-create the writable cert dir

```bash
mkdir -p /var/lib/tangra-asterisk/certs
chown <service-user>:<service-user> /var/lib/tangra-asterisk/certs
```

(`<service-user>` defaults to root if `User=` isn't set in the unit file.)

### 5. Start

```bash
systemctl start tangra-asterisk
journalctl -u tangra-asterisk -f | grep cert/ensure
# Expected:
#   cert/ensure msg=re-issuing certs for asterisk: missing /var/lib/tangra-asterisk/certs/ca/ca.crt
#   cert/ensure msg=certs provisioned for asterisk in /var/lib/tangra-asterisk/certs
#   cert/ensure msg=Server TLS config created with mTLS enabled
```

### 6. (Cleanup) Remove the legacy lcm-init artifacts

The old unit may have referenced `/etc/tangra-asterisk/certs/{ca.crt,server.crt,server.key}`
seeded out-of-band by an `scp` from the LCM host. Once cert.Ensure is
running, those files are stale — `rm` them or leave them, they're not
read.

## Restoring the frontend cert from lcm-data

The legacy compose mounted the whole `lcm-data` named volume read-only into
the frontend container so nginx could serve LCM's ACME-issued cert from
`/app/certs/frontend/server.{crt,key}`. The new layout uses a **plain host
bind mount** at `./certs/frontend/` instead — easier to inspect, easier to
rotate, no docker-volume tooling needed.

One-shot extraction from the existing volume:

```bash
cd /srv/portal       # or wherever this repo lives on the server

# 1) Find the volume that actually contains /frontend/server.crt — there may
#    be multiple lcm-data volumes from prior compose project names. List all
#    candidates, then probe each.
docker volume ls --format '{{.Name}}' | grep 'lcm-data$'
for v in $(docker volume ls --format '{{.Name}}' | grep 'lcm-data$'); do
  echo "--- $v ---"
  docker run --rm -v "$v:/data:ro" alpine:3.20 ls /data/frontend/ 2>&1 | head -3
done

# 2) Set VOL explicitly to the one that has server.crt + server.key
VOL=portal_lcm-data    # ← change this if the listing above shows it elsewhere

# 3) Copy the cert files into ./certs/frontend/
mkdir -p ./certs/frontend
docker run --rm \
  -v "${VOL}:/data:ro" \
  -v "$(pwd)/certs/frontend:/out" \
  alpine:3.20 sh -c '
    cp /data/frontend/server.crt /out/
    cp /data/frontend/server.key /out/
    [ -f /data/frontend/ca.crt ] && cp /data/frontend/ca.crt /out/ || true
'

# Lock down perms
chmod 644 ./certs/frontend/server.crt ./certs/frontend/ca.crt 2>/dev/null
chmod 600 ./certs/frontend/server.key

# Recreate the frontend with the new bind mount
docker compose up -d --force-recreate frontend
docker compose logs frontend | grep -E 'SSL|HTTPS'
# Expected: "SSL certificates found, enabling HTTPS"
```

The `certs/` directory is gitignored. To rotate the cert later, drop new
`server.crt` / `server.key` into `./certs/frontend/` on the host and
`docker compose restart frontend` — no volume editing.

## Module versions

The Phase 1 cutover landed in these tagged releases:

| Component | Tag |
|---|---|
| `go-tangra-common` | `v1.17.1` |
| Each module (`go-tangra-{warden,ipam,paperless,deployer,asterisk,hr,notification,sharing,signing,asset,backup,executor,sms-gw,lcm,scheduler}`) | `v3.0.0` |
| `go-tangra-portal` (admin-service) | `v3.0.0` |

All module `go.mod` files now pin `github.com/go-tangra/go-tangra-common
v1.17.1` directly — the temporary `replace ../go-tangra-common` workaround
that let us iterate on common during the rework is gone in v3.0.0.
