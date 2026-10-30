#!/usr/bin/env bash
# Configures AdGuard Home on first start through its install API,
# so the setup wizard is never left open.
#   - web UI:     port 3000 (routed by Traefik on dns.<DOMAIN>)
#   - DNS server: port 53 (used by WireGuard clients)
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -f data/adguard/conf/AdGuardHome.yaml ]]; then
  echo "AdGuard Home is already configured."
  exit 0
fi

PORT=${HTTPS_PORT:-443}
URL="https://dns.${DOMAIN}:${PORT}"
CURL=(curl -sk --resolve "dns.${DOMAIN}:${PORT}:127.0.0.1" --max-time 5)

echo "Waiting for AdGuard Home..."
for _ in $(seq 1 60); do
  code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$URL/control/install/get_addresses" || true)
  [[ "$code" == "200" ]] && break   # install wizard ready
  sleep 2
done

[[ "${code:-}" == "200" ]] || { echo "AdGuard unreachable (HTTP ${code:-?})" >&2; exit 1; }

payload=$(printf '{"web":{"ip":"0.0.0.0","port":3000},"dns":{"ip":"0.0.0.0","port":53},"username":"%s","password":"%s"}' \
  "${ADGUARD_ADMIN_USER:-admin}" "$(cat secrets/adguard_admin_password)")

"${CURL[@]}" --fail-with-body -X POST -H 'Content-Type: application/json' \
  -d "$payload" "$URL/control/install/configure"

echo
echo "AdGuard Home configured (user: ${ADGUARD_ADMIN_USER:-admin})."
