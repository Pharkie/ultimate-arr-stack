# Setup Guide

Complete setup guide for the media automation stack. Works on any Docker host with platform-specific notes in collapsible sections.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Step 1: Create Directories and Clone/Fork Repository](#step-1-create-directories-and-clonefork-repository)
- [Step 2: Configure Environment](#step-2-configure-environment)
- [Step 3: External Access (Optional)](#step-3-external-access-optional)
- [Step 4: Deploy Services](#step-4-deploy-services)
- [Step 5: Configure Services](#step-5-configure-services)
- [Step 6: Test](#step-6-test)
- [Backup](#backup)
- [Optional Utilities](#optional-utilities)

**See also:** [Quick Reference](REFERENCE.md) · [Updating the Stack](UPDATING.md) · [Home Assistant Integration](HOME-ASSISTANT.md)

---

## Prerequisites

### Hardware
- Docker host (NAS, server, Raspberry Pi 4+, etc.)
- Minimum 4GB RAM (8GB+ recommended)
- Storage for media files
- Support for `/dev/net/tun` (for VPN)

### Software
- Docker Engine 20.10+
- Docker Compose v2.0+
- Git (for deployment)
- SSH access to your host

### Required Services
- **VPN Subscription** - Any provider supported by [Gluetun](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers) (Surfshark, NordVPN, PIA, Mullvad, ProtonVPN, etc.)

### For remote access (optional)
- **Domain Name** (~$8-10/year)
- **Cloudflare Account** (free tier)

---

## Step 1: Create Directories and Clone/Fork Repository

Create media folders and get the repository onto your Docker host.

**Clone or Fork?**
- **Clone** (simpler): Just want to use the stack, pull updates occasionally
- **Fork** (recommended): Plan to add your own services (e.g., Audiobookshelf, Nextcloud), want to contribute improvements back, or keep your own version

To fork: Click "Fork" on GitHub, then clone your fork instead of this repo.

<details>
<summary><strong>Ugreen NAS (UGOS)</strong></summary>

Folders created via SSH don't appear in UGOS Files app. Create top-level folders via GUI for visibility.

1. Open UGOS web interface → **Files** app
2. Create shared folders: **Media**, **docker**
3. Inside **Media**, create subfolders: **downloads**, **tv**, **movies**
4. Via SSH, install git and clone:

```bash
ssh your-username@nas-ip

# Install git (Ugreen NAS uses Debian)
sudo apt-get update && sudo apt-get install -y git

# Clone the repo
cd /volume1/docker
sudo git clone https://github.com/Pharkie/arr-stack-ugreennas.git arr-stack  # or your fork
sudo chown -R 1000:1000 /volume1/docker/arr-stack

# Prepare Traefik certificate storage
sudo touch /volume1/docker/arr-stack/traefik/acme.json
sudo chmod 600 /volume1/docker/arr-stack/traefik/acme.json
```

**Note:** Use `sudo` for Docker commands on Ugreen NAS. Service configs are stored in Docker named volumes (auto-created on first run).

</details>

<details>
<summary><strong>Synology / QNAP</strong></summary>

Use File Station to create:
- **Media** shared folder with subfolders: downloads, tv, movies
- **docker** shared folder

Then via SSH:
```bash
ssh your-username@nas-ip

# Install git if not present (Synology)
sudo synopkg install Git

# Clone the repo
cd /volume1/docker
sudo git clone https://github.com/Pharkie/arr-stack-ugreennas.git arr-stack  # or your fork
sudo chown -R 1000:1000 /volume1/docker/arr-stack

# Prepare Traefik certificate storage
sudo touch /volume1/docker/arr-stack/traefik/acme.json
sudo chmod 600 /volume1/docker/arr-stack/traefik/acme.json
```

</details>

<details>
<summary><strong>Linux Server / Generic</strong></summary>

```bash
# Install git if needed
sudo apt-get update && sudo apt-get install -y git

# Create media directories
sudo mkdir -p /srv/media/{downloads,tv,movies}
sudo chown -R 1000:1000 /srv/media

# Clone the repo
cd /srv/docker
sudo git clone https://github.com/Pharkie/arr-stack-ugreennas.git arr-stack  # or your fork
sudo chown -R 1000:1000 /srv/docker/arr-stack

# Prepare Traefik certificate storage
sudo touch /srv/docker/arr-stack/traefik/acme.json
sudo chmod 600 /srv/docker/arr-stack/traefik/acme.json
```

**Note:** Adjust paths in docker-compose files if using different locations. Service configs are stored in Docker named volumes (auto-created on first run).

</details>

> **Note:** From this point forward, all commands should be run **on your NAS via SSH** unless otherwise noted. If you closed your terminal, reconnect with `ssh your-username@nas-ip` and `cd` to your deployment directory.

### Expected Structure

```
/volume1/  (or /srv/)
├── Media/
│   ├── downloads/    # qBittorrent downloads
│   ├── tv/           # TV shows (Sonarr → Jellyfin)
│   └── movies/       # Movies (Radarr → Jellyfin)
└── docker/
    └── arr-stack/
        ├── traefik/              # User-edited config (bind mount)
        │   ├── traefik.yml
        │   ├── acme.json         # SSL certificates (chmod 600)
        │   └── dynamic/
        │       └── tls.yml
        └── cloudflared/          # User-edited config (bind mount)
            └── config.yml
```

> **Note:** Service data (Sonarr, Radarr, Jellyfin, etc.) is stored in Docker named volumes, automatically managed by Docker. Only `traefik/` and `cloudflared/` are local directories for user-edited configuration.

---

## Step 2: Configure Environment

### 2.1 Copy Template

```bash
cp .env.example .env
```

### 2.2 VPN Configuration

Gluetun supports 30+ VPN providers. Configuration varies by provider.

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

7. Open the downloaded `.conf` file and note the `Address` value:
   ```ini
   [Interface]
   Address = 10.14.0.2/16          ← Copy this
   PrivateKey = (already copied)
   ```

8. Add to `.env`:
   ```bash
   VPN_SERVICE_PROVIDER=surfshark
   VPN_TYPE=wireguard
   WIREGUARD_PRIVATE_KEY=your_private_key_here
   WIREGUARD_ADDRESSES=10.14.0.2/16
   VPN_COUNTRIES=United Kingdom
   ```

> **Note:** `VPN_COUNTRIES` in your `.env` maps to Gluetun's `SERVER_COUNTRIES` env var (a fixed name we can't change). We use the clearer name in `.env`.

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

### 2.3 Service Passwords

**Pi-hole Password:**

Invent a password. Or, to generate a random one:
```bash
openssl rand -base64 24
```
Add to `.env`: `PIHOLE_UI_PASS=your_password`

**WireGuard Password Hash** (for remote VPN access):

Invent a password for the WireGuard admin UI and note it down, then generate its hash:
```bash
docker run --rm ghcr.io/wg-easy/wg-easy wgpw 'your_chosen_password'
```
Copy the `$2a$12$...` hash output and add to `.env`:
```bash
WG_PASSWORD_HASH=$2a$12$your_generated_hash
```

**Traefik Dashboard Auth** (if using external access):

Invent a password for the Traefik dashboard and note it down, then generate the auth string:
```bash
docker run --rm httpd:alpine htpasswd -nb admin 'your_chosen_password' | sed -e s/\\$/\\$\\$/g
```
Add the output to `.env`: `TRAEFIK_DASHBOARD_AUTH=admin:$$apr1$$...`

**Important:** The `.env` file contains secrets - never commit it to git.

---

## Step 3: External Access (Optional)

For local-only access, skip this section and use URLs like `http://NAS_IP:8096`.

<details>
<summary><strong>Option A: Cloudflare Tunnel (Recommended)</strong></summary>

Cloudflare Tunnel connects outbound from your server, bypassing port forwarding and ISP restrictions. This setup uses the CLI and a local config file (not the Cloudflare web dashboard) for wildcard DNS routing - only 2 DNS records for all services.

**1. Login to Cloudflare (run on NAS via SSH):**

```bash
cd /volume1/docker/arr-stack
mkdir -p cloudflared && chmod 777 cloudflared
docker run --rm -v ./cloudflared:/home/nonroot/.cloudflared cloudflare/cloudflared tunnel login
```

This prints a URL. Open it in your browser, select your domain, and authorize. The running cloudflared process receives the cert via callback and saves it automatically (the browser shouldn't offer any download).

**2. Create the tunnel:**

```bash
docker run --rm -v ./cloudflared:/home/nonroot/.cloudflared cloudflare/cloudflared tunnel create nas-tunnel
```

Note the tunnel ID (e.g., `6271ac25-f8ea-4cd3-b269-ad9778c61272`).

**3. Rename credentials and create config:**

```bash
# Rename credentials file
mv cloudflared/*.json cloudflared/credentials.json

# Create config (replace TUNNEL_ID and DOMAIN)
cat > cloudflared/config.yml << 'EOF'
tunnel: YOUR_TUNNEL_ID
credentials-file: /home/nonroot/.cloudflared/credentials.json

ingress:
  - hostname: "*.yourdomain.com"
    service: http://traefik:80
  - hostname: yourdomain.com
    service: http://traefik:80
  - service: http_status:404
EOF
```

**4. Add DNS routes:**

```bash
docker run --rm -v ./cloudflared:/home/nonroot/.cloudflared cloudflare/cloudflared tunnel route dns nas-tunnel "*.yourdomain.com"
docker run --rm -v ./cloudflared:/home/nonroot/.cloudflared cloudflare/cloudflared tunnel route dns nas-tunnel yourdomain.com
```

</details>

<details>
<summary><strong>Option B: Port Forwarding + DNS</strong></summary>

Traditional approach - requires your ISP to allow incoming connections.

**1. Cloudflare API Token** (for SSL certificates):
- Go to: https://dash.cloudflare.com/profile/api-tokens
- Create Token → Use "Edit zone DNS" template
- Permissions: `Zone → DNS → Edit` AND `Zone → Zone → Read`
- Copy token and add to `.env`: `CF_DNS_API_TOKEN=your_token`

**2. DNS Records** in Cloudflare:
- Add A record: `@` → Your public IP
- Add CNAME: `*` → `@` (or your DDNS hostname)
- **Set Proxy Status to "DNS only" (gray cloud)** - this is critical!

**3. Router Port Forwarding:**

| External Port | Internal IP | Internal Port | Protocol |
|---------------|-------------|---------------|----------|
| 80 | NAS_IP | 8080 | TCP |
| 443 | NAS_IP | 8443 | TCP |
| 51820 | NAS_IP | 51820 | UDP |

> **Ugreen NAS Note:** Ugreen NAS (nginx) uses ports 80/443 and auto-repairs its config. This stack uses Traefik on ports 8080/8443 instead. Configure router to forward external 80→8080 and 443→8443.

**4. Add Domain to .env:**
```bash
DOMAIN=yourdomain.com
```

</details>

### Update Traefik Config

Copy the example configs and customize with your domain:

```bash
# Copy example configs
cp traefik/traefik.yml.example traefik/traefik.yml
cp traefik/dynamic/vpn-services.yml.example traefik/dynamic/vpn-services.yml
# Or for Plex:
# cp traefik/dynamic/vpn-services-plex.yml.example traefik/dynamic/vpn-services-plex.yml
```

Edit `traefik/traefik.yml` and replace `yourdomain.com` with your actual domain (3 places):

```yaml
# Line 31-33: SSL certificate domains
domains:
  - main: yourdomain.com      # ← your domain
    sans:
      - "*.yourdomain.com"    # ← your domain

# Line 39: Let's Encrypt email
email: admin@yourdomain.com   # ← your email
```

Edit `traefik/dynamic/vpn-services.yml` and replace the Host rules:

```yaml
# Replace yourdomain.com with your actual domain
jellyfin:
  rule: "Host(`jellyfin.yourdomain.com`)"  # ← your domain
jellyseerr:
  rule: "Host(`jellyseerr.yourdomain.com`)"  # ← your domain
wg:
  rule: "Host(`wg.yourdomain.com`)"  # ← your domain
```

> **Note:** The `.yml` files are gitignored. Your customized configs won't be overwritten when you `git pull` updates.

---

## Step 4: Deploy Services

### 4.1 Create Docker Network

```bash
docker network create \
  --driver=bridge \
  --subnet=192.168.100.0/24 \
  --gateway=192.168.100.1 \
  traefik-proxy
```

### 4.2 Deploy (Choose One)

**Either** local-only:
```bash
docker compose -f docker-compose.arr-stack.yml up -d
```

**Or** with external access (Traefik + Cloudflare Tunnel):
```bash
# 1. Deploy Traefik first (creates network, handles SSL)
docker compose -f docker-compose.traefik.yml up -d

# 2. Deploy media stack
docker compose -f docker-compose.arr-stack.yml up -d

# 3. Deploy Cloudflare Tunnel (if using)
docker compose -f docker-compose.cloudflared.yml up -d
```

### 4.3 Verify Deployment

```bash
# Check all containers are running
docker ps

# Check VPN connection
docker logs gluetun | grep -i "connected"

# Verify VPN IP (should NOT be your home IP)
docker exec gluetun wget -qO- ifconfig.me
```

---

## Step 5: Configure Services

> **VPN Network Sharing:** Sonarr, Radarr, Prowlarr, and qBittorrent share Gluetun's network (for VPN protection). They reach each other via `localhost`. Services outside gluetun (Jellyseerr, Bazarr) reach them via `gluetun` hostname or `192.168.100.3`. See [Quick Reference](REFERENCE.md) for details.

### 5.1 qBittorrent

1. **Access:** `http://HOST_IP:8085`
2. **Get temporary password** (qBittorrent 4.6.1+ generates a random password):
   ```bash
   # Run this on your NAS via SSH:
   docker logs qbittorrent 2>&1 | grep "temporary password"
   ```
   Look for: `A temporary password is provided for this session: <password>`

   <details>
   <summary><strong>Ugreen NAS:</strong> Using UGOS Docker GUI instead</summary>

   You can also find the password in the UGOS web interface:
   1. Open Docker → Container → qbittorrent → Log tab
   2. Search for "password"

   ![UGOS Docker logs](images/qbit/1.png)

   </details>

3. **Login:** Username `admin`, password from step 2
4. **Change password immediately:** Tools → Options → Web UI → Authentication
5. **Create categories:** Right-click categories → Add
   - `sonarr` → Save path: `/downloads/sonarr`
   - `radarr` → Save path: `/downloads/radarr`

### 5.2 Prowlarr (Indexer Manager)

1. **Access:** `http://HOST_IP:9696`
2. **Add Indexers:** Settings → Indexers → Add Indexer
3. **Add FlareSolverr** (for protected sites):
   - Settings → Indexers → Add FlareSolverr
   - Host: `http://flaresolverr:8191` (or `http://192.168.100.10:8191` if hostname fails)
   - Tag: `flaresolverr`
   - **Note:** FlareSolverr doesn't bypass all Cloudflare protections - some indexers may still fail. Non-protected indexers are more reliable.
4. **Connect to Sonarr:**
   - Settings → Apps → Add → Sonarr
   - Sonarr Server: `http://localhost:8989` (they share gluetun's network)
   - API Key: (from Sonarr → Settings → General → Security)
5. **Connect to Radarr:** Same process with `http://localhost:7878`
6. **Sync:** Settings → Apps → Sync App Indexers

### 5.3 Sonarr (TV Shows)

1. **Access:** `http://HOST_IP:8989`
2. **Add Root Folder:** Settings → Media Management → `/tv`
3. **Add Download Client:** Settings → Download Clients → qBittorrent
   - Host: `localhost` (Sonarr & qBittorrent share gluetun's network)
   - Port: `8085`
   - Category: `sonarr`

### 5.4 Radarr (Movies)

1. **Access:** `http://HOST_IP:7878`
2. **Add Root Folder:** Settings → Media Management → `/movies`
3. **Add Download Client:** Settings → Download Clients → qBittorrent
   - Host: `localhost` (Radarr & qBittorrent share gluetun's network)
   - Port: `8085`
   - Category: `radarr`

### 5.5 Jellyfin (Media Server)

1. **Access:** `http://HOST_IP:8096`
2. **Initial Setup:** Create admin account
3. **Add Libraries:**
   - Movies: Content type "Movies", Folder `/media/movies`
   - TV Shows: Content type "Shows", Folder `/media/tv`

### 5.6 Jellyseerr (Request Manager)

1. **Access:** `http://HOST_IP:5055`
2. **Sign in with Jellyfin:**
   - Jellyfin URL: `http://jellyfin:8096`
   - Enter Jellyfin credentials
3. **Configure Services:**
   - Settings → Services → Add Sonarr: `http://gluetun:8989` (Sonarr runs via gluetun)
   - Settings → Services → Add Radarr: `http://gluetun:7878` (Radarr runs via gluetun)

### 5.7 Bazarr (Subtitles)

1. **Access:** `http://HOST_IP:6767`
2. **Enable Authentication:** Settings → General → Security → Forms
3. **Connect to Sonarr:** Settings → Sonarr → `http://gluetun:8989` (Sonarr runs via gluetun)
4. **Connect to Radarr:** Settings → Radarr → `http://gluetun:7878` (Radarr runs via gluetun)
5. **Add Providers:** Settings → Providers (OpenSubtitles, etc.)

### 5.8 Pi-hole (DNS/Ad-blocking)

1. **Access:** `http://HOST_IP:8081/admin`
2. **Login:** Use password from `PIHOLE_UI_PASS` (password only, no username)
3. **Configure DNS:** Settings → DNS → Upstream: 1.1.1.1, 1.0.0.1

**Network-wide ad-blocking:** Set your router's DHCP DNS to your host IP.

⚠️ **Security:** Admin services are local-only by default, but still recommend enabling authentication on Sonarr, Radarr, Prowlarr, Bazarr, and qBittorrent.

---

## Step 6: Test

### VPN Test
```bash
# Should show VPN IP, not your home IP
docker exec gluetun wget -qO- ifconfig.me
docker exec qbittorrent wget -qO- ifconfig.me
```

### Service Integration Test
1. Sonarr/Radarr: Settings → Download Clients → Test
2. Add a TV show or movie you have rights to → verify it appears in qBittorrent
3. After download completes → verify it moves to library
4. Jellyfin → verify media appears in library

### External Access Test (if configured)
- From phone on cellular data: `https://jellyfin.yourdomain.com`
- Check SSL certificate is valid (padlock icon)

---

## Next Steps

Setup complete! Now:

1. **Add content:** Search for TV shows in Sonarr, movies in Radarr
2. **Deploy utilities** (optional): See below
3. **Bookmark:** [Quick Reference](REFERENCE.md) for URLs, commands, and network info

**Other docs:** [Updating the Stack](UPDATING.md) · [Home Assistant Integration](HOME-ASSISTANT.md)

Issues? [Report on GitHub](https://github.com/Pharkie/arr-stack-ugreennas/issues).

---

## Backup

Service configs are stored in Docker named volumes. Run periodic backups:

```bash
./scripts/backup-volumes.sh --tar
```

Creates a ~13MB tarball of essential configs (VPN settings, indexers, request history, etc.).

See **[Backup & Restore](BACKUP.md)** for full details on what's backed up, restore procedures, and automation.

---

## Optional Utilities

Deploy additional utilities for monitoring and NAS optimization:

```bash
docker compose -f docker-compose.utilities.yml up -d
```

| Service | Description | Access |
|---------|-------------|--------|
| **deunhealth** | Auto-restarts services when VPN recovers | Internal |
| **Uptime Kuma** | Service monitoring dashboard | http://HOST_IP:3001 |
| **duc** | Disk usage analyzer (treemap UI) | http://HOST_IP:8838 |
| **qbit-scheduler** | Pauses torrents overnight for disk spin-down | Internal |

### qbit-scheduler Setup

Pauses all torrents at 20:00 and resumes at 06:00, allowing NAS disks to spin down overnight.

**Requirements:** Add qBittorrent credentials to `.env`:
```bash
QBIT_USER=admin
QBIT_PASSWORD=your_qbittorrent_password
```

**Manual control:**
```bash
docker exec qbit-scheduler /app/pause-resume.sh pause   # Stop all torrents
docker exec qbit-scheduler /app/pause-resume.sh resume  # Start all torrents
```

**View logs:**
```bash
docker logs qbit-scheduler
```
