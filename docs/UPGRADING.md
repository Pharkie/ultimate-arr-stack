# Upgrading the Stack

Already running an earlier version? There are two types of upgrades:

1. **Stack updates** — New features, bug fixes, compose changes from this repo
2. **Container image updates** — Newer versions of Sonarr, Radarr, Jellyfin, etc.

## Stack Updates (this repo)

SSH into your NAS and pull the latest changes:

```bash
ssh your-username@nas-ip
cd /volume1/docker/arr-stack  # or your deployment path

git pull origin main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate  # Updates AND restarts - no further steps needed
```

The `--force-recreate` flag ensures containers restart with new config even if the image hasn't changed.

## Container Image Updates (Sonarr, Jellyfin, etc.)

To pull the latest Docker images and restart with them:

```bash
docker compose -f docker-compose.arr-stack.yml pull
docker compose -f docker-compose.arr-stack.yml up -d  # Restarts containers with new images - no further steps needed
```

> **Ugreen NAS users:** UGOS has a built-in Container Manager that automatically updates images on a schedule. Check **Docker → Settings → Auto Update** to configure. You can skip manual image updates if this is enabled.

> **Note:** Docker named volumes persist across restarts. All your service configurations (Sonarr settings, API keys, library data, etc.) are preserved.

---

## Migration Notes

When upgrading across versions, check below for any action required.

### v1.4 → v1.5

**Breaking change:** Removed all env var fallbacks from compose files.

Previously, compose files had fallbacks like `${MEDIA_ROOT:-/volume1/Media}`. Now they use `${MEDIA_ROOT}` — if a variable is missing from `.env`, Docker will fail with a clear error instead of silently using a default.

**Action required:** Ensure your `.env` has all required variables. If you copied from `.env.example` when you first set up, you're fine. If not:

```bash
# Check for missing variables
diff <(grep -oP '^\$\{[A-Z_]+\}' docker-compose.arr-stack.yml | sort -u) <(grep -oP '^[A-Z_]+=' .env | cut -d= -f1 | sort -u)
```

Or just copy the latest `.env.example` and fill in your values.

**Also in v1.5** (non-breaking):

| Change | Details |
|--------|---------|
| SSL simplified | Removed Let's Encrypt DNS challenge. Cloudflare Tunnel handles HTTPS at the edge. |
| `traefik.yml.example` | Now HTTP-only (simpler). Old config still works. |
| `CF_DNS_API_TOKEN` | Removed from `.env.example` (was unused) |
| `acme.json` | No longer needed. Can delete if you have one. |
| `.env.example` reorganized | Now ordered by setup level: Core → + local DNS → + remote access |

**Optional cleanup:**

```bash
# Remove unused certificate file (if it exists)
rm -f traefik/acme.json
```

---

### v1.3 → v1.4

**Network renamed:** `traefik-proxy` → `arr-stack`

The old name was confusing - implied Traefik was required for Core setup. The network is used by all services.

```bash
cd /volume1/docker/arr-stack && \
git pull origin main && \
docker compose -f docker-compose.arr-stack.yml down && \
docker compose -f docker-compose.utilities.yml down 2>/dev/null; \
docker compose -f docker-compose.cloudflared.yml down 2>/dev/null; \
docker compose -f docker-compose.traefik.yml down 2>/dev/null; \
docker network rm traefik-proxy && \
docker network create --driver=bridge --subnet=172.20.0.0/24 --gateway=172.20.0.1 arr-stack && \
docker compose -f docker-compose.arr-stack.yml up -d && \
docker compose -f docker-compose.traefik.yml up -d 2>/dev/null; \
docker compose -f docker-compose.cloudflared.yml up -d 2>/dev/null; \
docker compose -f docker-compose.utilities.yml up -d 2>/dev/null; \
echo "Migration complete"
```

> **Other containers on the old network?** Update their compose files to use `arr-stack` instead of `traefik-proxy`.

---

### v1.2.x → v1.3

**Breaking change:** Docker network subnet changed from `192.168.100.0/24` to `172.20.0.0/24`.

Run the full migration as a single chained command to minimize DNS downtime:

```bash
cd /volume1/docker/arr-stack && \
git pull origin main && \
docker compose -f docker-compose.arr-stack.yml down && \
docker compose -f docker-compose.utilities.yml down 2>/dev/null; \
docker compose -f docker-compose.cloudflared.yml down 2>/dev/null; \
docker compose -f docker-compose.traefik.yml down && \
docker network rm arr-stack && \
docker network create --driver=bridge --subnet=172.20.0.0/24 --gateway=172.20.0.1 arr-stack && \
docker compose -f docker-compose.traefik.yml up -d && \
docker compose -f docker-compose.arr-stack.yml up -d && \
docker compose -f docker-compose.cloudflared.yml up -d 2>/dev/null; \
docker compose -f docker-compose.utilities.yml up -d 2>/dev/null; \
echo "Migration complete"
```

> **Other containers on arr-stack?** If you have containers from other compose files using this network (e.g., Frigate), stop them first, then update their compose files to use `172.20.0.x` IPs before restarting.

> **Why the change?** The new `172.20.0.0/24` subnet is a Docker-conventional range, less likely to conflict with home LANs (which often use `192.168.x.x`).

**New features:**

| Feature | What it does |
|---------|--------------|
| Jellyfin discovery ports | Apps auto-detect Jellyfin on LAN (7359/udp, 1900/udp) |
| "Adding More Services" docs | Example for adding Lidarr, Readarr, etc. |

**Documentation improvements:**

- README simplified (services table moved to SETUP.md)
- SETUP.md restructured with Stack Overview section
- Section headings now action-oriented
- Consistent `flaresolverr.lan` usage throughout
- TROUBLESHOOTING.md removed (notes consolidated into SETUP.md)

---

### v1.1 → v1.2.x

**Breaking changes:** None

**Automatic improvements** (just redeploy to get these):
- Startup order fixes — Gluetun now waits for Pi-hole to be healthy before connecting
- Improved healthchecks — FlareSolverr actually tests Chrome, catches crashes
- Backup script improvements — smart space checking, 7-day rotation
- SABnzbd added — Usenet downloads via VPN (remove from compose if not wanted); configure in [SETUP.md](SETUP.md#usenet-sabnzbd)

**New features (optional, requires setup):**

| Feature | What it does | Setup |
|---------|--------------|-------|
| `.lan` domains | `http://sonarr.lan` etc, no ports | Router DHCP reservation + Pi-hole DNS, see [SETUP.md](SETUP.md#local-dns-lan-domains---optional) |
| `MEDIA_ROOT` env var | Configurable media path | Set in `.env` |
| deunhealth | Auto-restart crashed services | Deploy `docker-compose.utilities.yml` |

**New .env variables:**

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `MEDIA_ROOT` | Yes | — | Base path for media storage |
| `TRAEFIK_LAN_IP` | Only for .lan | — | Traefik's dedicated LAN IP for local DNS |
| `LAN_INTERFACE` | Only for .lan | — | Network interface (e.g., `eth0`) |
| `LAN_SUBNET` | Only for .lan | — | Your LAN subnet (e.g., `10.10.0.0/24`) |
| `LAN_GATEWAY` | Only for .lan | — | Router IP |
| `TRAEFIK_LAN_MAC` | Only for .lan | — | Fixed MAC for DHCP reservation |

See [.env.example](../.env.example) for all available variables.
