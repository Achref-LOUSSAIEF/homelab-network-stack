.PHONY: help init up down restart ps logs test validate clean

COMPOSE := docker compose

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-10s %s\n", $$1, $$2}'

init: ## Prepare the host: .env, secrets, data directories
	@./scripts/init.sh

up: ## Start the stack, then configure AdGuard on first run
	$(COMPOSE) up -d
	@./scripts/adguard-setup.sh

down: ## Stop the stack (data is kept)
	$(COMPOSE) down

restart: down up ## Restart the stack

ps: ## Container status
	$(COMPOSE) ps

logs: ## Follow logs (make logs s=traefik for one service)
	$(COMPOSE) logs -f --tail=100 $(s)

validate: ## Validate the Compose file and configs
	$(COMPOSE) config --quiet
	docker run --rm -v $(PWD)/config/prometheus:/etc/prometheus:ro --entrypoint promtool \
		prom/prometheus:v3.15.0 check config /etc/prometheus/prometheus.yml

test: ## Run smoke tests against the running stack
	@./scripts/smoke-test.sh

clean: ## Remove containers, volumes and data (irreversible)
	$(COMPOSE) down -v
	sudo rm -rf data/
