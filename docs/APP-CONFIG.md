# Step 4: Configure Each App

> Return to [Setup Guide](SETUP.md)

Your stack is running! Now configure each app to work together.

See **[Quick Reference → Service Connection Guide](REFERENCE.md#service-connection-guide)** for how services connect to each other.

## Option A: Semi-Automated Configuration (Recommended)

A script automates ~22 configuration steps across qBittorrent, Sonarr, Radarr, Prowlarr, and Bazarr — root folders, download clients, naming schemes, NFO metadata, custom formats, delay profiles, subtitle sync, and more.

**Prerequisites:** Complete the initial setup wizards first — each *arr app requires you to create an admin account on first access before the API is available.

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

**What the script configures:**

| Service | Settings |
|---------|----------|
| qBittorrent | Categories (`tv`/`movies`), auto torrent management, encryption, UPnP off |
| Sonarr | Root folder, qBittorrent + SABnzbd download clients, TRaSH naming, NFO metadata, Reject ISO custom format, Usenet delay profile |
| Radarr | Root folder, qBittorrent + SABnzbd download clients, TRaSH naming, NFO metadata, Reject ISO custom format, Usenet delay profile |
| Prowlarr | FlareSolverr proxy, Sonarr + Radarr app sync |
| Bazarr | Sonarr + Radarr connections, subtitle sync (ffsubsync), Sub-Zero content mods, default English language |

**What stays manual after the script:**

1. **Jellyfin** — Initial wizard, add libraries, hardware transcoding ([§4.1](#41-jellyfin-media-server))
2. **qBittorrent** — Change default password ([§4.2 step 4](#42-qbittorrent-torrent-downloads))
3. **Prowlarr** — Add your indexers ([§4.6 steps 2–3](#46-prowlarr-indexer-manager))
4. **Seerr** — Initial setup + Jellyfin login ([§4.7](#47-seerr-request-manager))
5. **SABnzbd** — Usenet provider credentials + folder config ([§4.3](#43-sabnzbd-usenet-downloads))
6. **Pi-hole** — Upstream DNS servers ([§4.10](#410-pi-hole-dns))

After running the script, skip to each section above for the remaining manual steps.

## Option B: Manual Configuration

Follow each section below to configure everything through the web UI.

---

## 4.1 Jellyfin (Media Server)

Streams your media library to any device.

1. **Access:** `http://NAS_IP:8096`
2. **Initial Setup:** Create admin account
3. **Add Libraries:**
   - Movies: Content type "Movies", Folder `/data/media/movies`
   - TV Shows: Content type "Shows", Folder `/data/media/tv`

<details>
<summary><strong>Hardware Transcoding (Intel Quick Sync) - Recommended for Ugreen</strong></summary>

Ugreen NAS (DXP4800+, etc.) have Intel CPUs with built-in GPUs. Enable this to use GPU-accelerated transcoding - reduces CPU usage from ~80% to ~20% when transcoding.

> **No Intel GPU?** Remove the `devices:` and `group_add:` lines (4 lines total) from the jellyfin service in `docker-compose.arr-stack.yml`, or Jellyfin won't start.

**1. Find your render group ID:**
```bash
# SSH to your NAS and run:
getent group render | cut -d: -f3
```

**2. Add to your `.env`:**
```bash
RENDER_GROUP_ID=105  # Use the number from step 1
```

**3. Recreate Jellyfin:**
```bash
docker compose -f docker-compose.arr-stack.yml up -d jellyfin
```

**4. Configure Jellyfin:** Dashboard → Playback → Transcoding

![Jellyfin transcoding settings](images/jellyfin/jellyfin-transcoding.png)

**Key settings:**
- **Hardware acceleration:** Intel QuickSync (QSV)
- **Enable hardware decoding for:** H264, HEVC, MPEG2, VC1, VP8, VP9, HEVC 10bit, VP9 10bit
- **Prefer OS native DXVA or VA-API hardware decoders:** ✅
- **Enable hardware encoding:** ✅
- **Enable Intel Low-Power H.264/HEVC encoders:** ✅
- **Allow encoding in HEVC format:** ✅
- **Enable VPP Tone mapping:** ✅

**5. Configure Trickplay:** Dashboard → Playback → Trickplay

Trickplay generates preview thumbnails when you hover over the video timeline.

![Jellyfin trickplay settings](images/jellyfin/jellyfin-trickplay.png)

**Enable these for GPU-accelerated thumbnail generation:**
- **Enable hardware decoding:** ✅
- **Enable hardware accelerated MJPEG encoding:** ✅
- **Only generate images from key frames:** ✅ (faster, minimal quality impact)

**6. Verify it's working:**

1. Click your user icon → **Settings** → **Playback**
2. Set **Quality** to a low value (e.g., 720p 1Mbps)
3. Play a video and open **Playback Info** (⚙️ → Playback Info)
4. Look for **"Transcoding framerate"** - should show **10x+ realtime** (e.g., 400+ fps)
5. Check CPU usage - should stay ~20-30% instead of 80%+

If transcoding framerate is only ~1x (24-30 fps), hardware acceleration isn't working.

</details>

<details>
<summary><strong>Kodi for Fire TV (Dolby Vision / TrueHD Atmos passthrough)</strong></summary>

**When to use Kodi instead of the Jellyfin app:**

The Jellyfin Android TV app works well for most content. However, it may not properly pass through advanced audio/video formats to your AV receiver. If you're experiencing:

- High CPU usage / transcoding on 4K HDR or Dolby Vision content
- Audio being converted instead of passing through TrueHD Atmos or DTS-HD
- Playback stuttering or buffering on high-bitrate files

...try **Kodi with the Jellyfin add-on** instead. Kodi handles passthrough more reliably on Fire TV devices.

**Step 1: Install Kodi on Fire TV (sideload via ADB)**

Kodi isn't in the Amazon App Store. Install via ADB from your computer:

```bash
# Install ADB (Mac)
brew install android-platform-tools

# Enable on Fire TV: Settings → My Fire TV → Developer Options → ADB debugging → ON

# Connect (replace FIRETV_IP with your Fire TV's IP)
adb connect FIRETV_IP:5555
# Accept the prompt on your TV screen

# Download and install Kodi (32-bit for Fire TV)
curl -L -o /tmp/kodi.apk "https://mirrors.kodi.tv/releases/android/arm/kodi-21.3-Omega-armeabi-v7a.apk"
adb install /tmp/kodi.apk
```

**Step 2: Install Jellyfin add-on in Kodi**

First, push the Jellyfin repo to Fire TV:
```bash
curl -L -o /tmp/jellyfin-repo.zip "https://kodi.jellyfin.org/repository.jellyfin.kodi.zip"
adb push /tmp/jellyfin-repo.zip /sdcard/Download/
```

Then in Kodi on Fire TV:
1. Settings → Add-ons → Install from zip file
2. Enable unknown sources if prompted
3. Select External storage → Download → `jellyfin-repo.zip`
4. Wait for "Add-on installed" notification
5. Install from repository → Jellyfin Kodi Add-ons → Video add-ons → Jellyfin → Install

**Step 3: Fix "Unable to connect" error**

Jellyfin in Docker reports its internal Docker IP to clients, which they can't reach. Fix by setting the published server URI:

```bash
# SSH to NAS and run (replace NAS_IP with your actual NAS IP):
docker exec jellyfin sed -i 's|<PublishedServerUriBySubnet />|<PublishedServerUriBySubnet><string>0.0.0.0/0=http://NAS_IP:8096</string></PublishedServerUriBySubnet>|' /config/config/network.xml

docker compose -f docker-compose.arr-stack.yml restart jellyfin
```

**Step 4: Connect and configure**

1. In Kodi, the Jellyfin add-on should auto-discover your server
2. Select it and login with your Jellyfin credentials
3. Choose **Add-on** mode when prompted

**Step 5: Enable passthrough in Kodi**

Settings → System → Audio:
- Allow passthrough: **On**
- Dolby TrueHD capable receiver: **On**
- DTS-HD capable receiver: **On**
- Passthrough output device: your AV receiver

Now 4K Dolby Vision + TrueHD Atmos content will direct play without transcoding.

</details>

### RAID5 Streaming Tuning

If you're using RAID5 with spinning HDDs and experience playback stuttering on large files (especially 4K remuxes), the default read-ahead buffer is too small. Apply this tuning on your NAS:

```bash
sudo bash -c '
echo 4096 > /sys/block/md1/queue/read_ahead_kb
echo 4096 > /sys/block/dm-0/queue/read_ahead_kb
echo 4096 > /sys/block/md1/md/stripe_cache_size
'
```

Add a root crontab `@reboot` job to persist across reboots (do **not** use `/etc/rc.local` — UGOS overwrites it on firmware updates). See [Troubleshooting: Jellyfin Video Stutters](TROUBLESHOOTING.md#jellyfin-video-stuttersfreezes-every-few-minutes) for full details.

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

### qBittorrent Tuning (TRaSH Recommended)

Tools → Options → BitTorrent:
- **Enable UPnP / NAT-PMP:** ❌ (unnecessary behind VPN, potential security risk)

Tools → Options → Speed:
- **Apply rate limit to µTP protocol:** ✅
- **Apply rate limit to peers on LAN:** ✅

Tools → Options → BitTorrent:
- **Encryption mode:** Allow encryption

> These follow [TRaSH Guides qBittorrent recommendations](https://trash-guides.info/Downloaders/qBittorrent/Basic-Setup/). Speed limits are left at unlimited since the VPN is the bottleneck.

> **Mobile access?** The default UI is poor on mobile. This stack includes [VueTorrent](https://github.com/VueTorrent/VueTorrent)—enable it at Tools → Options → Web UI → Use alternative WebUI → `/vuetorrent`.

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

### SABnzbd Hardening (TRaSH Recommended)

These settings follow [TRaSH Guides SABnzbd recommendations](https://trash-guides.info/Downloaders/SABnzbd/Basic-Setup/):

**Config (⚙️) → Sorting:**
- **Enable TV Sorting:** ❌
- **Enable Movie Sorting:** ❌
- **Enable Date Sorting:** ❌

> Sorting must be disabled — Sonarr/Radarr handle all file organization. SABnzbd sorting causes files to end up in unexpected paths.

**Config (⚙️) → Switches:**
- **Propagation delay:** `5` minutes (waits for Usenet propagation before downloading)
- **Check result of unpacking:** ✅ (only processes successfully unpacked jobs)
- **Deobfuscate final filenames:** ✅ (cleans up obfuscated filenames)

**Config (⚙️) → Special:**
- **Unwanted extensions:** Add common junk file extensions. See [TRaSH's full list](https://trash-guides.info/Downloaders/SABnzbd/Basic-Setup/#unwanted-extensions) for the recommended blacklist.

4. **Get API Key:** Config (⚙️) → General → Copy **API Key**

5. **For + local DNS:** Add `sabnzbd.lan` to hostname whitelist:
   - Config (⚙️) → Special → **host_whitelist** → add `sabnzbd.lan`
   - Save, then restart SABnzbd container

   Or via SSH:
   ```bash
   docker exec sabnzbd sed -i 's/^host_whitelist = .*/&, sabnzbd.lan/' /config/sabnzbd.ini
   docker restart sabnzbd
   ```

6. **Add Usenet indexer to Prowlarr** (later step):
   - NZBGeek ($12/year): https://nzbgeek.info
   - DrunkenSlug (free tier): https://drunkenslug.com

## 4.4 Sonarr (TV Shows)

Searches for TV shows, sends download links to qBittorrent/SABnzbd, and organizes completed files.

1. **Access:** `http://NAS_IP:8989`
2. **Add Root Folder:** Settings → Media Management → `/data/media/tv`
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
2. **Add Root Folder:** Settings → Media Management → `/data/media/movies`
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

### NFO Metadata

> **Why this matters:** Without NFO files, Jellyfin identifies media by guessing from the filename. For movies or shows with common titles shared by multiple entries on TMDB, it can match the wrong one. When the TMDB IDs don't agree between Radarr/Sonarr and Jellyfin, Seerr can't link them — so requests stay stuck at "Requested" even though the file is downloaded and playable.
>
> Enabling NFO metadata makes Radarr/Sonarr write a small `.nfo` file alongside each media file containing the correct TMDB/IMDB/TVDB IDs. Jellyfin reads these instead of guessing. This eliminates the entire class of metadata mismatch bugs.
>
> **After enabling:** Run a full library refresh to write NFOs for existing media. In Radarr: Movies → Update All. In Sonarr: Series → Update All. New downloads will get NFOs automatically.

## 4.6 Prowlarr (Indexer Manager)

Manages torrent/Usenet indexers and syncs them to Sonarr/Radarr.

1. **Access:** `http://NAS_IP:9696`
2. **Add Torrent Indexers:** Indexers (left sidebar) → + button → search by name
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

## 4.9 Prefer Usenet over Torrents (Optional)

If you have both qBittorrent and SABnzbd configured, Sonarr/Radarr will grab whichever is available first. To prefer Usenet (faster, no seeding):

1. Settings → Profiles → Delay Profiles
2. Click the **wrench/spanner icon** on the existing profile (don't click +)
3. Set: **Usenet Delay:** `0` minutes, **Torrent Delay:** `30` minutes
4. Save

This gives Usenet a 30-minute head start before considering torrents.

> **Note:** Do this in both Sonarr and Radarr (same steps in each).

## 4.10 Pi-hole (DNS)

> **Prerequisite: Static IP required.** Pi-hole binds to `NAS_IP` at boot. If the IP comes from DHCP, Docker starts before it's assigned and Pi-hole fails every reboot. Check: `ip addr show eth0` — if you see `dynamic`, it's DHCP and needs fixing. See [Troubleshooting: Pi-hole doesn't start after reboot](TROUBLESHOOTING.md#pi-hole-doesnt-start-after-reboot).

1. **Access:** `http://NAS_IP:8081/admin`
2. **Login:** Use password from `PIHOLE_UI_PASS` (password only, no username)
3. **Upstream DNS:** Settings → DNS → pick upstream servers (1.1.1.1, 8.8.8.8, etc.)

**Optional:** Set your router's DHCP DNS to your NAS IP for network-wide ad-blocking.

> **Warning:** If your NAS goes down, every device on your network will lose internet (DNS stops resolving). To recover: temporarily change your device's DNS to `1.1.1.1` (or enable a VPN) so you can access your router and revert the DHCP DNS setting until Pi-hole is back up.

---

**Next step:** Return to [Setup Guide → Step 5: Check It Works](SETUP.md#step-5-check-it-works)
