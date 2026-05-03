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
