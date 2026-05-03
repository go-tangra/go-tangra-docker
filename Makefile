.PHONY: help up down restart build logs ps lcm-fingerprint lcm-bootstrap

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

up: ## Start all services
	@docker compose up -d

down: ## Stop all services
	@docker compose down

restart: ## Restart all services
	@docker compose restart

build: ## Build all services
	@docker compose build

logs: ## Follow logs for all services
	@docker compose logs -f

ps: ## Show running services
	@docker compose ps

lcm-fingerprint: ## Print the LCM CA SHA-256 fingerprint (set WRITE=1 to update .env)
	@./scripts/lcm-fingerprint.sh $(if $(WRITE),--write,)

lcm-bootstrap: ## First-time setup: bring lcm-service up + write CA pin to .env
	@docker compose up -d lcm-service
	@echo "Waiting for lcm-service to generate the CA..."
	@for i in $$(seq 1 60); do \
	  if docker run --rm \
	      -v $$(basename $$(pwd))_lcm-data:/data:ro \
	      alpine:3.20 test -f /data/ca/ca.crt 2>/dev/null; then \
	    break; \
	  fi; \
	  sleep 1; \
	done
	@./scripts/lcm-fingerprint.sh --write
	@echo "Done. You can now bring up the rest of the stack: make up"
