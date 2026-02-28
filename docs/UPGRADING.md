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

### v1.7 → v1.7.1

Infrastructure cleanup and backup consolidation.

#### 1. Pull and redeploy

```bash
cd /volume1/docker/arr-stack
git pull origin main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
docker compose -f docker-compose.traefik.yml up -d --force-recreate
docker compose -f docker-compose.utilities.yml up -d --force-recreate
```

> **Note:** Start arr-stack first — it now owns the `arr-stack` network. Traefik and utilities reference it as `external: true`.

#### 2. Update backup crontab (if using automated backups)

The backup script was renamed from `backup-volumes.sh` to `arr-backup.sh`:

```bash
sudo crontab -l | sed 's/backup-volumes.sh/arr-backup.sh/' | sudo crontab -
```

Verify: `sudo crontab -l` should show `arr-backup.sh`.

---

### v1.6.5 → v1.7

This release adds TRaSH Guides best practices: hardlinks, naming schemes, download directory structure, and download client hardening.

**Breaking change:** Volume mounts changed for 6 services. Docker Compose will handle this automatically on redeploy, but you must reconfigure paths inside the apps.

#### 1. Create new directories and move library files

```bash
ssh your-username@nas-ip
mkdir -p /volume1/Media/media
mv /volume1/Media/movies /volume1/Media/media/movies
mv /volume1/Media/tv /volume1/Media/media/tv
mkdir -p /volume1/Media/torrents/{tv,movies}
mkdir -p /volume1/Media/usenet/{incomplete,complete/{tv,movies}}
chown -R 1000:1000 /volume1/Media/media /volume1/Media/torrents /volume1/Media/usenet
```

#### 2. Pull and redeploy

```bash
cd /volume1/docker/arr-stack
git pull origin main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
```

Wait ~30 seconds for services to stabilize.

#### 3. Reconfigure Radarr root folder

1. Settings → Media Management → Add Root Folder → `/data/media/movies`
2. Movies → Select All → Edit → Root Folder → `/data/media/movies/` → Save
3. Settings → Media Management → delete old root folder `/movies`
4. **Fix collections:** If you see "Missing root folder for movie collection" on the Health page, go to Movies → Collections → Select All → Edit → Root Folder → `/data/media/movies/` → Save

#### 4. Reconfigure Sonarr root folder

1. Settings → Media Management → Add Root Folder → `/data/media/tv`
2. Series → Select All → Edit → Root Folder → `/data/media/tv/` → Save
3. Settings → Media Management → delete old root folder `/tv`

#### 5. Reconfigure qBittorrent categories

1. Tools → Options → Downloads → Default Torrent Management Mode: **Automatic**
2. Right-click category `sonarr` → Edit → rename to `tv`, save path `/data/torrents/tv`
3. Right-click category `radarr` → Edit → rename to `movies`, save path `/data/torrents/movies`

> **Active torrents:** If you have active torrents, reassign them to the new category names before deleting old categories.

#### 6. Update download client categories in Sonarr/Radarr

- **Sonarr:** Settings → Download Clients → qBittorrent → Category: `tv` (was `sonarr`)
- **Radarr:** Settings → Download Clients → qBittorrent → Category: `movies` (was `radarr`)

#### 7. Reconfigure SABnzbd paths

Config (⚙️) → Folders:
- Temporary Download Folder: `/data/usenet/incomplete`
- Completed Download Folder: `/data/usenet/complete`

Restart SABnzbd after saving.

#### 8. Reconfigure Jellyfin library paths

Dashboard → Libraries:
- Edit Movies library → add `/data/media/movies`, remove `/media/movies`
- Edit TV Shows library → add `/data/media/tv`, remove `/media/tv`

This triggers a library rescan. NFO files ensure accurate identification.

#### 9. Configure TRaSH naming schemes (recommended)

Follow the naming configuration steps in the [App Configuration Guide](APP-CONFIG.md):
- [Sonarr naming](APP-CONFIG.md#44-sonarr-tv-shows) (step 5)
- [Radarr naming](APP-CONFIG.md#45-radarr-movies) (step 5)

After configuring naming, rename existing files:
- Radarr: Movies → Select All → Organize
- Sonarr: Series → Select All → Organize

#### 10. Enable NFO metadata (recommended)

**In Radarr** (`http://NAS_IP:7878`):

1. Settings → Metadata → Kodi (XBMC) / Emby → **Enable**
2. Movie Metadata: ✅, Movie Images: ❌
3. Save, then refresh the full library: Movies → Update All

**In Sonarr** (`http://NAS_IP:8989`):

1. Settings → Metadata → Kodi (XBMC) / Emby → **Enable**
2. Series Metadata: ✅, Episode Metadata: ✅, all image options: ❌
3. Save, then refresh the full library: Series → Update All

The library refresh writes `.nfo` files for all existing media. New downloads get them automatically.

#### What about old `downloads/` directory?

The old `/volume1/Media/downloads/` directory is still accessible inside containers at `/data/downloads/`. Any in-progress downloads will complete normally. Once they're all imported, you can delete the directory.

---

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
- TROUBLESHOOTING.md simplified (common issues consolidated into SETUP.md)

---

### v1.1 → v1.2.x

**Breaking changes:** None

**Automatic improvements** (just redeploy to get these):
- Startup order fixes — Gluetun now waits for Pi-hole to be healthy before connecting
- Improved healthchecks — FlareSolverr actually tests Chrome, catches crashes
- Backup script improvements — smart space checking, 7-day rotation
- SABnzbd added — Usenet downloads via VPN (remove from compose if not wanted); configure in [App Configuration Guide](APP-CONFIG.md#43-sabnzbd-usenet-downloads)

**New features (optional, requires setup):**

| Feature | What it does | Setup |
|---------|--------------|-------|
| `.lan` domains | `http://sonarr.lan` etc, no ports | Router DHCP reservation + Pi-hole DNS, see [Local DNS Guide](LOCAL-DNS.md) |
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
