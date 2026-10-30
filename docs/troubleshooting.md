# Troubleshooting

General approach: start from the symptom, check layer by layer (is the container running?
is the port listening? does the Docker network allow the connection? does DNS resolve?), then read the logs.

```bash
make ps                      # container status
make logs s=traefik          # logs for one service
make test                    # checks the whole stack
```

Logs from every service are also available in Grafana (*Homelab* dashboard, *Logs* panel,
or the *Explore* menu with the Loki source: `{service="traefik"} |= "error"`).

---

## A subdomain returns a 404 error

**Likely cause**: Traefik has not discovered the service's router.

1. Is the container running? `make ps`
2. Does Traefik see the service? Traefik dashboard → *HTTP Routers*.
3. Does the `traefik.docker.network` label match a network shared with Traefik?
   The actual name is prefixed with the project name: `homelab_frontend`, `homelab_vpn`.
4. Can Traefik reach the Docker API? `make logs s=traefik`: an error mentioning `socket-proxy:2375`
   points to a problem reaching the proxy.

## 502 Bad Gateway error

Traefik found the router but cannot reach the container.

- Is the port declared in `loadbalancer.server.port` correct?
- Is the service still starting up? (`make logs s=<service>`)
- Test from Traefik's network:
  `docker compose exec traefik wget -qO- http://grafana:3000/api/health`

## The certificate is invalid ("TRAEFIK DEFAULT CERT")

Let's Encrypt could not validate the domain.

- Does the subdomain point to the host's public IP? `dig +short grafana.<domain>`
- Is port 443 reachable from the Internet (firewall, router NAT, security group)?
- `make logs s=traefik | grep -i acme` gives the exact reason.
- While testing, use the *staging* server (`ACME_CA_SERVER` in `.env`) to avoid hitting
  Let's Encrypt rate limits, then delete `data/traefik/acme.json` before switching back to production.
- `acme.json` must be mode `600` and owned by user 65532 (`make init` takes care of this).

## wg-easy stays "unhealthy" and vpn.<domain> returns 404

Traefik ignores *unhealthy* containers: the 404 is only a consequence. In the wg-easy logs:

```
modprobe: FATAL: Module ip_tables not found in directory /lib/modules/...
iptables v1.8 (legacy): can't initialize iptables table `nat': Table does not exist
```

wg-easy sets up NAT for its clients with iptables (*legacy* mode), but the module is not loaded
on the host and the container cannot load it itself. Fix on the host:

```bash
sudo modprobe -a ip_tables iptable_nat iptable_filter
printf 'ip_tables\niptable_nat\niptable_filter\n' | sudo tee /etc/modules-load.d/homelab-wg.conf
docker compose restart wg-easy
```

## VPN clients connect but have no Internet access

1. Does the WireGuard handshake happen? The wg-easy UI shows the time of the latest handshake.
   If there is none: port **51820/udp** is blocked (firewall, router) or `WG_HOST` is wrong.
2. Handshake OK but no traffic: check IP forwarding and NAT inside the container:
   ```bash
   docker compose exec wg-easy sysctl net.ipv4.ip_forward     # must be 1
   docker compose exec wg-easy iptables -t nat -L POSTROUTING -n -v
   ```
3. MTU problem (ping works, HTTPS sites don't load): lower the clients' MTU
   to 1280 in the wg-easy UI.

## VPN clients have no DNS resolution

- Is AdGuard listening? `docker compose exec wg-easy nslookup example.com 10.8.1.3`
- Has AdGuard been configured? If not: `./scripts/adguard-setup.sh`
- Is the DNS server handed to clients `10.8.1.3`? (`INIT_DNS` variable, applied on first
  start only; can be changed later in the wg-easy UI).
- The dashboard's *DNS resolution time* panel and the `SlowDnsResolution` alert help spot
  a slow upstream.

## A probe is DOWN in Grafana

The dashboard shows which target is failing. In Prometheus (*Status → Targets*), the exact error
appears next to the target. To replay the probe by hand with details for each step:

```bash
docker compose exec prometheus wget -qO- \
  'http://blackbox-exporter:9115/probe?module=http_2xx&target=http://grafana:3000/api/health&debug=true'
```

## Permission denied on startup (Traefik, AdGuard, Alloy)

The containers run as non-root: their `data/` directories must be owned by the right UID.
Run `make init` again, which fixes ownership (`65532` for Traefik, `65534` for Alloy, root for AdGuard).

## Starting from scratch

```bash
make clean    # removes containers, volumes and data/ (secrets are kept)
make init && make up
```