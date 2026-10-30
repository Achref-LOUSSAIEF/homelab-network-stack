#!/usr/bin/env bash
# Configure AdGuard Home au premier démarrage via son API d'installation,
# pour ne pas laisser l'assistant web ouvert.
#   - interface web : port 3000 (routé par Traefik sur dns.<DOMAIN>)
#   - serveur DNS   : port 53 (utilisé par les clients WireGuard)
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -f data/adguard/conf/AdGuardHome.yaml ]]; then
  echo "AdGuard Home est déjà configuré."
  exit 0
fi

URL="https://dns.${DOMAIN}:${HTTPS_PORT:-443}"
CURL=(curl -sk --resolve "dns.${DOMAIN}:${HTTPS_PORT:-443}:127.0.0.1" --max-time 5)

echo "Attente d'AdGuard Home..."
for _ in $(seq 1 60); do
  code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$URL/control/install/get_addresses" || true)
  [[ "$code" == "200" ]] && break   # assistant d'installation prêt
  sleep 2
done

[[ "${code:-}" == "200" ]] || { echo "AdGuard injoignable (HTTP ${code:-?})" >&2; exit 1; }

payload=$(printf '{"web":{"ip":"0.0.0.0","port":3000},"dns":{"ip":"0.0.0.0","port":53},"username":"%s","password":"%s"}' \
  "${ADGUARD_ADMIN_USER:-admin}" "$(cat secrets/adguard_admin_password)")

"${CURL[@]}" --fail-with-body -X POST -H 'Content-Type: application/json' \
  -d "$payload" "$URL/control/install/configure"

echo
echo "AdGuard Home configuré (utilisateur : ${ADGUARD_ADMIN_USER:-admin})."
