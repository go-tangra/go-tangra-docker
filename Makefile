.PHONY: help init up down reset config ps logs pull allow-list integrity

COMPOSE ?= docker compose

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'

init: docker-compose.yaml ## Create docker-compose.yaml (and .env) from the examples
	@test -f .env || cp .env.example .env

docker-compose.yaml:
	cp docker-compose.yaml.example docker-compose.yaml

up: ## Bring the stack up (up.sh: pull, up, print the operator accept link)
	@./up.sh

down: ## Stop the stack, keep volumes
	@$(COMPOSE) down

reset: ## Stop the stack and DELETE its volumes (database, CA, tokens, SVID state)
	@$(COMPOSE) down -v

config: docker-compose.yaml ## Validate the compose file with the current .env
	@$(COMPOSE) config --quiet && echo "compose config OK"

ps: ## Show running services
	@$(COMPOSE) ps

logs: ## Follow logs for all services
	@$(COMPOSE) logs -f

pull: ## Pull the service images
	@$(COMPOSE) pull --ignore-buildable

allow-list: ## Re-apply the gateway registration allow-list
	@./scripts/apply-allow.sh

integrity: ## Run the SVID rotation integrity test (start with CERT_TTL=5m RENEW_INTERVAL=210)
	@./scripts/integrity-test.sh
