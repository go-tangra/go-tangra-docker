# Service identity & enrollment

How every service gets its SPIFFE SVID, why the design is secure across hosts,
and how to enroll a new service.

## The model (SPIFFE/SPIRE-style)

There is **one trust root** — the mesh CA, a P-256 root generated and sealed in
lcm's database. lcm self-signs its own identity from it; everything else's SVID
chains to it. Nothing secret ever crosses the network or sits on a shared
volume: a workload **generates its own key locally**, sends only a **CSR**, and
receives a signed **certificate** (public). The private key never leaves it.

Services fall into three tiers:

| Tier | Service(s) | How it gets its SVID |
|------|-----------|----------------------|
| **CA** | `lcm` | **self-issues** from the DB-sealed mesh root at startup (no cert file) |
| **Control plane** | `auth` | **bootstrap SVID** minted under the mesh root by `lcmsvc bootstrap`, read from `/certs` (rotated by the `renewer`). It *cannot* enroll — lcm verifies every join token by calling auth, so auth can't depend on itself. This is the trust anchor. |
| **Workloads** | `gateway`, `notification`, `warden`, … | **enroll over the network** with a single-use join token |

`gateway` is a workload but a special case: it cannot enroll *through itself*
(it is the enrollment proxy), so it enrolls **directly** against lcm's
server-auth-only enroll listener (`enroll_listener: 0.0.0.0:9947`). Other
workloads enroll via the gateway edge (`https://gateway:8443/api/lcm/v1/enroll`).

## The enrollment flow

```
workload (cold start, no SVID):
  1. generate an ECDSA P-256 key locally               (private key stays here)
  2. read its single-use join token (from /tokens)
  3. POST { spiffe_id, csr_pem, enrollment_token } to the public enroll route
       - via the gateway edge (workloads), or direct to lcm:9947 (gateway)
  4. lcm verifies the token with auth (single-use jti burn), issues the SVID
  5. load the SVID in memory; persist it to /state (so a restart reuses it)

thereafter (has an SVID):
  - renew before expiry over a direct mTLS gRPC channel to lcm:9945
    (own SVID authenticates it; no token). lcm's server cert is verified
    against the mesh bundle (SPIFFE-aware).
```

Only two things ever cross hosts, and both are safe: the **public trust bundle**
(no secret) and a **short-lived, single-use join token** (ephemeral). The join
token is an EdDSA JWT minted and verified by **auth**, single-use via a burned
`jti`. `lcmidentity.NetProvider` (`sdk/pkg/lcmidentity/net.go` in go-tangra-lcm, module
`github.com/go-tangra/go-tangra-lcm/sdk/v4`)
implements the client.

## Enroll a NEW service — recipe

Do the same as `notification`:

1. **Depend on lcm's client sdk** — in the service repository:
   ```
   go get github.com/go-tangra/go-tangra-lcm/sdk/v4@v4.0.0
   ```
   then `go mod tidy` (import `github.com/go-tangra/go-tangra-lcm/sdk/v4/pkg/lcmidentity`).

2. **Config** — add an `Enroll` struct to the service config and, in the stack
   config yaml, set identity to injected and add the enroll block:
   ```yaml
   identity: { provider: provided }
   enroll:
     enabled: true
     enroll_url: https://gateway:8443/api/lcm/v1/enroll   # or https://lcm:9947/... for gateway-like
     lcm_grpc: lcm:9945
     tenant_id: "00000000-0000-0000-0000-000000000001"    # the mesh tenant (chains to the mesh root)
     token_file: /tokens/<svc>.token
     state_file: /state/svid.json
     insecure: true                                       # dev self-signed edge only (see Production)
   ```

3. **app.Build** — before `freya.New`, when `cfg.Enroll.Enabled`, build the
   provider and inject it (see `internal/app/app.go` in go-tangra-notification):
   ```go
   prov, _ := lcmidentity.NewNet(ctx, lcmidentity.NetConfig{
     EnrollURL: cfg.Enroll.EnrollURL, LCMGRPCTarget: cfg.Enroll.LCMGRPCTarget,
     TenantID: cfg.Enroll.TenantID, TrustDomain: cfg.Config.TrustDomain,
     ServiceName: cfg.Config.ServiceName,
     EnrollmentToken: strings.TrimSpace(string(tokenBytes)),
     Insecure: cfg.Enroll.Insecure, StateFile: cfg.Enroll.StateFile,
   })
   fopts = append(fopts, freya.WithIdentityProvider(prov))
   ```

4. **Compose** — add a token-mint init job and the service (drop the `/certs`
   mount, add `tokens:ro` and a `<svc>-state` volume):
   ```yaml
   <svc>-token:
     image: ghcr.io/go-tangra/go-tangra-auth:${TANGRA_VERSION:-4.0.0}
     command: ["mint-enrollment-token","-config","deploy/container.yaml",
       "-spiffe","spiffe://example.org/svc/<svc>","-ttl","30m","-out","/tokens/<svc>.token"]
     volumes: ["tokens:/tokens","certs:/certs:ro","./configs/auth.yaml:/app/deploy/container.yaml:ro"]
     depends_on: { auth-bootstrap: { condition: service_completed_successfully }, ... }
   <svc>:
     volumes: ["tokens:/tokens:ro","<svc>-state:/state","./configs/<svc>.yaml:/app/deploy/container.yaml:ro", ...]
     depends_on: { gateway: {condition: service_healthy}, lcm: {condition: service_healthy},
                   lcm-bootstrap: {condition: service_completed_successfully},
                   <svc>-token: {condition: service_completed_successfully} }
   # volumes: add  <svc>-state:
   ```

5. **Gateway allow-list** — grant the service's route prefixes so it may
   register. Add it to the `gateway-bootstrap` command in
   `docker-compose.yaml` (`scripts/apply-allow.sh` re-runs that job):
   ```
   -allow 'spiffe://example.org/svc/<svc>=/api/<svc>[,/extra/prefix];<svc>'
   ```
   Note the allow-list is idempotent **per SPIFFE id**; to change prefixes on an
   existing row, update it directly:
   ```sh
   docker exec freya-stack-timescaledb-1 psql -U postgres -d gateway \
     -c "UPDATE allow_list SET prefixes = ARRAY['/api/<svc>'] WHERE spiffe_id='spiffe://example.org/svc/<svc>' AND revoked_at IS NULL;"
   ```
   A module must NOT claim the shared `/ui` prefix or a `/ui` edge route — its
   remote is relayed via `/m/<svc>/`.

## Minting a join token by hand

```sh
docker exec freya-stack-auth-1 authsvc mint-enrollment-token \
  -config deploy/container.yaml -spiffe spiffe://example.org/svc/<svc> -ttl 30m
```
Tenant defaults to the mesh tenant so the SVID chains to the mesh root. In
production the gateway/console mints these (auth `MintEnrollmentToken`, policed
to gateway/console).

## SVID persistence & restarts

Each enrolled service persists its SVID (cert+key+bundle) to `/state/svid.json`
(a `<svc>-state` volume, 0600). On restart it **reuses** a still-valid SVID and
renews over mTLS — it does not consume a fresh (single-use) join token. A hard
reset (`down -v`) clears the state and regenerates the mesh root, so the next
start does a token enroll again.

## Verifying

```sh
# a service enrolled (no /certs mount), got its SVID, and registered:
docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' freya-stack-<svc>-1   # no /certs
docker logs freya-stack-<svc>-1 | grep -E "identity ready|gateway lease"
# every leaf + lcm's live cert chains to the ONE root:
docker exec freya-stack-lcm-1 sh -c 'echo | openssl s_client -connect notification:9943 ...'  # (mTLS)
```

## Production notes

- **`insecure: true`** disables server verification on the *first-enroll* HTTP
  dial only (the dev gateway edge is self-signed). In production the edge has a
  real TLS certificate — set `insecure: false`. The **renewal** mTLS channel is
  always SPIFFE-verified against the mesh bundle regardless.
- **Restart across the cert lifetime**: if a workload is down longer than its
  SVID's validity, the persisted SVID expires and it needs a fresh join token
  (re-attestation) — deliver one via the orchestrator's secret mechanism.
- **Control-plane bootstrap on other hosts**: `auth`'s (and the mesh CA's)
  bootstrap material is delivered per host by an `lcmsvc bootstrap` init with DB
  access, or an orchestrator secret — the SPIRE-server-bootstrap pattern.
