# Advanced Configuration

> Return to: [Script-Assisted Setup](APP-CONFIG-QUICK.md) · [Manual Setup](APP-CONFIG.md)

Optional tuning and advanced features. None of these are required — your stack works fine without them.

---

## Hardware Transcoding (Intel Quick Sync)

Recommended for Ugreen NAS (DXP4800+, etc.) with Intel CPUs. Enables GPU-accelerated transcoding — reduces CPU usage from ~80% to ~20%.

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
4. Look for **"Transcoding framerate"** — should show **10x+ realtime** (e.g., 400+ fps)
5. Check CPU usage — should stay ~20-30% instead of 80%+

If transcoding framerate is only ~1x (24-30 fps), hardware acceleration isn't working.

---

## Kodi for Fire TV (Dolby Vision / TrueHD Atmos)

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

---

## RAID5 Streaming Tuning

If you're using RAID5 with spinning HDDs and experience playback stuttering on large files (especially 4K remuxes), the default read-ahead buffer is too small. Apply this tuning on your NAS:

```bash
sudo bash -c '
echo 4096 > /sys/block/md1/queue/read_ahead_kb
echo 4096 > /sys/block/dm-0/queue/read_ahead_kb
echo 4096 > /sys/block/md1/md/stripe_cache_size
'
```

Add a root crontab `@reboot` job to persist across reboots (do **not** use `/etc/rc.local` — UGOS overwrites it on firmware updates). See [Troubleshooting: Jellyfin Video Stutters](TROUBLESHOOTING.md#jellyfin-video-stuttersfreezes-every-few-minutes) for full details.

---

## qBittorrent Tuning (TRaSH Recommended)

Tools → Options → Connection:
- **Enable UPnP / NAT-PMP:** ❌ (unnecessary behind VPN, potential security risk)

Tools → Options → Speed:
- **Apply rate limit to µTP protocol:** ✅
- **Apply rate limit to peers on LAN:** ✅

Tools → Options → BitTorrent:
- **Encryption mode:** Allow encryption
- **Seeding Limits → When inactive for:** `30` minutes → **Pause torrent**

Tools → Options → Speed → Queue:
- **Maximum active downloads:** `5`
- **Maximum active uploads:** `5`
- **Maximum active torrents:** `10`

> These follow [TRaSH Guides qBittorrent recommendations](https://trash-guides.info/Downloaders/qBittorrent/Basic-Setup/). Speed limits are left at unlimited since the VPN is the bottleneck. The inactivity timeout pauses stalled torrents so Sonarr/Radarr can detect them and automatically search for alternatives. Concurrent limits prevent overloading the NAS when many torrents are queued — the rest wait in line.

> **Mobile access?** The default UI is poor on mobile. This stack includes [VueTorrent](https://github.com/VueTorrent/VueTorrent)—enable it at Tools → Options → Web UI → Use alternative WebUI → `/vuetorrent`.

### Auth bypass for local networks

qBittorrent bans IPs after repeated failed login attempts (e.g., from scripts or Sonarr/Radarr reconnections). To prevent this, whitelist your Docker and LAN subnets:

Tools → Options → Web UI → Authentication:
- **Bypass authentication for clients on localhost:** ✅
- **Bypass authentication for clients in whitelisted IP subnets:** ✅
- **Whitelisted subnets:** `172.20.0.0/24, 192.168.1.0/24, 127.0.0.0/8`

> Adjust the `192.168.1.0/24` to match your LAN subnet. The `172.20.0.0/24` is the arr-stack Docker network — this ensures Sonarr, Radarr, and API scripts can always reach qBittorrent without auth failures.
>
> **Is this safe?** Yes — qBittorrent sits behind Gluetun's VPN tunnel with no ports exposed to the internet. Only devices on your LAN or Docker containers can reach it. The whitelisted subnets are all internal, so auth bypass doesn't widen the attack surface.

---

## SABnzbd Hardening (TRaSH Recommended)

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

### SABnzbd hostname whitelist (.lan DNS)

If using Pi-hole local DNS, add `sabnzbd.lan` to the hostname whitelist:
- Config (⚙️) → Special → **host_whitelist** → add `sabnzbd.lan`
- Save, then restart SABnzbd container

Or via SSH:
```bash
docker exec sabnzbd sed -i 's/^host_whitelist = .*/&, sabnzbd.lan/' /config/sabnzbd.ini
docker restart sabnzbd
```

---

## Bazarr Settings API (for scripting)

Only relevant if you're extending [configure-apps.sh](../scripts/configure-apps.sh) or driving Bazarr from your own scripts — the web UI handles all of this for you.

Bazarr's `/api/system/settings` takes **flat form keys**, not JSON. A JSON body is answered `204 No Content` and then silently discarded: the request looks like it succeeded, and nothing is written.

```bash
# Does nothing at all. Returns 204.
curl -X POST -H "X-API-KEY: $KEY" -H 'Content-Type: application/json' \
  --data '{"sonarr": {"http_timeout": 120}}' "http://NAS_IP:6767/api/system/settings"

# Works.
curl -X POST -H "X-API-KEY: $KEY" \
  --data-urlencode 'settings-sonarr-http_timeout=120' "http://NAS_IP:6767/api/system/settings"
```

Keys are `settings-<section>-<field>`, where the section and field names match the JSON from a `GET` on the same endpoint.

**Booleans must be lowercase `true` / `false`.** Bazarr type-checks the raw form value, so `True`, `on`, `1` and `0` are all rejected — and one bad value fails the *entire* POST, not just that key:

```
HTTP 406  "sonarr.only_monitored must is_type_of <class 'bool'> but it is True"
```

> A `406` is the good outcome when you're probing an unfamiliar field: it proves the request reached Bazarr's validator, and the message names the field and the type it wanted. A `204` proves nothing — it's also what a silently-discarded JSON body returns.

**Bazarr applies a write inside the POST** — in memory, then to `config.yaml` — and never restarts its process for it (read from v1.6.0: the only restarts on that path are its Sonarr/Radarr SignalR clients, which it bounces in-request when their connection settings change). Two writes are expensive rather than disruptive: any POST that changes the Sonarr/Radarr connection blocks until Bazarr can reach them — forever, if it can't, which is why `configure-apps.sh` bounds every request — and any POST carrying `languages-profiles` makes Bazarr rescan the whole library before answering. Read the current values and compare first; only POST when something actually differs, and only send `languages-profiles` when a profile changed.

### Sub-Zero mods use a separate key space

`settings-general-subzero_mods` cannot be written at all. Bazarr stores the value as a comma-separated string, but also lists `subzero_mods` among its array fields — so the form parser hands the validator a list while the schema demands a string, and every value fails:

```
HTTP 406  "general.subzero_mods must is_type_of <class 'str'> but it is ['remove_tags']"
```

Repeated keys and a comma-separated string fail identically. Mods are toggled one at a time through `subzero-<mod>` instead:

```bash
# Add a mod
curl -X POST -H "X-API-KEY: $KEY" \
  --data-urlencode 'subzero-OCR_fixes=true' "http://NAS_IP:6767/api/system/settings"

# Remove a mod — 'false' or an empty value
curl -X POST -H "X-API-KEY: $KEY" \
  --data-urlencode 'subzero-OCR_fixes=false' "http://NAS_IP:6767/api/system/settings"
```

Two traps worth knowing before you script this:

- **Stick to `true` and `false`.** Bazarr normalises the value before the toggle runs — numeric strings are cast to integers, then the literal strings `true` and `false` become booleans — and *then* adds on anything truthy, removes on anything falsy. So `true` and `1` add; `false`, `0` and an empty value remove; and any other non-empty string (`yes`, `off`) is truthy and **adds**, whatever it looks like it means.
- **Adding doesn't check membership.** Re-sending an already-enabled mod stores it twice: `subzero-emoji=true` against an enabled `emoji` gives `[…, 'emoji', 'emoji']`. Send only the mods that are actually missing.

Read the current set from `GET /api/system/settings` as `general.subzero_mods`, which comes back as an array even though it's stored as a string.

> Bazarr's source is in the container if you need to confirm any of this: `docker exec bazarr cat /app/bazarr/bin/bazarr/app/config.py`. `save_settings` does the parsing, `array_keys` lists the array fields, and the `Validator(...)` calls near the top declare each field's type.
