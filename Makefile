.PHONY: help up down restart build logs ps

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
