.PHONY: help init up down restart ps logs test validate clean

COMPOSE := docker compose

help: ## Affiche cette aide
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  %-10s %s\n", $$1, $$2}'

init: ## Prépare l'hôte : .env, secrets, répertoires de données
	@./scripts/init.sh

up: ## Démarre la stack puis configure AdGuard au premier lancement
	$(COMPOSE) up -d
	@./scripts/adguard-setup.sh

down: ## Arrête la stack (les données sont conservées)
	$(COMPOSE) down

restart: down up ## Redémarre la stack

ps: ## État des conteneurs
	$(COMPOSE) ps

logs: ## Suit les logs (make logs s=traefik pour un seul service)
	$(COMPOSE) logs -f --tail=100 $(s)

validate: ## Vérifie la syntaxe du compose et des configurations
	$(COMPOSE) config --quiet
	docker run --rm -v $(PWD)/config/prometheus:/etc/prometheus:ro --entrypoint promtool \
		prom/prometheus:v3.15.0 check config /etc/prometheus/prometheus.yml

test: ## Lance les tests de fumée sur la stack démarrée
	@./scripts/smoke-test.sh

clean: ## Supprime conteneurs, volumes et données (irréversible)
	$(COMPOSE) down -v
	sudo rm -rf data/
