.PHONY: help up down build rebuild logs ps clean pull dev dev-build dev-down generate-api ts

# Default target
help:
	@echo "Go-Tangra Platform Docker Commands"
	@echo ""
	@echo "Production (pulls pre-built images from GHCR):"
	@echo "  make up        - Start all services"
	@echo "  make down      - Stop all services"
	@echo "  make pull      - Pull latest images from GHCR"
	@echo "  make logs      - Follow all logs"
	@echo "  make ps        - Show running services"
	@echo "  make clean     - Stop services and remove volumes"
	@echo ""
	@echo "Development (builds from local source):"
	@echo "  make dev       - Start all services (build from source)"
	@echo "  make dev-build - Rebuild and restart all services"
	@echo "  make dev-down  - Stop all dev services"
	@echo ""
	@echo "API Generation:"
	@echo "  make ts            - Generate TypeScript API for frontend"
	@echo "  make generate-api  - Same as 'make ts'"
	@echo ""
	@echo "Service-specific commands:"
	@echo "  make logs-admin     - Follow admin-service logs"
	@echo "  make logs-lcm       - Follow lcm-service logs"
	@echo "  make logs-deployer  - Follow deployer-service logs"
	@echo "  make logs-warden    - Follow warden-service logs"
	@echo "  make logs-ipam      - Follow ipam-service logs"
	@echo "  make logs-paperless - Follow paperless-service logs"
	@echo ""
	@echo "  make restart-admin     - Restart admin-service"
	@echo "  make restart-lcm       - Restart lcm-service"
	@echo "  make restart-deployer  - Restart deployer-service"
	@echo "  make restart-warden    - Restart warden-service"
	@echo "  make restart-ipam      - Restart ipam-service"
	@echo "  make restart-paperless - Restart paperless-service"

# ===========================================
# Production (GHCR images)
# ===========================================

# Start all services
up:
	docker compose up -d

# Stop all services
down:
	docker compose down

# Pull latest images
pull:
	docker compose pull

# Stop and remove volumes
clean:
	docker compose down -v

# ===========================================
# Development (build from source)
# ===========================================

DEV_COMPOSE = docker compose -f docker-compose.dev.yaml

# Start all services (build from source)
dev:
	$(DEV_COMPOSE) up -d

# Rebuild and restart
dev-build:
	$(DEV_COMPOSE) up -d --build

# Stop all dev services
dev-down:
	$(DEV_COMPOSE) down

# Clean dev environment
dev-clean:
	$(DEV_COMPOSE) down -v

# Follow logs
logs:
	docker compose logs -f

# Show running services
ps:
	docker compose ps

# Service-specific logs
logs-admin:
	docker compose logs -f admin-service

logs-lcm:
	docker compose logs -f lcm-service

logs-deployer:
	docker compose logs -f deployer-service

logs-warden:
	docker compose logs -f warden-service

logs-ipam:
	docker compose logs -f ipam-service

logs-paperless:
	docker compose logs -f paperless-service

logs-frontend:
	docker compose logs -f frontend

# Service-specific restarts
restart-admin:
	docker compose restart admin-service

restart-lcm:
	docker compose restart lcm-service

restart-deployer:
	docker compose restart deployer-service

restart-warden:
	docker compose restart warden-service

restart-ipam:
	docker compose restart ipam-service

restart-paperless:
	docker compose restart paperless-service

restart-frontend:
	docker compose restart frontend

# Infrastructure services
logs-infra:
	docker compose logs -f postgres redis vault rustfs

restart-infra:
	docker compose restart postgres redis vault rustfs

# Development helpers
shell-admin:
	docker compose exec admin-service /bin/sh

shell-postgres:
	docker compose exec postgres psql -U postgres -d gwa

shell-redis:
	docker compose exec redis redis-cli -a '*Abcd123456'

# ===========================================
# API Generation
# ===========================================

# Generate TypeScript API for frontend (all modules)
ts: generate-api

generate-api:
	@./scripts/generate-api.sh

# Generate TypeScript for portal only
ts-portal:
	@cd ../go-tangra-portal && make ts

# Generate full API clients (with typed service methods)
ts-full:
	@./scripts/generate-api-full.sh

# Install API generation dependencies
ts-deps:
	@npm install -g openapi-typescript openapi-typescript-codegen
	@echo "TypeScript generation dependencies installed"
