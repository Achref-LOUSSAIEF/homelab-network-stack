#!/usr/bin/env bash
# Prépare l'hôte avant le premier démarrage :
#   - vérifie le fichier .env
#   - génère les secrets (mots de passe aléatoires) s'ils n'existent pas
#   - crée les répertoires de données avec les bons propriétaires (conteneurs non-root)
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Fichier .env créé à partir de .env.example : adapte-le puis relance 'make init'."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

for cmd in docker openssl; do
  command -v "$cmd" >/dev/null || { echo "Commande manquante : $cmd" >&2; exit 1; }
done

SUDO=""
if [[ $EUID -ne 0 ]]; then SUDO="sudo"; fi

gen_password() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

# --- Modules noyau utilisés par wg-easy (NAT des clients VPN via iptables) ----
if [[ -d /lib/modules/$(uname -r) ]]; then
  if $SUDO modprobe -a ip_tables iptable_nat iptable_filter 2>/dev/null; then
    printf 'ip_tables\niptable_nat\niptable_filter\n' | $SUDO tee /etc/modules-load.d/homelab-wg.conf >/dev/null
  else
    echo "Attention : modules iptables introuvables, le NAT de wg-easy risque d'échouer (voir docs/troubleshooting.md)." >&2
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
  chmod 444 "$file"   # lisible par les conteneurs non-root ; le répertoire reste en 700
}

echo "Secrets :"
for name in grafana_admin_password adguard_admin_password traefik_admin_password wg_admin_password; do
  write_secret "$name" "$(gen_password)"
done

write_secret traefik_dashboard_users \
  "${TRAEFIK_ADMIN_USER:-admin}:$(openssl passwd -apr1 "$(cat secrets/traefik_admin_password)")"

write_secret wg-easy.env "INIT_PASSWORD=$(cat secrets/wg_admin_password)"

# --- Répertoires de données (bind mounts) -------------------------------------
echo "Répertoires de données :"
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

# Traefik refuse un acme.json lisible par d'autres utilisateurs
if [[ ! -f data/traefik/acme.json ]]; then
  $SUDO install -m 600 -o 65532 -g 65532 /dev/null data/traefik/acme.json
fi

echo
echo "Initialisation terminée. Lance la stack avec : make up"
echo "Les mots de passe d'administration sont dans le dossier secrets/."