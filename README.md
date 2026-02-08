# Go-Tangra Docker

Docker Compose configuration for running the entire Go-Tangra platform stack.

## Prerequisites

- Docker Engine 24.0+
- Docker Compose 2.20+
- At least 8GB RAM available for Docker
- The following repositories cloned as siblings:
  ```
  go-tangra/
  ├── go-tangra-docker/      # This repository
  ├── go-tangra-portal/      # Admin portal backend
  ├── go-tangra-frontend/    # Frontend application
  ├── go-tangra-lcm/         # Lifecycle Management service
  ├── go-tangra-deployer/    # Deployer service
  ├── go-tangra-warden/      # Secrets management service
  ├── go-tangra-ipam/        # IP Address Management service
  └── go-tangra-paperless/   # Document management service
  ```

## Quick Start

1. **Clone all repositories** (if not already done):
   ```bash
   cd go-tangra
   git clone <url>/go-tangra-docker.git
   git clone <url>/go-tangra-portal.git
   git clone <url>/go-tangra-frontend.git
   git clone <url>/go-tangra-lcm.git
   git clone <url>/go-tangra-deployer.git
   git clone <url>/go-tangra-warden.git
   git clone <url>/go-tangra-ipam.git
   git clone <url>/go-tangra-paperless.git
   ```

2. **Configure environment** (optional):
   ```bash
   cd go-tangra-docker
   cp .env.example .env
   # Edit .env as needed
   ```

3. **Start the platform**:

   **Production** (pulls pre-built images from GHCR):
   ```bash
   docker compose up -d
   docker compose pull   # Pull latest images
   ```

   **Development** (builds from local source):
   ```bash
   docker compose -f docker-compose.dev.yaml up -d --build
   ```

4. **Access the application**:
   - Frontend: http://localhost:8080
   - Admin API: http://localhost:7788
   - Vault UI: http://localhost:8200 (token: `dev-token`)
   - RustFS Console: http://localhost:9001

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Frontend (:8080)                         │
│                        (nginx + Vue.js)                          │
└─────────────────────────────────┬───────────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────────┐
│                      Admin Service (:7787/7788/7789)             │
│                    (Portal Backend + Dynamic Router)             │
└────┬─────────┬─────────┬─────────┬─────────┬────────────────────┘
     │         │         │         │         │
     ▼         ▼         ▼         ▼         ▼
┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌──────────┐
│  LCM   │ │Deployer│ │ Warden │ │  IPAM  │ │Paperless │
│ :9100  │ │ :9200  │ │ :9300  │ │ :9400  │ │  :9500   │
└────┬───┘ └────┬───┘ └────┬───┘ └────┬───┘ └────┬─────┘
     │         │         │         │         │
     └─────────┴─────────┴─────────┴─────────┘
                         │
        ┌────────────────┼────────────────┐
        ▼                ▼                ▼
   ┌─────────┐     ┌─────────┐      ┌─────────┐
   │PostgreSQL│     │  Redis  │      │  Vault  │
   │  :5432  │     │  :6379  │      │  :8200  │
   └─────────┘     └─────────┘      └─────────┘
```

## Services

| Service | Port(s) | Description |
|---------|---------|-------------|
| frontend | 8080 | Vue.js web application |
| admin-service | 7787, 7788, 7789 | Portal backend with dynamic module routing |
| lcm-service | 8000, 9100 | Lifecycle & Certificate Management |
| deployer-service | 9200 | Deployment automation |
| warden-service | 9300 | Secrets management (Vault backend) |
| ipam-service | 9400 | IP Address Management |
| paperless-service | 9500 | Document management |
| postgres | 5432 | TimescaleDB (PostgreSQL) |
| redis | 6379 | Redis cache |
| vault | 8200 | HashiCorp Vault |
| rustfs | 9000, 9001 | Object storage (S3-compatible) |

## Commands

```bash
# Start all services
make up

# Stop all services
make down

# Rebuild and start
make rebuild

# View logs
make logs

# View specific service logs
make logs-admin
make logs-lcm

# Restart specific service
make restart-admin

# Stop and remove all data
make clean

# Access shells
make shell-admin      # Admin service shell
make shell-postgres   # PostgreSQL CLI
make shell-redis      # Redis CLI
```

## Configuration

### Environment Variables

Copy `.env.example` to `.env` and customize:

| Variable | Default | Description |
|----------|---------|-------------|
| POSTGRES_PASSWORD | *Abcd123456 | PostgreSQL password |
| REDIS_PASSWORD | *Abcd123456 | Redis password |
| VAULT_DEV_TOKEN | dev-token | Vault root token |
| RUSTFS_ACCESS_KEY | rustfsadmin | Object storage access key |
| RUSTFS_SECRET_KEY | rustfsadmin | Object storage secret key |

### Service Configuration

Service-specific configs are in `configs/<service>/`:

- `configs/admin/` - Admin service configuration
- `configs/lcm/` - LCM service configuration
- `configs/deployer/` - Deployer service configuration
- `configs/warden/` - Warden service configuration
- `configs/ipam/` - IPAM service configuration
- `configs/paperless/` - Paperless service configuration

## mTLS Architecture

The platform uses mutual TLS (mTLS) for service-to-service communication:

1. **LCM Service** acts as the Certificate Authority
2. On startup, LCM generates:
   - CA certificate
   - Client certificates (admin, deployer)
   - Server certificates (for each module)
3. **lcm-init** container waits for all certificates
4. Services mount the shared `lcm-data` volume for certificates

## Troubleshooting

### Services not starting

Check if all sibling repositories exist:
```bash
ls -la ../go-tangra-*
```

### Certificate issues

Check LCM init logs:
```bash
docker compose logs lcm-init
```

### Database connection issues

Verify PostgreSQL is healthy:
```bash
docker compose exec postgres pg_isready
```

### Reset everything

```bash
make clean
make up
```

## Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| Frontend | admin | admin123 |
| PostgreSQL | postgres | *Abcd123456 |
| Redis | - | *Abcd123456 |
| Vault | - | dev-token |
| RustFS | rustfsadmin | rustfsadmin |

> **Warning**: Change these credentials in production!

## License

MIT License
