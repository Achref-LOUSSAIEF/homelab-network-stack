#!/usr/bin/env bash
# Prepares the host before the first start:
#   - checks the .env file
#   - generates secrets (random passwords) if they don't exist
#   - creates data directories with the right owners (non-root containers)
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example: edit it, then run 'make init' again."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

for cmd in docker openssl; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done

SUDO=""
[[ $EUID -eq 0 ]] || SUDO="sudo"

gen_password() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

# --- Kernel modules used by wg-easy (VPN client NAT through iptables) --------
if [[ -d /lib/modules/$(uname -r) ]]; then
  if $SUDO modprobe -a ip_tables iptable_nat iptable_filter 2>/dev/null; then
    printf 'ip_tables\niptable_nat\niptable_filter\n' | $SUDO tee /etc/modules-load.d/homelab-wg.conf >/dev/null
  else
    echo "Warning: iptables modules not found, wg-easy NAT will probably fail (see docs/troubleshooting.md)." >&2
  fi
fi

# --- Secrets ------------------------------------------------------------------
mkdir -p secrets
chmod 700 secrets

write_secret() {
  local file="secrets/$1" content="$2"
  if [[ ! -f "$file" ]]; then
    printf '%s' "$content" > "$file"
    echo "  + $file"
  fi
  chmod 444 "$file"   # readable by non-root containers; the directory stays 700
}

echo "Secrets:"
for name in grafana_admin_password adguard_admin_password traefik_admin_password wg_admin_password; do
  write_secret "$name" "$(gen_password)"
done

write_secret traefik_dashboard_users \
  "${TRAEFIK_ADMIN_USER:-admin}:$(openssl passwd -apr1 "$(cat secrets/traefik_admin_password)")"

write_secret wg-easy.env "INIT_PASSWORD=$(cat secrets/wg_admin_password)"

# --- Data directories (bind mounts) -------------------------------------------
echo "Data directories:"
make_data_dir() {
  local dir="data/$1" owner="$2"
  mkdir -p "$dir"
  $SUDO chown -R "$owner" "$dir"
  echo "  + $dir ($owner)"
}
make_data_dir traefik       65532:65532
make_data_dir adguard/work  0:0
make_data_dir adguard/conf  0:0
make_data_dir alloy         65534:65534

# Traefik rejects an acme.json readable by other users
if [[ ! -f data/traefik/acme.json ]]; then
  $SUDO install -m 600 -o 65532 -g 65532 /dev/null data/traefik/acme.json
fi

echo
echo "Init done. Start the stack with: make up"
echo "Admin passwords are in the secrets/ folder."