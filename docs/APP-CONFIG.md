# Step 4: Configure Each App

> Return to [Setup Guide](SETUP.md)

Your stack is running! Now configure each app to work together.

**Configuration order:** Services depend on each other, so configure them in the order below:
1. Jellyfin (media server — needed before Seerr)
2. qBittorrent (downloads — needed before Sonarr/Radarr)
3. SABnzbd (optional Usenet — needed before Sonarr/Radarr if using)
4. Sonarr & Radarr (library managers — need qBit/SABnzbd configured first)
5. Prowlarr (indexers — needs Sonarr/Radarr configured first)
6. Seerr (requests — needs Jellyfin + Sonarr/Radarr configured first)
7. Bazarr (subtitles — needs Sonarr/Radarr configured first)
8. Pi-hole (DNS — independent, do anytime)

See **[Quick Reference → Service Connection Guide](REFERENCE.md#service-connection-guide)** for how services connect to each other.

## Choose your path

| | Script-Assisted (Recommended) | Manual |
|---|---|---|
| **Time** | ~5 minutes | ~30 minutes |
| **What happens** | Script configures qBit, Sonarr, Radarr, Prowlarr, Bazarr; you do the rest manually | You configure everything through the web UI |
| **Guide** | **[APP-CONFIG-QUICK.md](APP-CONFIG-QUICK.md)** | Continue below ↓ |

---

## Manual Configuration

Work through these sections top to bottom.

## 4.1 Jellyfin (Media Server)

Streams your media library to any device.

1. **Access:** `http://NAS_IP:8096`
2. **Create admin account** when prompted (setup wizard)
3. **Add Libraries:**
   - Movies: Content type "Movies", Folder `/data/media/movies`
   - TV Shows: Content type "Shows", Folder `/data/media/tv`

> **Optional:** [Enable hardware transcoding](APP-CONFIG-ADVANCED.md#hardware-transcoding-intel-quick-sync) for GPU-accelerated playback (recommended for Ugreen NAS). Also see [Kodi for Fire TV](APP-CONFIG-ADVANCED.md#kodi-for-fire-tv-dolby-vision--truehd-atmos) and [RAID5 streaming tuning](APP-CONFIG-ADVANCED.md#raid5-streaming-tuning).

## 4.2 qBittorrent (Torrent Downloads)

Receives download requests from Sonarr and Radarr and downloads files via torrents.

1. **Access:** `http://NAS_IP:8085`
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
5. **Set Torrent Management Mode:** Tools → Options → Downloads → **Default Torrent Management Mode: Automatic**
   - This tells qBittorrent to use the category save path, enabling hardlinks between download and library directories
6. **Create categories:** Right-click categories → Add
   - `tv` → Save path: `/data/torrents/tv`
   - `movies` → Save path: `/data/torrents/movies`

   > **Why categories matter:** Sonarr/Radarr tell qBittorrent which category to use when requesting downloads. qBittorrent puts files in the category's save path. After download completes, Sonarr/Radarr create hardlinks from `/data/torrents/tv` or `/data/torrents/movies` to your library (`/data/media/tv` or `/data/media/movies`). If categories don't match, downloads won't be found.

> **Optional:** [qBittorrent tuning](APP-CONFIG-ADVANCED.md#qbittorrent-tuning-trash-recommended) (TRaSH recommended settings for encryption, UPnP, VueTorrent mobile UI).

## 4.3 SABnzbd (Usenet Downloads)

SABnzbd provides Usenet downloads as an alternative/complement to qBittorrent.

> **Note:** Usenet is routed through VPN for consistency and an extra layer of security.

1. **Access:** `http://NAS_IP:8082`
2. **Run Quick-Start Wizard** with your Usenet provider details:

   **Popular providers:**
   | Provider | Price | Server |
   |----------|-------|--------|
   | Frugal Usenet | $4/mo | `news.frugalusenet.com` |
   | Newshosting | $6/mo | `news.newshosting.com` |
   | Eweka | €4/mo | `news.eweka.nl` |

   **Wizard settings:**
   - Host: (from table above)
   - Username: (your account email)
   - Password: (your account password)
   - SSL: ✓ checked
   - Click **Advanced Settings**:
     - Port: `563`
     - Connections: `20-60` (depends on plan)
   - Click **Test Server** → **Next**

3. **Configure Folders:** Config (⚙️) → Folders → set **absolute paths**:
   - **Temporary Download Folder:** `/data/usenet/incomplete`
   - **Completed Download Folder:** `/data/usenet/complete`
   - Save Changes

   > **Important:** Don't use relative paths like `Downloads/complete` - Sonarr/Radarr won't find them.

4. **Get API Key:** Config (⚙️) → General → Copy **API Key**

> **Optional:** [SABnzbd hardening](APP-CONFIG-ADVANCED.md#sabnzbd-hardening-trash-recommended) (TRaSH recommended settings for sorting, propagation, hostname whitelist).

> **Next:** Once SABnzbd is set up, you'll add a Usenet indexer in [Prowlarr §4.6](#46-prowlarr-indexer-manager).

## 4.4 Sonarr (TV Shows)

Searches for TV shows, sends download links to qBittorrent/SABnzbd, and organizes completed files.

1. **Access:** `http://NAS_IP:8989`
2. **Create admin account** when prompted
3. **Add Root Folder:** Settings → Media Management → `/data/media/tv`
3. **Add Download Client(s):** Settings → Download Clients

   **qBittorrent (torrents):**
   - Add → qBittorrent
   - Host: `localhost` (Sonarr & qBittorrent share gluetun's network)
   - Port: `8085`
   - Category: `tv`

   **SABnzbd (Usenet):** *(if configured)*
   - Add → SABnzbd
   - Host: `localhost` (SABnzbd also runs via gluetun)
   - Port: `8080`
   - API Key: (from SABnzbd Config → General)
   - Category: `tv`

4. **Enable NFO metadata:** Settings → Metadata → Kodi (XBMC) / Emby → **Enable** (see [why this matters](#nfo-metadata))
   - Series Metadata: ✅
   - Episode Metadata: ✅
   - All image options: ❌ (Jellyfin handles its own artwork)

5. **Configure naming (TRaSH recommended):** Settings → Media Management → Episode Naming
   - **Rename Episodes:** ✅
   - **Standard Episode Format:** `{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}`
   - **Daily Episode Format:** `{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}`
   - **Anime Episode Format:** `{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels}{MediaInfo AudioLanguages}]{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec][ Mediainfo VideoBitDepth]bit}{-Release Group}`
   - **Season Folder Format:** `Season {season:00}`
   - **Series Folder Format:** `{Series TitleYear} [tvdbid-{TvdbId}]`
   - **Multi-Episode Style:** Prefixed Range

   > These follow [TRaSH Guides Sonarr naming](https://trash-guides.info/Sonarr/Sonarr-recommended-naming-scheme/). After saving, rename existing files: Series → Select All → Organize.

6. **Block ISOs:** Some indexers serve disc images that Jellyfin can't play.
   - Settings → Custom Formats → + → Name: `Reject ISO`
   - Add condition: Release Title, value `\.iso$`, check **Regex**
   - Settings → Profiles → your quality profile → set `Reject ISO` to `-10000`

## 4.5 Radarr (Movies)

Searches for movies, sends download links to qBittorrent/SABnzbd, and organizes completed files.

1. **Access:** `http://NAS_IP:7878`
2. **Create admin account** when prompted
3. **Add Root Folder:** Settings → Media Management → `/data/media/movies`
3. **Add Download Client(s):** Settings → Download Clients

   **qBittorrent (torrents):**
   - Add → qBittorrent
   - Host: `localhost` (Radarr & qBittorrent share gluetun's network)
   - Port: `8085`
   - Category: `movies`

   **SABnzbd (Usenet):** *(if configured)*
   - Add → SABnzbd
   - Host: `localhost` (SABnzbd also runs via gluetun)
   - Port: `8080`
   - API Key: (from SABnzbd Config → General)
   - Category: `movies`

4. **Enable NFO metadata:** Settings → Metadata → Kodi (XBMC) / Emby → **Enable** (see [why this matters](#nfo-metadata))
   - Movie Metadata: ✅
   - Movie Images: ❌ (Jellyfin handles its own artwork)

5. **Configure naming (TRaSH recommended):** Settings → Media Management → Movie Naming
   - **Rename Movies:** ✅
   - **Standard Movie Format:** `{Movie CleanTitle} {(Release Year)} {imdb-{ImdbId}} - {Edition Tags }{[Custom Formats]}{[Quality Full]}{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}`
   - **Movie Folder Format:** `{Movie CleanTitle} ({Release Year})`

   > These follow [TRaSH Guides Radarr naming](https://trash-guides.info/Radarr/Radarr-recommended-naming-scheme/). After saving, rename existing files: Movies → Select All → Organize.

6. **Block ISOs:** Some indexers serve disc images that Jellyfin can't play.
   - Settings → Custom Formats → + → Name: `Reject ISO`
   - Add condition: Release Title, value `\.iso$`, check **Regex**
   - Settings → Profiles → your quality profile → set `Reject ISO` to `-10000`

### Prefer Usenet over Torrents (Optional)

If you have both qBittorrent and SABnzbd configured, Sonarr/Radarr will grab whichever is available first. To prefer Usenet (faster, no seeding):

1. Settings → Profiles → Delay Profiles
2. Click the **wrench/spanner icon** on the existing profile (don't click +)
3. Set: **Usenet Delay:** `0` minutes, **Torrent Delay:** `30` minutes
4. Save

This gives Usenet a 30-minute head start before considering torrents.

> **Note:** Do this in both Sonarr and Radarr (same steps in each).

### NFO Metadata

> **Applies to both Sonarr (step 4 above) and Radarr (step 4 above).**
>
> **Why this matters:** Without NFO files, Jellyfin identifies media by guessing from the filename. For movies or shows with common titles shared by multiple entries on TMDB, it can match the wrong one. When the TMDB IDs don't agree between Radarr/Sonarr and Jellyfin, Seerr can't link them — so requests stay stuck at "Requested" even though the file is downloaded and playable.
>
> Enabling NFO metadata makes Radarr/Sonarr write a small `.nfo` file alongside each media file containing the correct TMDB/IMDB/TVDB IDs. Jellyfin reads these instead of guessing. This eliminates the entire class of metadata mismatch bugs.
>
> **After enabling:** Run a full library refresh to write NFOs for existing media. In Radarr: Movies → Update All. In Sonarr: Series → Update All. New downloads will get NFOs automatically.

## 4.6 Prowlarr (Indexer Manager)

Manages torrent/Usenet indexers and syncs them to Sonarr/Radarr.

1. **Access:** `http://NAS_IP:9696`
2. **Create admin account** when prompted
3. **Add Torrent Indexers:** Indexers (left sidebar) → + button → search by name
3. **If using SABnzbd: Add Usenet Indexer**
   - **Indexers** (left sidebar, NOT Settings → Indexer Proxies) → + button
   - Search by indexer name (e.g., "NZBGeek", "DrunkenSlug", "NZBFinder")
   - API Key: (from your indexer account → API section)
   - **Tags:** leave blank (syncs to all apps)
   - **Indexer Proxy:** leave blank (not needed for Usenet)
   - Test → Save

   > **Tested with:** NZBGeek (~$12/year, reliable). Free alternatives: DrunkenSlug, NZBFinder.

4. **Add FlareSolverr** (for protected torrent sites):
   - Settings → Indexers → Add FlareSolverr
   - Host: `http://localhost:8191` (FlareSolverr shares Gluetun's network with Prowlarr)
   - Tag: `flaresolverr`
   - **Note:** FlareSolverr doesn't bypass all Cloudflare protections - some indexers may still fail. If you have issues, [Byparr](https://github.com/ThePhaseless/Byparr) is a drop-in alternative using different browser tech.
5. **Connect to Sonarr:**
   - Settings → Apps → Add → Sonarr
   - Sonarr Server: `http://localhost:8989` (they share gluetun's network)
   - API Key: (from Sonarr → Settings → General → Security)
6. **Connect to Radarr:** Same process with `http://localhost:7878`
7. **Sync:** Settings → Apps → Sync App Indexers

## 4.7 Seerr (Request Manager)

Lets users browse and request movies/TV shows.

1. **Access:** `http://NAS_IP:5055`
2. **Sign in with Jellyfin:**
   - Jellyfin URL: `http://jellyfin:8096`
   - Enter Jellyfin credentials
3. **Configure Services:**
   - Settings → Services → Add Radarr:
     - **Hostname:** `gluetun` (internal Docker hostname)
     - **Port:** `7878`
     - **External URL:** `http://radarr.lan` (or `http://NAS_IP:7878`) — makes "Open in Radarr" links work in your browser
   - Settings → Services → Add Sonarr:
     - **Hostname:** `gluetun`
     - **Port:** `8989`
     - **External URL:** `http://sonarr.lan` (or `http://NAS_IP:8989`)

## 4.8 Bazarr (Subtitles)

Automatically downloads subtitles for your media.

1. **Access:** `http://NAS_IP:6767`
2. **Enable Authentication:** Settings → General → Security → Forms
3. **Connect to Sonarr:** Settings → Sonarr → `http://gluetun:8989` (Sonarr runs via gluetun)
4. **Connect to Radarr:** Settings → Radarr → `http://gluetun:7878` (Radarr runs via gluetun)
5. **Add Providers:** Settings → Providers (OpenSubtitles, etc.)
6. **Enable Subtitle Sync:** Settings → Subtitles → Subtitle Synchronization:
   - **Subtitle Synchronization:** On — enables `ffsubsync` to re-time subtitles against the audio track
   - **Series Score Threshold:** On (default 90) — auto-syncs series subs scoring below this
   - **Movies Score Threshold:** On (default 70) — auto-syncs movie subs scoring below this

   > **Why:** Jellyfin's web player has no manual subtitle delay control. If subs are out of sync, the only fix is re-timing the subtitle file itself — which is exactly what this does.

## 4.9 Pi-hole (DNS)

> **Prerequisite: Static IP required.** Pi-hole binds to `NAS_IP` at boot. If the IP comes from DHCP, Docker starts before it's assigned and Pi-hole fails every reboot. Check: `ip addr show eth0` — if you see `dynamic`, it's DHCP and needs fixing. See [Troubleshooting: Pi-hole doesn't start after reboot](TROUBLESHOOTING.md#pi-hole-doesnt-start-after-reboot).

1. **Access:** `http://NAS_IP:8081/admin`
2. **Login:** Use password from `PIHOLE_UI_PASS` (password only, no username)
3. **Upstream DNS:** Settings → DNS → pick upstream servers (1.1.1.1, 8.8.8.8, etc.)

**Optional:** Set your router's DHCP DNS to your NAS IP for network-wide ad-blocking.

> **Warning:** If your NAS goes down, every device on your network will lose internet (DNS stops resolving). To recover: temporarily change your device's DNS to `1.1.1.1` (or enable a VPN) so you can access your router and revert the DHCP DNS setting until Pi-hole is back up.

---

**Next step:** Return to [Setup Guide → Step 5: Check It Works](SETUP.md#step-5-check-it-works)
