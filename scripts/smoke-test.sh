#!/usr/bin/env bash
# Vérifie que la stack est opérationnelle :
#   1. chaque interface web répond via Traefik en HTTPS
#   2. AdGuard résout des noms de domaine
#   3. Prometheus voit toutes ses cibles et sondes au vert
#   4. Loki reçoit bien les logs des conteneurs
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1091
source .env
set +a

TIMEOUT=${SMOKE_TIMEOUT:-180}
failures=0

pass() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; failures=$((failures + 1)); }

# Réessaie une commande jusqu'au succès ou jusqu'au timeout
retry() {
  local deadline=$((SECONDS + TIMEOUT))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS >= deadline )) && return 1
    sleep 3
  done
}

https_ok() {
  local host="$1.${DOMAIN}" path="${2:-/}"
  local code
  code=$(curl -sk --resolve "${host}:${HTTPS_PORT:-443}:127.0.0.1" -o /dev/null -w '%{http_code}' --max-time 5 "https://${host}:${HTTPS_PORT:-443}${path}")
  [[ "$code" =~ ^(200|302|401)$ ]]
}

prom_query() {
  docker compose exec -T prometheus \
    wget -qO- "http://localhost:9090/api/v1/query?query=$1"
}

all_targets_up() {
  # aucune cible "up == 0" et aucune sonde "probe_success == 0"
  local down
  down=$(prom_query 'count(up%3D%3D0)%20or%20count(probe_success%3D%3D0)' | grep -o '"value":\[[^]]*\]' || true)
  [[ -z "$down" ]] && prom_query 'count(probe_success%3D%3D1)' | grep -q '"value"'
}

dns_resolves() {
  docker run --rm --network homelab_vpn busybox:stable nslookup example.com 10.8.1.3 | grep -q 'Name:'
}

loki_has_logs() {
  docker compose exec -T prometheus \
    wget -qO- 'http://loki:3100/loki/api/v1/label/service/values' | grep -q 'traefik'
}

echo "Interfaces web (via Traefik, HTTPS) :"
for svc in grafana:/api/health dns:/ vpn:/ traefik:/dashboard/; do
  name=${svc%%:*}; path=${svc#*:}
  if retry https_ok "$name" "$path"; then pass "https://${name}.${DOMAIN}${path}"; else fail "https://${name}.${DOMAIN}${path}"; fi
done

echo "Résolution DNS :"
if retry dns_resolves; then pass "AdGuard (10.8.1.3) résout example.com"; else fail "AdGuard ne résout pas"; fi

echo "Supervision :"
if retry all_targets_up; then pass "toutes les cibles Prometheus et sondes sont UP"; else
  fail "cibles ou sondes en échec :"
  prom_query 'up%3D%3D0%20or%20probe_success%3D%3D0' || true
  echo
fi

echo "Logs :"
if retry loki_has_logs; then pass "Loki reçoit les logs des conteneurs"; else fail "aucun log dans Loki"; fi

echo
if (( failures > 0 )); then
  echo "$failures vérification(s) en échec."
  exit 1
fi
echo "Tous les tests sont passés."
