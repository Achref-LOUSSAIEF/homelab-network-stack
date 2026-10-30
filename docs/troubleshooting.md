# Dépannage

Méthode générale : partir du symptôme, vérifier couche par couche (le conteneur tourne-t-il ?
le port écoute-t-il ? le réseau Docker permet-il la connexion ? le DNS résout-il ?), puis lire les logs.

```bash
make ps                      # état des conteneurs
make logs s=traefik          # logs d'un service
make test                    # vérifie l'ensemble de la stack
```

Les logs de tous les services sont aussi consultables dans Grafana (dashboard *Homelab*, panneau *Logs*,
ou menu *Explore* avec la source Loki : `{service="traefik"} |= "error"`).

---

## Un sous-domaine renvoie une erreur 404

**Cause probable** : Traefik n'a pas découvert le routeur du service.

1. Le conteneur tourne-t-il ? `make ps`
2. Traefik voit-il le service ? Dashboard Traefik → *HTTP Routers*.
3. Le label `traefik.docker.network` correspond-il à un réseau partagé avec Traefik ?
   Le nom réel est préfixé par le projet : `homelab_frontend`, `homelab_vpn`.
4. Traefik accède-t-il à l'API Docker ? `make logs s=traefik` : une erreur sur `socket-proxy:2375`
   indique un problème d'accès au proxy.

## Erreur 502 Bad Gateway

Traefik a trouvé le routeur mais n'atteint pas le conteneur.

- Le port déclaré dans `loadbalancer.server.port` est-il le bon ?
- Le service est-il encore en train de démarrer ? (`make logs s=<service>`)
- Test depuis le réseau de Traefik :
  `docker compose exec traefik wget -qO- http://grafana:3000/api/health`

## Le certificat n'est pas valide (« TRAEFIK DEFAULT CERT »)

Let's Encrypt n'a pas pu valider le domaine.

- Le sous-domaine pointe-t-il vers l'IP publique de l'hôte ? `dig +short grafana.<domaine>`
- Le port 443 est-il joignable depuis Internet (pare-feu, NAT de la box, security group) ?
- `make logs s=traefik | grep -i acme` donne la raison exacte.
- En phase de test, utilise le serveur *staging* (`ACME_CA_SERVER` dans `.env`) pour ne pas atteindre
  les limites de Let's Encrypt, puis supprime `data/traefik/acme.json` avant de repasser en production.
- `acme.json` doit être en `600` et appartenir à l'utilisateur 65532 (`make init` s'en charge).

## wg-easy reste « unhealthy » et vpn.<domaine> renvoie 404

Traefik ignore les conteneurs *unhealthy* : le 404 n'est qu'une conséquence. Dans les logs de wg-easy :

```
modprobe: FATAL: Module ip_tables not found in directory /lib/modules/...
iptables v1.8 (legacy): can't initialize iptables table `nat': Table does not exist
```

wg-easy crée le NAT de ses clients avec iptables (mode *legacy*), mais le module n'est pas chargé
sur l'hôte et le conteneur ne peut pas le charger lui-même. Correction sur l'hôte :

```bash
sudo modprobe -a ip_tables iptable_nat iptable_filter
printf 'ip_tables\niptable_nat\niptable_filter\n' | sudo tee /etc/modules-load.d/homelab-wg.conf
docker compose restart wg-easy
```

## Les clients VPN se connectent mais n'ont pas Internet

1. Le handshake WireGuard a-t-il lieu ? L'interface wg-easy affiche la date du dernier handshake.
   S'il n'y en a pas : le port **51820/udp** est bloqué (pare-feu, box) ou `WG_HOST` est incorrect.
2. Handshake OK mais pas de trafic : vérifier l'IP forwarding et le NAT dans le conteneur :
   ```bash
   docker compose exec wg-easy sysctl net.ipv4.ip_forward     # doit valoir 1
   docker compose exec wg-easy iptables -t nat -L POSTROUTING -n -v
   ```
3. Problème de MTU (le ping passe, les sites HTTPS ne chargent pas) : réduire la MTU des clients
   à 1280 dans l'interface wg-easy.

## Les clients VPN n'ont pas de résolution DNS

- AdGuard écoute-t-il ? `docker compose exec wg-easy nslookup example.com 10.8.1.3`
- AdGuard a-t-il été configuré ? Sinon : `./scripts/adguard-setup.sh`
- Le DNS distribué aux clients est-il `10.8.1.3` ? (variable `INIT_DNS`, appliquée au premier
  démarrage seulement ; modifiable ensuite dans l'interface wg-easy).
- Le panneau *Temps de résolution DNS* du dashboard et l'alerte `SlowDnsResolution` aident à repérer
  un upstream lent.

## Une sonde est DOWN dans Grafana

Le dashboard indique quelle cible échoue. Dans Prometheus (*Status → Targets*), l'erreur exacte
apparaît à côté de la cible. Pour rejouer la sonde à la main avec le détail de chaque étape :

```bash
docker compose exec prometheus wget -qO- \
  'http://blackbox-exporter:9115/probe?module=http_2xx&target=http://grafana:3000/api/health&debug=true'
```

## Permission denied au démarrage (Traefik, AdGuard, Alloy)

Les conteneurs tournent en non-root : leurs répertoires `data/` doivent appartenir au bon UID.
Relancer `make init`, qui corrige les propriétaires (`65532` pour Traefik, `65534` pour Alloy, root pour AdGuard).

## Repartir de zéro

```bash
make clean    # supprime conteneurs, volumes et data/ (les secrets sont conservés)
make init && make up
```