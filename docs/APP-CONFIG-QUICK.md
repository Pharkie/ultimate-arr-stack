# Step 4: Configure Each App (Script-Assisted)

> Return to [Setup Guide](SETUP.md) · [Manual setup instead?](APP-CONFIG.md)

The [configure-apps.sh](../scripts/configure-apps.sh) script automates ~22 configuration steps across qBittorrent, Sonarr, Radarr, Prowlarr, and Bazarr — root folders, download clients, naming schemes, NFO metadata, custom formats, delay profiles, subtitle sync, and more.

## Step 1: Set up access to each app

Work through these in order. Each app needs you to create an account or complete a first-run wizard before anything else works.

**Jellyfin** — `http://NAS_IP:8096`
Complete the setup wizard (language, admin user, etc.). Skip adding libraries for now — you'll do that in Step 3.

**qBittorrent** — `http://NAS_IP:8085`
Get the temporary password:
```bash
docker logs qbittorrent 2>&1 | grep "temporary password"
```
Login as `admin` with the temp password, then change it immediately: Tools → Options → Web UI → Authentication.

**SABnzbd** *(skip if not using Usenet)* — `http://NAS_IP:8082`
Complete the Quick-Start Wizard with your Usenet provider details (host, username, password, SSL on, port `563`).

**Sonarr** — `http://NAS_IP:8989`
Create admin account when prompted.

**Radarr** — `http://NAS_IP:7878`
Create admin account when prompted.

**Prowlarr** — `http://NAS_IP:9696`
Create admin account when prompted.

**Bazarr** — `http://NAS_IP:6767`
Create admin account when prompted.

## Step 2: Run the script

```bash
# SSH to your NAS:
cd /volume1/docker/arr-stack

# If you've changed qBittorrent's default password:
QBIT_PASSWORD='yourpassword' ./scripts/configure-apps.sh

# If still using the temp password (first run):
./scripts/configure-apps.sh
```

Preview what it will do without making changes:

```bash
./scripts/configure-apps.sh --dry-run
```

> **Safe to re-run:** The script is fully idempotent — it checks each setting before applying it and skips anything already configured. You can run it as many times as needed without side effects (e.g., after a stack update or restore).

**What the script configures:**

| Service | Settings |
|---------|----------|
| qBittorrent | Categories (`tv`/`movies`), auto torrent management, encryption, UPnP off |
| Sonarr | Root folder, qBittorrent + SABnzbd download clients, TRaSH naming, NFO metadata, Reject ISO custom format, Usenet delay profile |
| Radarr | Root folder, qBittorrent + SABnzbd download clients, TRaSH naming, NFO metadata, Reject ISO custom format, Usenet delay profile |
| Prowlarr | FlareSolverr proxy, Sonarr + Radarr app sync |
| Bazarr | Sonarr + Radarr connections, subtitle sync (ffsubsync), Sub-Zero content mods, default English language |

## Step 3: Configure the remaining services

The script handles qBittorrent, Sonarr, Radarr, Prowlarr, and Bazarr. Complete these remaining services in order:

### 1. Jellyfin — Add libraries

- Movies → Content type "Movies" → Folder `/data/media/movies`
- TV Shows → Content type "Shows" → Folder `/data/media/tv`

> **Optional:** [Enable hardware transcoding](APP-CONFIG-ADVANCED.md#hardware-transcoding-intel-quick-sync) for GPU-accelerated playback (recommended for Ugreen NAS).

### 2. SABnzbd — Set download folders (skip if not using Usenet)

Config (⚙️) → Folders → set **absolute paths**:
- Temporary Download Folder: `/data/usenet/incomplete`
- Completed Download Folder: `/data/usenet/complete`

> For hardening settings and `.lan` hostname whitelist, see [SABnzbd Advanced Setup](APP-CONFIG-ADVANCED.md#sabnzbd-hardening-trash-recommended).

### 3. Prowlarr — Add your indexers

1. Indexers (left sidebar) → + → search by name → add your torrent indexers
2. If using Usenet: add a Usenet indexer the same way (e.g., NZBGeek, DrunkenSlug)

### 4. Seerr — Connect to Jellyfin and *arrs

1. Open `http://NAS_IP:5055`
2. Sign in with Jellyfin: URL `http://jellyfin:8096`, enter your Jellyfin credentials
3. Settings → Services → Add Radarr:
   - Hostname: `gluetun`, Port: `7878`
   - External URL: `http://radarr.lan` (or `http://NAS_IP:7878`)
4. Settings → Services → Add Sonarr:
   - Hostname: `gluetun`, Port: `8989`
   - External URL: `http://sonarr.lan` (or `http://NAS_IP:8989`)

### 5. Bazarr — Add subtitle providers

Settings → Providers → add a provider (e.g., OpenSubtitles).

> The script already configured Sonarr/Radarr connections and subtitle sync.

### 6. Pi-hole — Set upstream DNS

1. Open `http://NAS_IP:8081/admin`
2. Login with the password from `PIHOLE_UI_PASS` in your `.env` (password only, no username)
3. Settings → DNS → pick upstream servers (e.g., `1.1.1.1`, `8.8.8.8`)

---

**You're done!** Return to [Setup Guide → Step 5: Check It Works](SETUP.md#step-5-check-it-works).
