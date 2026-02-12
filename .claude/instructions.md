# Project Instructions for Claude Code

## ⚠️ FIRST: NAS SSH Access

**Before ANY SSH command, read `config.local.md` for credentials.**

```bash
# Pattern for ALL NAS commands:
sshpass -p 'PASSWORD' ssh USER@HOST "COMMAND"

# With sudo:
sshpass -p 'PASSWORD' ssh USER@HOST "echo 'PASSWORD' | sudo -S COMMAND"
```

**NEVER guess usernames or try random SSH keys. The credentials are in `config.local.md`.**

---

## What This Project Is

A Docker Compose media automation stack **that runs on a NAS**, not on this local machine. Users request TV shows/movies via Jellyseerr → Sonarr/Radarr search for them → qBittorrent/SABnzbd download them (through VPN) → media appears in Jellyfin ready to watch.

**⚠️ IMPORTANT: This repo is the SOURCE CODE. The stack RUNS on a remote NAS.**
- Local machine (where Claude Code runs): Development, editing config files
- NAS (remote): Where Docker containers actually run
- **All `docker` commands must be run via SSH to the NAS** - they won't work locally
- See `config.local.md` for NAS hostname/IP and SSH credentials

**Key services:**
- **Jellyfin** - Media server (like Netflix for your own content)
- **Jellyseerr** - Request portal for users to ask for shows/movies
- **Sonarr/Radarr** - TV/Movie managers that find and organize downloads
- **Prowlarr** - Indexer manager (finds download sources)
- **qBittorrent** - Torrent client (downloads via VPN)
- **SABnzbd** - Usenet client (downloads via VPN)
- **Gluetun** - VPN gateway container (protects all download traffic)
- **Pi-hole** - DNS server (enables `.lan` domains, blocks ads)
- **Traefik** - Reverse proxy (routes `sonarr.lan` → correct container)

**Networking:** Services behind VPN share Gluetun's network (`network_mode: service:gluetun`). They reach each other via `localhost`. Services outside the VPN reach them via `gluetun` hostname.

---

## ⚠️ CRITICAL: Read Before Any Docker Commands

**Pi-hole provides DNS for the entire LAN. Stopping it = no internet.**

```bash
# ❌ NEVER DO THIS - kills DNS, you lose connection before up -d runs
docker compose -f docker-compose.arr-stack.yml down
docker compose -f docker-compose.arr-stack.yml up -d

# ✅ ALWAYS USE THIS - atomic restart, Pi-hole back in seconds
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate

# ✅ OR USE THE WRAPPER SCRIPT
./scripts/restart-stack.sh
```

**If you lose internet:** Mobile hotspot → SSH to NAS IP → `docker compose up -d pihole`

---

## Documentation Strategy

- **Public docs** (tracked): Generic instructions with placeholders (`yourdomain.com`, `YOUR_NAS_IP`)
- **Private config** (`.claude/config.local.md`, gitignored): Actual hostnames, IPs, usernames
- **Credentials** (`.env`, gitignored): Passwords and tokens

**Always read `config.local.md`** for actual deployment values (domain, IPs, NAS hostname).

## Security

**NEVER commit secrets.** Use `${VAR_NAME}` references in compose files, real values in `.env` (gitignored).

Forbidden in tracked files: API keys, passwords, tokens, private keys, public IPs, email addresses.

## File Locations

| Location | Purpose |
|----------|---------|
| Git repo (local) | Development |
| Git repo (NAS: `/volume1/docker/arr-stack/`) | Deployment via `git pull` |

**Deployed via git**: `docker-compose.*.yml`, `traefik/`, `scripts/`, `.claude/instructions.md`
**Gitignored but required on NAS**: `.env` (manual setup), app data directories
**Not needed on NAS**: `docs/`, `.env.example` (but git pull includes them, harmless)

## Deployment Workflow

**The NAS has a git clone of this repo. Deploy via git, not file copy.**

```bash
# 1. Commit and push locally
git add -A && git commit -m "..." && git push

# 2. Pull on NAS
ssh <user>@<nas-host> "cd /volume1/docker/arr-stack && git pull"

# 3. Restart affected services
ssh <user>@<nas-host> "docker restart traefik"  # For routing changes
ssh <user>@<nas-host> "cd /volume1/docker/arr-stack && docker compose -f docker-compose.arr-stack.yml up -d"  # For compose changes
```

## NAS Access

**See `config.local.md` for hostname and username.**

**On any auth failure, immediately ask the user for credentials. Don't retry or guess.**

```bash
# Add user to docker group (one-time setup, avoids needing sudo for docker):
echo 'PASS' | sudo -S usermod -aG docker <user>
# Requires new SSH session to take effect

# SCP doesn't work on UGOS. Use stdin redirect (for rare cases):
sshpass -p 'PASS' ssh <user>@<nas-host> "cat > /path/file" < localfile

# If sudo is needed, pipe password:
sshpass -p 'PASS' ssh <user>@<nas-host> "echo 'PASS' | sudo -S <command>"

# Image updates need pull + recreate (restart keeps old image):
docker compose -f docker-compose.arr-stack.yml pull <service>
docker compose -f docker-compose.arr-stack.yml up -d <service>
```

## Service Networking

VPN services (Sonarr, Radarr, Prowlarr, qBittorrent, SABnzbd) use `network_mode: service:gluetun`.

| Route | Use |
|-------|-----|
| VPN → VPN (Sonarr/Radarr → qBittorrent) | `localhost` |
| Non-VPN → VPN (Jellyseerr → Sonarr) | `gluetun` |
| Any → Non-VPN (Any → Jellyfin) | container name |

**Download client config**: Sonarr/Radarr → qBittorrent: Host=`localhost`, Port=`8085`. SABnzbd: Host=`localhost`, Port=`8080`.

**CRITICAL: When restarting gluetun, always recreate ALL dependent services.** Docker stores the actual container ID at creation time. If gluetun is recreated but dependents aren't, they point to a stale/non-existent network namespace and `localhost` connections fail between them.

```bash
# WRONG - leaves dependent services attached to old gluetun
docker compose -f docker-compose.arr-stack.yml up -d gluetun

# RIGHT - recreate everything to ensure correct network attachment
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
```

If you see "Unable to connect" errors between VPN-routed services (e.g., Sonarr → qBittorrent), check network attachment:
```bash
docker inspect gluetun --format '{{.Id}}' | cut -c1-12  # Get current gluetun ID
docker inspect sonarr --format '{{.HostConfig.NetworkMode}}'  # Should match
```

## Traefik Routing

Routes defined in `traefik/dynamic/vpn-services.yml`, NOT Docker labels.

Docker labels are minimal (`traefik.enable=true`, `traefik.docker.network=arr-stack`). To add routes, edit `vpn-services.yml`.

**Remote vs Local-only services:**
- **Remote** (via Cloudflare Tunnel): Jellyfin, Jellyseerr, WireGuard, Traefik dashboard
- **Local-only** (NAS_IP:PORT or via WireGuard): Sonarr, Radarr, Prowlarr, qBittorrent, Bazarr, Pi-hole, Uptime Kuma, duc

Why local-only? These services default to "no login from local network". Cloudflare Tunnel traffic appears local, bypassing auth. Use Jellyseerr for remote media requests.

## Cloudflare Tunnel

Dashboard path: **Zero Trust → Networks → Connectors → Cloudflare Tunnels → [tunnel] → Configure → Published application routes**

All routes point to `<NAS_IP>:8080` (Traefik). Traefik routes by Host header. See `config.local.md` for actual IPs and tunnel name.

## Pi-hole DNS (v6+)

### ⚠️ CRITICAL: Pi-hole DNS Dependency

**If your router uses Pi-hole as DNS, stopping Pi-hole = total network DNS failure.**

This affects:
- All devices on the network (no internet)
- SSH connections using hostnames (use IP instead)
- Claude Code sessions (can't reach API)

**NEVER run `docker compose down` on arr-stack** - it stops Pi-hole and you lose DNS before you can run `up -d`. The `down` command also REMOVES containers, so UGOS Docker UI can't restart them.

```bash
# WRONG - stops Pi-hole, kills DNS, removes containers, you're stuck
docker compose -f docker-compose.arr-stack.yml down
docker compose -f docker-compose.arr-stack.yml up -d  # Can't run this - no DNS!

# RIGHT - single atomic command, Pi-hole restarts immediately
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate
```

### Emergency Recovery (Pi-hole Down)

If Pi-hole is down and you've lost DNS:

1. **Connect to mobile hotspot** (different network, uses mobile DNS)
2. **SSH to NAS using IP address** (not hostname):
   ```bash
   ssh <user>@<NAS_IP>  # e.g., ssh mooseadmin@10.10.0.10
   ```
3. **Start the stack**:
   ```bash
   cd /volume1/docker/arr-stack && docker compose -f docker-compose.arr-stack.yml up -d
   ```
4. **Wait 30 seconds**, reconnect to home WiFi - DNS restored

**Know your NAS IP!** Check `config.local.md` or your router's DHCP leases. Write it down somewhere accessible offline.

### Pi-hole Configuration

**⚠️ CRITICAL: Don't duplicate .lan domains**

Stack `.lan` domains are defined in `pihole/02-local-dns.conf` (dnsmasq config). User-specific domains can go in either:
- `02-local-dns.conf` (CLI)
- Pi-hole web UI (Local DNS → DNS Records) → writes to `pihole.toml`

**Never define the same domain in both places.** If both dnsmasq and pihole.toml define a domain with different IPs, resolution is unpredictable.

**Adding stack .lan domains** (use dnsmasq):
```bash
# On NAS - edit the config file
nano /volume1/docker/arr-stack/pihole/02-local-dns.conf

# Add your entry
address=/myservice.lan/10.10.0.XX

# Reload (or restart for bind-mount changes)
docker exec pihole pihole reloaddns
```

**TLDs**: `.local` fails in Docker (mDNS reserved). Use `.lan` for local DNS.

## Architecture

- **3 compose files**: traefik (infra), arr-stack (apps), cloudflared (tunnel)
- **Network**: arr-stack (172.20.0.0/24), static IPs for all services
- **External access**: Cloudflare Tunnel (bypasses CGNAT)

## Adding Services

1. Add to `docker-compose.arr-stack.yml` with static IP
2. Add route to `traefik/dynamic/vpn-services.yml`
3. If VPN-routed: use `network_mode: service:gluetun`
4. Sync compose + traefik config to NAS

## Service Notes

| Service | Note |
|---------|------|
| Pi-hole | v6 API uses password not separate token |
| Gluetun | VPN gateway. Services using it share IP 172.20.0.3. Uses Pi-hole DNS. `FIREWALL_OUTBOUND_SUBNETS` must include LAN for HA access |
| Cloudflared | SSL terminated at Cloudflare, Traefik receives HTTP |
| FlareSolverr | Cloudflare bypass for Prowlarr. Configure in Prowlarr: Settings → Indexers → add FlareSolverr with Host `flaresolverr.lan` |

## Container Updates

UGOS handles automatic updates natively (no Watchtower needed):
- **Docker → Management → Image update**
- Update detection: enabled
- Update as scheduled: weekly

## Backups

### Prerequisites

**USB drive mounted at `/mnt/arr-backup`** for automated backups. Without it, backups stay in `/tmp` (cleared on reboot).

### Automated Daily Backup (6am)

Cron runs daily at 6am:
```
0 6 * * * /volume1/docker/arr-stack/scripts/backup-volumes.sh --tar /mnt/arr-backup >> /var/log/arr-backup.log 2>&1
```

**How it works:**
1. Creates backup in `/tmp` first (reliable space)
2. Creates tarball (~13MB)
3. Checks actual tarball size vs USB space
4. Moves to USB only if space available
5. Falls back to `/tmp` with warning if USB full
6. EXIT trap ensures services stay running no matter what

**Does NOT stop services** - safe live backup. Keeps 7 days on USB.

### Manual Backup / Pull to Local

```bash
# Run backup manually on NAS
ssh <user>@<nas-host> "cd /volume1/docker/arr-stack && ./scripts/backup-volumes.sh --tar"

# Pull from /tmp to local repo (gitignored backups/ folder)
ssh <user>@<nas-host> "cat /tmp/arr-stack-backup-*.tar.gz" > backups/arr-stack-backup-$(date +%Y%m%d).tar.gz

# Or pull from USB drive
ssh <user>@<nas-host> "cat /mnt/arr-backup/arr-stack-backup-*.tar.gz" > backups/arr-stack-backup-$(date +%Y%m%d).tar.gz
```

### What's Backed Up

**Included** (~13MB compressed): gluetun, qbittorrent, prowlarr, bazarr, wireguard, uptime-kuma, pihole-dnsmasq, jellyseerr, sabnzbd configs.

**Excluded** (regeneratable): jellyfin-config (407MB), sonarr (43MB), radarr (110MB), pihole blocklists (138MB).

## Uptime Kuma SQLite

**Query monitors:**
```bash
docker exec uptime-kuma sqlite3 /app/data/kuma.db "SELECT id, name, url FROM monitor"
```

**Update monitor URL:**
```bash
docker exec uptime-kuma sqlite3 /app/data/kuma.db "UPDATE monitor SET url='http://NEW_URL' WHERE id=ID"
docker restart uptime-kuma
```

**Add monitors:**

**CRITICAL: Always include `user_id=1` - monitors without it won't appear in the UI!**

```bash
docker exec uptime-kuma sqlite3 /app/data/kuma.db "INSERT INTO monitor (name, type, url, interval, accepted_statuscodes_json, ignore_tls, active, maxretries, user_id) VALUES ('Service Name', 'http', 'http://url', 60, '[\"200-299\"]', 0, 1, 3, 1);"
docker restart uptime-kuma
```

For HTTPS with self-signed cert or 401 auth page: `ignore_tls=1`, `accepted_statuscodes_json='[\"200-299\",\"401\"]'`

**Note:** Services using `network_mode: service:gluetun` (qBittorrent, Sonarr, etc.) should use Gluetun's static IP (`172.20.0.3`) in Uptime Kuma, not the hostname.

## Bash Script Gotchas

**SSH command substitution with `set -e`**: When using `set -e` (exit on error), command substitution causes script exit if the command fails. Add `|| true` to prevent this:

```bash
# WRONG - script exits if SSH fails
result=$(ssh_to_nas "some command")

# RIGHT - gracefully handle SSH failure
result=$(ssh_to_nas "some command") || true
if [[ -z "$result" ]]; then
    echo "SKIP: SSH failed"
    return 0
fi
```

This pattern is used in `scripts/lib/check-env-backup.sh` and `check-uptime-monitors.sh`.

## Custom .lan Domains (User-Specific Services)

To add `.lan` domains for services outside this stack (e.g., Frigate, Home Assistant):

**1. Add DNS entry** (gitignored `pihole/02-local-dns.conf`):
```
address=/frigate.lan/TRAEFIK_LAN_IP
```

**2. Add Traefik route** (create `traefik/dynamic/my-services.local.yml` - gitignored):
```yaml
http:
  routers:
    frigate-lan:
      rule: "Host(`frigate.lan`)"
      entryPoints: [web]
      service: frigate-lan

  services:
    frigate-lan:
      loadBalancer:
        servers:
          - url: "http://172.20.0.30:5000"
```

**3. Deploy**:
```bash
# On NAS - reload Pi-hole DNS
docker exec pihole pihole restartdns
# Traefik picks up *.local.yml automatically
```

**Requirement**: Service must be on `arr-stack` network with a static IP.

## .env Gotchas

**Bcrypt hashes must be quoted** (they contain `$` which Docker interprets as variables):
```bash
# Wrong
TRAEFIK_DASHBOARD_AUTH=admin:$2y$05$abc...

# Correct
TRAEFIK_DASHBOARD_AUTH='admin:$2y$05$abc...'
```

## Troubleshooting: SABnzbd Stuck Downloads

If a movie/show shows "Downloading" in Radarr at 100% but has 0 B file size:

1. Check for `_UNPACK_*` directory buildup in `/volume1/Media/downloads/` — each is a failed unpack retry wasting 20-50 GB
2. The actual completed file is usually in `/volume1/Media/downloads/incomplete/<release>/` with an obfuscated filename
3. SABnzbd UI/API will likely be unresponsive (locked by the post-processing loop)
4. Fix: `docker stop sabnzbd` → delete `postproc2.sab` from admin dir → delete `_UNPACK_*` dirs → move file to movie folder → `docker start sabnzbd` → clear Radarr queue → trigger RefreshMovie
5. Key lesson: the SABnzbd history API delete does NOT clear the postproc queue — must delete `postproc2.sab` while stopped
6. See `docs/TROUBLESHOOTING.md` for full step-by-step

**SABnzbd API** (via container): `http://localhost:8080/api?apikey=KEY&mode=history&output=json`
**Radarr API** (via container): `http://localhost:7878/api/v3/...?apikey=KEY`

## GitHub Releases

**⚠️ CRITICAL: Always update CHANGELOG.md when creating a release.**

Update `CHANGELOG.md` BEFORE creating the GitHub release. The changelog is the permanent record; GitHub releases can change but the changelog is in the repo.

When creating release notes:
- Link to `docs/UPGRADING.md` for upgrade instructions instead of inline steps
- Keep notes concise - bullet points, not paragraphs
- Don't mention Reddit/community feedback as motivation for changes

**⚠️ CRITICAL: Force-pushing a tag resets the GitHub release to Draft status.**

When updating a release tag to a new commit:
```bash
# Move tag to new commit
git tag -d v1.x && git tag v1.x
git push origin :refs/tags/v1.x && git push origin v1.x

# REQUIRED: Fix the release status (force-push sets it to Draft)
gh release edit v1.x --draft=false --latest
```

**Always run `gh release edit` after force-pushing a tag.** Without it, the release stays Draft and won't show as Latest.
