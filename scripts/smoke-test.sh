#!/usr/bin/env bash
# Checks that the stack is working:
#   1. every web UI answers over HTTPS through Traefik
#   2. AdGuard resolves domain names
#   3. Prometheus sees all its targets and probes as up
#   4. Loki receives the container logs
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1091
source .env
set +a

TIMEOUT=${SMOKE_TIMEOUT:-180}
PORT=${HTTPS_PORT:-443}
failures=0

pass() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; failures=$((failures + 1)); }

# Retries a command until it succeeds or TIMEOUT expires
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
  code=$(curl -sk --resolve "${host}:${PORT}:127.0.0.1" -o /dev/null -w '%{http_code}' --max-time 5 "https://${host}:${PORT}${path}")
  [[ "$code" =~ ^(200|302|401)$ ]]
}

prom_query() {
  docker compose exec -T prometheus \
    wget -qO- "http://localhost:9090/api/v1/query?query=$1"
}

all_targets_up() {
  # no target with "up == 0" and no probe with "probe_success == 0"
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

echo "Web UIs (through Traefik, HTTPS):"
for svc in grafana:/api/health dns:/ vpn:/ traefik:/dashboard/; do
  name=${svc%%:*}; path=${svc#*:}
  if retry https_ok "$name" "$path"; then pass "https://${name}.${DOMAIN}${path}"; else fail "https://${name}.${DOMAIN}${path}"; fi
done

echo "DNS resolution:"
if retry dns_resolves; then pass "AdGuard (10.8.1.3) resolves example.com"; else fail "AdGuard does not resolve"; fi

echo "Monitoring:"
if retry all_targets_up; then pass "all Prometheus targets and probes are UP"; else
  fail "failing targets or probes:"
  prom_query 'up%3D%3D0%20or%20probe_success%3D%3D0' || true
  echo
fi

echo "Logs:"
if retry loki_has_logs; then pass "Loki receives container logs"; else fail "no logs in Loki"; fi

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed."
  exit 1
fi
echo "All checks passed."
