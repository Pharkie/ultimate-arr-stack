# Setup Guide

Everything you need to go from zero to streaming. Works on any NAS or Docker host.

## Table of Contents

- [Choose Your Setup](#choose-your-setup)
- [Requirements](#requirements)
- [Stack Overview](#stack-overview)
- [Step 1: Create Directories and Clone/Fork Repository](#step-1-create-directories-and-clonefork-repository)
- [Step 2: Edit Your Settings](#step-2-edit-your-settings)
- [Step 3: Start the Stack](#step-3-start-the-stack)
- [Step 4: Configure Each App](#step-4-configure-each-app)
- [Step 5: Check It Works](#step-5-check-it-works)
- [+ local DNS (.lan domains)](#-local-dns-lan-domains--optional)
- [+ remote access](#-remote-access--optional)
- [Backup](#backup)
- [Optional Utilities](#optional-utilities)

---

## Choose Your Setup

Decide how you'll access your media stack:

| Setup | How you access | What to configure | Good for |
|-------|----------------|-------------------|----------|
| **Core** | `192.168.1.50:8096` | Just `.env` + VPN credentials | Testing, single user |
| **+ local DNS** | `jellyfin.lan` | Configure Pi-hole + add Traefik | Home/family use |
| **+ remote access** | `jellyfin.yourdomain.com` | Add Cloudflare Tunnel | Watch/request from anywhere |

**You can start simple and add features later.** The guide has checkpoints so you can stop at any level.

---

## Requirements

### Hardware
- **NAS** (Ugreen, Synology, QNAP, etc.) or any Linux server/Raspberry Pi 4+
- Minimum 4GB RAM (8GB+ recommended)
- Storage for media files

### Software & Services
- **Docker** - Preinstalled on UGOS; one-click install from app store on Synology/QNAP
  <details>
  <summary><strong>New to Docker?</strong></summary>

  **Docker** runs applications in isolated "containers" - like lightweight virtual machines. Each service (Jellyfin, Sonarr, etc.) runs in its own container.

  **Docker Compose** lets you define multiple containers in a single file (`docker-compose.yml`) and start them all with one command. Instead of typing out dozens of options for each container, you just run `docker compose up -d`.

  This stack uses Docker Compose because it has 10+ services that need to work together. The compose file defines how they're connected, what ports they use, and where they store data.

  </details>
- **SSH access** to your NAS (enable in NAS settings)
- **VPN Subscription** - Any provider supported by [Gluetun](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers) (Surfshark, NordVPN, PIA, Mullvad, ProtonVPN, etc.)
- **Usenet Provider** (optional, ~$4-6/month) - Frugal Usenet, Newshosting, Eweka, etc.
- **Usenet Indexer** (optional) - NZBGeek (~$12/year) or DrunkenSlug (free tier)

> **Why Usenet?** More reliable than public torrents (no fakes), faster downloads, SSL-encrypted (no VPN needed). See [SABnzbd setup](APP-CONFIG.md#43-sabnzbd-usenet-downloads).

**For + remote access:**
- **Domain name** (~$10/year) - [Cloudflare Registrar](https://www.cloudflare.com/products/registrar/) recommended
- **Cloudflare account** (free tier)

---

## Stack Overview

### What Each Component Does

| Component | What it does | Which setup? |
|-----------|--------------|--------------|
| **Seerr** | Request portal - users request shows/movies here | Core |
| **Jellyfin** | Media player - like Netflix but for your own content | Core |
| **Sonarr** | TV show manager - searches for episodes, sends to download client | Core |
| **Radarr** | Movie manager - searches for movies, sends to download client | Core |
| **Prowlarr** | Indexer manager - finds download sources for Sonarr/Radarr | Core |
| **qBittorrent** | Torrent client - downloads files (through VPN) | Core |
| **SABnzbd** | Usenet client - downloads files via SSL (optional, for Usenet users) | Core |
| **Bazarr** | Subtitle manager - finds and syncs subtitles for your library | Core |
| **Gluetun** | VPN container - routes download traffic through VPN so your ISP can't see what you download | Core |
| **Pi-hole** | DNS server - blocks ads, provides Docker DNS | Core |
| **Traefik** | Reverse proxy - enables `.lan` domains | + local DNS |
| **Cloudflared** | Tunnel to Cloudflare - secure remote access without port forwarding | + remote access |

### Files You Need To Edit

**Core:**
- `.env` - Media path, timezone, PUID/PGID, VPN credentials

**+ local DNS:**
- `.env` - Add NAS IP, Pi-hole password, Traefik macvlan settings

**+ remote access:**
- `.env` - Add domain, Traefik dashboard auth
- `traefik/dynamic/vpn-services.yml` - Replace `yourdomain.com`

**Files you DON'T edit:**
- `docker-compose.*.yml` - Work as-is, configured via `.env`
- `pihole/02-local-dns.conf` - Generated from example via sed command
- `traefik/dynamic/tls.yml` - Security defaults
- `traefik/dynamic/local-services.yml` - Auto-generates from `.env`

### Docker Compose Files

| File | Purpose | Which setup? |
|------|---------|--------------|
| `docker-compose.arr-stack.yml` | Core media stack (Jellyfin, *arr apps, downloads, VPN) | Core |
| `docker-compose.traefik.yml` | Reverse proxy for .lan domains and external access | + local DNS |
| `docker-compose.cloudflared.yml` | Secure tunnel to Cloudflare (no port forwarding) | + remote access |
| `docker-compose.utilities.yml` | Monitoring, auto-recovery, disk usage | Utilities (optional) |

See [Quick Reference](REFERENCE.md) for full service lists, .lan URLs, and network details.

<details>
<summary><strong>Prefer Plex over Jellyfin?</strong></summary>

This stack uses Jellyfin, but you can swap to Plex by modifying `docker-compose.arr-stack.yml`:

1. **Replace the Jellyfin service** with Plex (`lscr.io/linuxserver/plex`), port `32400`, and add `PLEX_CLAIM` env var (get from https://plex.tv/claim)
2. **Replace the Seerr service** with Overseerr if preferred (Seerr supports both Jellyfin and Plex)
3. **Update volumes**: `jellyfin-config`/`jellyfin-cache` → `plex-config`
4. **Update Traefik routes**: `jellyfin.lan`/`jellyfin.yourdomain.com` → `plex.lan`/`plex.yourdomain.com`, point to port `32400`
5. **Update Pi-hole DNS**: add `plex.lan` entry
6. **Remove hardware transcoding** lines (`devices`, `group_add`) unless you configure Plex hardware transcoding separately

This is not tested or supported — you're on your own.

</details>

---

## Step 1: Create Directories and Clone/Fork Repository

First, set up the folder structure for your media and get the files from this GitHub repo onto your NAS.

**Fork first (recommended):** Click "Fork" on GitHub, then clone your fork. This lets you add your own services, customise configs, and pull upstream updates when you want them.

> **Just want to try it?** You can clone this repo directly instead of forking. You'll still get updates via `git pull`, but can't push your own changes.

<details>
<summary><strong>Ugreen NAS (UGOS)</strong></summary>

Docker comes preinstalled on UGOS - no installation needed! Folders created via SSH don't appear in UGOS Files app, so create top-level folders via GUI.

1. Open UGOS web interface → **Files** app
2. Create shared folders: **data**, **docker**
3. Inside **data**, create subfolder: **media**, then inside **media** create **tv** and **movies**
4. Enable SSH: **Control Panel** → **Terminal** → toggle SSH on
5. SSH into your NAS and create download directories + install git:

```bash
ssh your-username@nas-ip

# Install git (Ugreen NAS uses Debian)
sudo apt-get update && sudo apt-get install -y git

# Create media and download directories
sudo mkdir -p /volume1/data/media/{tv,movies}
sudo mkdir -p /volume1/data/torrents/{tv,movies}
sudo mkdir -p /volume1/data/usenet/{incomplete,complete/{tv,movies}}
sudo chown -R 1000:1000 /volume1/data/media /volume1/data/torrents /volume1/data/usenet

# Clone the repo
cd /volume1/docker
sudo git clone https://github.com/Pharkie/ultimate-arr-stack.git arr-stack  # or your fork
sudo chown -R 1000:1000 /volume1/docker/arr-stack
```

**Note:** Use `sudo` for Docker commands on Ugreen NAS. Service configs are stored in Docker named volumes (auto-created on first run).

<details>
<summary><strong>Antivirus tip</strong></summary>

UGOS has a built-in antivirus scanner that runs scheduled scans. The default settings can scan your entire data folder, taking 40-50+ hours and causing system slowdowns. To fix:
1. Open **Security** app → **Scheduled Scan**
2. Remove `/volume1/data` from the scan targets
3. Change frequency from daily to weekly
4. Under "Scan file types", select **Specific** and uncheck **Multimedia Data**

Scanning media files for viruses is unnecessary - video/audio files can't contain executable malware.

</details>

</details>

<details>
<summary><strong>Synology / QNAP</strong></summary>

Use File Station to create:
- **data** shared folder with subfolder: **media** (containing **tv** and **movies**)
- **docker** shared folder

Then via SSH:
```bash
ssh your-username@nas-ip

# Install git if not present (Synology)
sudo synopkg install Git

# Create media and download directories
sudo mkdir -p /volume1/data/media/{tv,movies}
sudo mkdir -p /volume1/data/torrents/{tv,movies}
sudo mkdir -p /volume1/data/usenet/{incomplete,complete/{tv,movies}}
sudo chown -R 1000:1000 /volume1/data/media /volume1/data/torrents /volume1/data/usenet

# Clone the repo
cd /volume1/docker
sudo git clone https://github.com/Pharkie/ultimate-arr-stack.git arr-stack  # or your fork
sudo chown -R 1000:1000 /volume1/docker/arr-stack
```

</details>

<details>
<summary><strong>Linux Server / Generic</strong></summary>

```bash
# Install git if needed
sudo apt-get update && sudo apt-get install -y git

# Create media and download directories
sudo mkdir -p /srv/data/media/{tv,movies}
sudo mkdir -p /srv/data/torrents/{tv,movies}
sudo mkdir -p /srv/data/usenet/{incomplete,complete/{tv,movies}}
sudo chown -R 1000:1000 /srv/data

# Clone the repo
cd /srv/docker
sudo git clone https://github.com/Pharkie/ultimate-arr-stack.git arr-stack  # or your fork
sudo chown -R 1000:1000 /srv/docker/arr-stack
```

**Note:** Adjust paths in docker-compose files if using different locations. Service configs are stored in Docker named volumes (auto-created on first run).

</details>

### Expected Structure

```
/volume1/  (or /srv/)
├── data/
│   ├── media/                # Library files (TRaSH recommended)
│   │   ├── movies/           #   Movie library (Radarr → Jellyfin)
│   │   └── tv/               #   TV show library (Sonarr → Jellyfin)
│   ├── torrents/             # qBittorrent downloads
│   │   ├── tv/               #   Sonarr category
│   │   └── movies/           #   Radarr category
│   └── usenet/               # SABnzbd downloads
│       ├── incomplete/       #   In-progress downloads
│       └── complete/         #   Completed downloads
│           ├── tv/           #   Sonarr category
│           └── movies/       #   Radarr category
└── docker/
    └── arr-stack/
        ├── traefik/              # + local DNS / + remote access only
        │   ├── traefik.yml
        │   └── dynamic/
        │       └── vpn-services.yml
        └── cloudflared/          # + remote access only
            └── config.yml
```

> Only `traefik/` and `cloudflared/` appear as folders on your NAS. Everything else is managed by Docker internally.
>
> **Why this structure?** All media directories live under one `MEDIA_ROOT`, mounted as a single `/data` volume in containers that need both downloads and library access (qBittorrent, SABnzbd, Sonarr, Radarr). This enables **hardlinks** — when Sonarr/Radarr import a file, they create a hardlink instead of copying, making imports instant and using zero extra disk space. See [TRaSH Guides: Hardlinks](https://trash-guides.info/Hardlinks/Hardlinks-and-Instant-Moves/).

---

## Step 2: Edit Your Settings

The stack needs your media path, timezone, VPN credentials, and a few passwords. Everything goes in one `.env` file.

> **Note:** From this point forward, all commands run **on your NAS via SSH**. If you closed your terminal, reconnect with `ssh your-username@nas-ip` and `cd /volume1/docker/arr-stack` (or your clone location). **UGOS users:** SSH may time out—re-enable in Control Panel → Terminal if needed.

### 2.1 Copy the Main Configuration File

```bash
cp .env.example .env
```

### 2.2 Media Storage Path

Set `MEDIA_ROOT` in `.env` to match your media folder location:

```bash
# Examples:
MEDIA_ROOT=/volume1/data      # Ugreen, Synology
MEDIA_ROOT=/share/data        # QNAP
MEDIA_ROOT=/srv/data          # Linux server
```

Containers run as the user specified by PUID/PGID. This must match who owns your media folders:

```bash
# SSH to NAS, then run:
ls -ln /volume1/       # Shows folder owners as numbers (UID/GID)
id                     # Shows YOUR user's UID/GID - these should match
```

If wrong, you'll see errors like "Folder '/tv/' is not writable by user 'abc'" in Sonarr/Radarr.

### 2.3 Timezone

Set your timezone (used for scheduling, logs, and UI times):

```bash
TZ=Europe/London              # Find yours: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones
```

### 2.4 Configure VPN

Add your VPN credentials to `.env`. Gluetun supports 30+ providers—find yours below:

<details>
<summary><strong>Surfshark (WireGuard)</strong></summary>

| Step | Screenshot |
|:-----|:-----------|
| 1. Go to [my.surfshark.com](https://my.surfshark.com/) → VPN → Manual Setup → Router → WireGuard | <img src="images/Surfshark/1.png" width="700"> |
| 2. Select **"I don't have a key pair"** | <img src="images/Surfshark/2.png" width="700"> |
| 3. Under Credentials, enter a name (e.g., `ugreen-nas`) | <img src="images/Surfshark/3.png" width="700"> |
| 4. Click **"Generate a new key pair"** and copy both keys to your notes | <img src="images/Surfshark/4.png" width="700"> |
| 5. Click **"Choose location"** and select a server (e.g., United Kingdom) | <img src="images/Surfshark/5.png" width="700"> |
| 6. Click the **Download** arrow to get the `.conf` file | <img src="images/Surfshark/6.png" width="700"> |

7. Open the downloaded `.conf` file and note the `Address` and `PrivateKey` values:
   ```ini
   [Interface]
   Address = 10.14.0.2/16
   PrivateKey = aBcDeFgHiJkLmNoPqRsTuVwXyZ...
   ```

8. Edit `.env`:
   ```bash
   VPN_SERVICE_PROVIDER=surfshark
   VPN_TYPE=wireguard
   WIREGUARD_PRIVATE_KEY=your_private_key_here
   WIREGUARD_ADDRESSES=10.14.0.2/16
   VPN_COUNTRIES=United Kingdom
   ```

> **Note:** `VPN_COUNTRIES` in your `.env` maps to Gluetun's `SERVER_COUNTRIES` env var.

</details>

<details>
<summary><strong>Other Providers (NordVPN, PIA, Mullvad, etc.)</strong></summary>

See the Gluetun wiki for your provider:
- [NordVPN](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/nordvpn.md)
- [Private Internet Access](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md)
- [Mullvad](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/mullvad.md)
- [ProtonVPN](https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md)
- [All providers](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)

Update `.env` with your provider's required variables.

</details>

> **Don't want Pi-hole?** Change `DNS_ADDRESS=172.20.0.5` to your preferred public DNS (e.g., `1.1.1.1`, `8.8.8.8`) in `docker-compose.arr-stack.yml`.

### 2.5 Create Passwords

**Pi-hole Password:**

> **Static IP required:** Pi-hole binds its DNS listener to `NAS_IP` at boot. Your NAS **must** have a static IP that matches `NAS_IP` in `.env`. If the IP comes from DHCP, Docker may start before it's assigned and Pi-hole will fail. Check with `ip addr show eth0` — if you see `dynamic`, configure a static IP first. See [Troubleshooting](TROUBLESHOOTING.md#pi-hole-doesnt-start-after-reboot) if Pi-hole fails after reboot.

Invent a password. Or, to generate a random one:
```bash
openssl rand -base64 24
```
Edit `.env`: `PIHOLE_UI_PASS=your_password`

**For + remote access: Traefik Dashboard Auth**

Invent a password for the Traefik dashboard and note it down, then generate the auth string:
```bash
docker run --rm httpd:alpine htpasswd -nbB admin 'your_chosen_password'
```
Copy the output to `.env`, wrapping in single quotes to protect the `$` characters:
```
TRAEFIK_DASHBOARD_AUTH='admin:$2y$05$...'
```

---

## Step 3: Start the Stack

Time to launch your containers and verify everything connects properly.

### 3.1 Deploy

```bash
# Create empty config file (+ local DNS users will overwrite this later)
touch pihole/02-local-dns.conf

docker compose -f docker-compose.arr-stack.yml up -d
```

> **Port 1900 conflict?** If you get "address already in use" for port 1900, your NAS's built-in media server is using it. Comment out `- "1900:1900/udp"` in the Jellyfin section of the compose file. Jellyfin works fine without it (only affects smart TV auto-discovery).

### 3.2 Verify Deployment

```bash
# Check all containers are running
docker ps

# Check VPN connection (should show a VPN IP and location)
docker logs gluetun 2>&1 | grep "Public IP address" | tail -1

```

---

## Step 4: Configure Each App

Your stack is running! Now configure each app to work together.

Choose your path:
- **Recommended:** [Script-Assisted Setup](APP-CONFIG-QUICK.md) (~5 min — script handles most of it)
- **Manual:** [Full Manual Setup](APP-CONFIG.md) (~30 min — configure everything through the UI)

Both guides walk you through creating accounts, connecting services, and adding your indexers — step by step.

---

## Step 5: Check It Works

Time to verify everything is connected and protected before you start adding content.

### VPN Test

> **⚠️ Do this before downloading anything.** If your VPN isn't working, your real IP will be exposed to trackers.

Run on NAS via SSH:
```bash
docker exec gluetun wget -qO- https://ipinfo.io/ip       # Should show VPN IP, not your home IP
docker exec qbittorrent wget -qO- https://ipinfo.io/ip   # Same - confirms qBit uses VPN
```

**Thorough test:** Visit [ipleak.net](https://ipleak.net) from your browser, then run the same test from inside qBittorrent:
```bash
docker exec qbittorrent wget -qO- https://ipleak.net/json
```
Compare the IPs — qBittorrent should show your VPN's IP, not your home IP.

### Service Integration Test
1. Sonarr/Radarr: Settings → Download Clients → Test
2. Add a TV show or movie (noting legal restrictions) → verify it appears in qBittorrent
3. After download completes → verify it moves to library
4. Jellyfin → verify media appears in library

---

## ✅ Core Complete!

Your media stack is fully configured. The two services you'll use most:

- **Seerr** — `http://NAS_IP:5055` — Request new shows and movies
- **Jellyfin** — `http://NAS_IP:8096` — Watch your media library

> Replace `NAS_IP` with your NAS's IP address (e.g., `192.168.1.50`). For all service URLs, ports, and network details, see [Quick Reference](REFERENCE.md).

**Try it out:** Open Seerr, request a show or movie, then watch it download in Sonarr/Radarr and appear in Jellyfin.

**What's next?**
- **Stop here** if IP:port access is fine for you
- **Continue to [+ local DNS](#-local-dns-lan-domains--optional)** for friendly `.lan` URLs (e.g., `http://jellyfin.lan`) and remote access

---

## + local DNS (.lan domains) — Optional

Access services by name (`http://sonarr.lan`) instead of port numbers. Requires Pi-hole + Traefik.

**[→ Local DNS setup guide](LOCAL-DNS.md)**

---

## + remote access — Optional

Watch and request media from anywhere via `jellyfin.yourdomain.com`. Requires a domain + Cloudflare Tunnel.

**[→ Remote access setup guide](REMOTE-ACCESS.md)**

---

## Backup

Service configs are stored in Docker named volumes. Run periodic backups:

```bash
./scripts/arr-backup.sh --tar
```

Creates a ~13MB tarball of essential configs (VPN settings, indexers, request history, etc.).

See **[Backup & Restore](BACKUP.md)** for full details on what's backed up, restore procedures, and automation.

---

## Optional Utilities

Deploy monitoring, auto-recovery, and disk usage tools.

**[→ Utilities setup guide](UTILITIES.md)**

---

## Adding More Services (Core)

Other *arr apps you can add to your Core stack:

- **Lidarr** - Music (port 8686)
- **Readarr** - Ebooks (port 8787)

<details>
<summary>Example: Adding Lidarr</summary>

1. Add to `docker-compose.arr-stack.yml` volumes section:
   ```yaml
   lidarr-config:
   ```

2. Add port to gluetun:
   ```yaml
   - "8686:8686"   # Lidarr
   ```

3. Add the service:
   ```yaml
   lidarr:
     image: lscr.io/linuxserver/lidarr:latest
     container_name: lidarr
     network_mode: "service:gluetun"
     depends_on:
       gluetun:
         condition: service_healthy
     environment:
       - PUID=${PUID}
       - PGID=${PGID}
       - TZ=${TZ}
     volumes:
       - lidarr-config:/config
       - ${MEDIA_ROOT}:/data
     restart: unless-stopped
   ```

4. Redeploy: `docker compose -f docker-compose.arr-stack.yml up -d`

5. **(+ local DNS)** Add `.lan` domain:
   ```bash
   # Add to pihole/02-local-dns.conf
   echo "address=/lidarr.lan/TRAEFIK_LAN_IP" >> pihole/02-local-dns.conf

   # Add Traefik route to traefik/dynamic/local-services.yml
   # (router + service, see existing entries as template)

   # Restart Pi-hole to pick up bind-mount changes (reloaddns alone is NOT enough)
   docker restart pihole
   ```

</details>

---

## Further Reading

- [TRaSH Guides](https://trash-guides.info/) — Quality profiles, naming conventions, and best practices for Sonarr, Radarr, and more

---

Issues? [Report on GitHub](https://github.com/Pharkie/ultimate-arr-stack/issues) or [chat on Reddit](https://www.reddit.com/user/Jeff46K4/).
