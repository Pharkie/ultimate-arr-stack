# Maintenance Guide

Day-to-day operations, multi-compose commands, and verification procedures.

## Multi-Compose Quick Reference

This stack uses multiple compose files. Here are common commands for each scenario.

### Core Stack Only

```bash
# Start / recreate
docker compose -f docker-compose.arr-stack.yml up -d

# Stop without removing (Pi-hole stops too: LAN DNS is down until you start it again)
docker compose -f docker-compose.arr-stack.yml stop

# View logs
docker compose -f docker-compose.arr-stack.yml logs -f --tail=50

# Pull latest images
docker compose -f docker-compose.arr-stack.yml pull
```

### Core + Traefik (.lan domains)

```bash
# Start both
docker compose -f docker-compose.arr-stack.yml -f docker-compose.traefik.yml up -d

# Pull images for both
docker compose -f docker-compose.arr-stack.yml -f docker-compose.traefik.yml pull
```

### Core + Traefik + Cloudflared (remote access)

Cloudflared has its own project name (`cloudflared`), so give it its own command. Adding its file to the one above would make the *last* file's name win, and run the whole stack as project `cloudflared`.

```bash
# Start all three
docker compose -f docker-compose.arr-stack.yml -f docker-compose.traefik.yml up -d
docker compose -f docker-compose.cloudflared.yml up -d
```

### Utilities (independent)

```bash
# Start utilities
docker compose -f docker-compose.utilities.yml up -d

```

### Tailscale (independent)

```bash
# Start / update Tailscale (uses its own compose project name, so this won't disturb the arr-stack)
docker compose -f docker-compose.tailscale.yml up -d
docker compose -f docker-compose.tailscale.yml pull
```

### All Stacks

The three `arr-stack` files go together; Cloudflared and Tailscale are separate projects and get their own commands.

```bash
# Start everything
docker compose \
  -f docker-compose.arr-stack.yml \
  -f docker-compose.traefik.yml \
  -f docker-compose.utilities.yml \
  up -d
docker compose -f docker-compose.cloudflared.yml up -d
docker compose -f docker-compose.tailscale.yml up -d

# Pull all images
docker compose \
  -f docker-compose.arr-stack.yml \
  -f docker-compose.traefik.yml \
  -f docker-compose.utilities.yml \
  pull
docker compose -f docker-compose.cloudflared.yml pull
docker compose -f docker-compose.tailscale.yml pull
```

> **Never use `docker compose down`** on the arr-stack file — it removes the Pi-hole container and you lose DNS (and internet) before you can bring it back up. Use `stop` instead, or just `up -d` to recreate.

---

## VPN Verification

Verify the VPN is working and your real IP is not exposed:

```bash
# Quick check
./scripts/check-vpn.sh

# Manual check
docker exec gluetun wget -qO- https://ipinfo.io/ip     # Should show VPN IP
docker exec qbittorrent wget -qO- https://ipinfo.io/ip  # Should match Gluetun's IP
```

The `check-vpn.sh` script checks DNS, compares Gluetun's exit IP with the host's own egress (measured from Sonarr, which is off the VPN), and checks that each tunnelled service (qBittorrent, Prowlarr, SABnzbd, FlareSolverr) exits through Gluetun. It exits non-zero on a leak, a DNS failure, or a service it can't measure. When Gluetun can't reach the internet at all, it also says why, from Gluetun's own log: no server answering for minutes (most likely an expired subscription or a revoked key, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#vpn-no-server-answers-expired-subscription-revoked-key-or-blocked-udp)), one server failing on its own, or the host's own connection down too. You can add it to cron for periodic monitoring (the Uptime Kuma setup in [UTILITIES.md](UTILITIES.md#the-vpn-check-and-why-it-is-a-push-monitor) also gets you alerted):

```bash
# Check every 5 minutes, log failures
*/5 * * * * $NAS_STACK_DIR/scripts/check-vpn.sh >> /var/log/vpn-check.log 2>&1
```

---

## Backups

Run periodic backups of service configs:

```bash
# Manual backup
./scripts/arr-backup.sh --tar

# Encrypted backup
./scripts/arr-backup.sh --tar --encrypt
```

See [Backup & Restore](BACKUP.md) for full details and [Restore Guide](RESTORE.md) for recovery procedures.

---

## Queue Cleanup

Torrents frequently stall (dead seeders, stuck metadata, failed imports). The cleanup script removes stuck items, blocklists them, and triggers fresh searches:

```bash
# Dry run — see what would be removed
./scripts/queue-cleanup.sh

# Actually remove stuck items
./scripts/queue-cleanup.sh --apply

# With verbose output
./scripts/queue-cleanup.sh --apply -v
```

### Automated (cron)

Add to NAS crontab (`crontab -e`):

```bash
# Thursday 2am — clean stuck downloads weekly
0 2 * * 4 $NAS_STACK_DIR/scripts/queue-cleanup.sh --apply >> $NAS_STACK_DIR/logs/queue-cleanup.log 2>&1
```

### What gets removed

- Downloads stalled with no connections (dead seeders)
- Torrents stuck downloading metadata (no peers)
- Failed imports (downloaded but can't import)
- Blocked imports (already imported, not an upgrade, missing episodes in pack)
- Import-pending items with warnings (executable files, quality not accepted)
- Items at 0% progress for more than 24 hours

Items with **any** download progress are never removed, even if slow.

**Left alone: downloads waiting for a manual import because Sonarr or Radarr matched them by ID.** An ID search lets the indexer say which show or film a release is, so Sonarr grabs releases whose names it can't recognise (a Netflix release of a Korean show under its romanised title, say). When one finishes, Sonarr won't import it on its own, by design, in case the indexer was wrong, and sends a "Needs manual import" notice. The file is usually fine, so the sweep doesn't blocklist it. It names each one in the weekly notice instead, as a `warning`, until you import it (Activity → Queue → the person icon). A grab made from Interactive Search imports normally.

Removed releases are blocklisted so the same broken release won't be grabbed again. A fresh search is triggered for each affected series/movie to find better-seeded alternatives.

---

## Stuck Requests

A request can sit undownloaded for weeks while every step reports success. Three naming authorities are involved and nothing checks that a request turned into monitored, findable episodes: Seerr follows TMDB, Sonarr follows TVDB, and release groups name files however they like. The case that prompted this check is in [TROUBLESHOOTING.md](TROUBLESHOOTING.md#seerr-request-stuck-for-weeks-while-the-release-exists-three-naming-authorities). The commonest cause is duller still: Sonarr and Radarr only ever grab from their RSS sync and never search the backlog, so a release that RSS missed (an indexer in backoff that hour, a post outside the window) is never found until somebody clicks Search. Two films sat 130 and 171 days that way with approved releases on NZBgeek the whole time. The opposite failure looks like success to every step: three shows share the plain title *Queer as Folk*, NZBgeek's untagged `Queer.as.Folk.S01Exx` names belong to the US run and the 2022 reboot, and Sonarr files an untagged name under whichever library series carries the title, so the UK series' season 1 was "imported" as the reboot's first episode and the US run's episodes 2 to 8. Seerr and Jellyfin called it done; only the runtimes (44 to 55 minutes against TVDB's 32 to 36) said otherwise.

`scripts/check-stuck-requests.sh` reads Seerr's requests, asks Sonarr and Radarr what became of each one, runs their own release search for anything never grabbed, compares every imported episode file's length with TVDB's runtime for its episode, and posts one `info` notice to the Home Assistant panel (tag `stuck-requests`, so each day's notice replaces the last). With `--apply` it also queues the search RSS missed, which is the fix for that case. It posts nothing when nothing is stuck.

```bash
./scripts/check-stuck-requests.sh                 # dry run: report only
./scripts/check-stuck-requests.sh --post          # post the notice if anything is stuck
./scripts/check-stuck-requests.sh --apply         # queue a search for what RSS missed
./scripts/check-stuck-requests.sh --post --apply -v
./scripts/check-stuck-requests.sh --test          # post a test notice, to prove the webhook
```

### What it reports

Each line names the title, who requested it, how long ago, and what to do:

- **Seerr never handed it over**, or marked the request *Failed* (the hand-off did not go through). Retry it from Seerr → Requests.
- **Sonarr monitored nothing.** Seerr asked for season numbers the TVDB record doesn't have (Seerr sent "season 10"; TVDB numbers that show's seasons 1964 … 2026), or every requested season is unmonitored. Re-request from the TVDB-linked entry, or monitor the season in Sonarr.
- **Never grabbed.** A monitored, available movie in Radarr for `MOVIE_STUCK_DAYS` (default 7) or more days with no file and no history, or episodes that aired `STUCK_DAYS` (default 3) or more days ago with no file and no grab in Sonarr's history. Each gets the app's own release search (what Interactive Search shows), and the line says which of these it is, in order:
  1. **A release it would take exists.** RSS missed it; nobody ever searched. `--apply` queues `MoviesSearch` or `EpisodeSearch`, and the line says so; if the item is still there tomorrow, the download failed.
  2. **Releases exist but every one is rejected.** The rejection reasons are quoted: fix the quality profile or custom formats, or decline.
  3. **Nothing, while Prowlarr has an indexer in failure backoff.** The zero is not trusted; try again later.
  4. **Nothing.** A Prowlarr search by title sorts what is left: only `S01E01`-style releases means a TV broadcast with a TMDB *movie* entry, which Radarr can never match (delete it and request the series); for Sonarr, releases for the missing seasons under the title means the episode numbering differs from TVDB's (if they are this show and not a same-named one); none at all means no enabled indexer carries it, or names it differently, as "70 Up" for *The Up Series*.

  A film still in cinemas with no home release date yet, or whose home release is still to come, is waiting correctly and is not reported.
- **A monitored Sonarr series with no monitored season**, whether or not a request points at it (catches manual adds).
- **An imported file that cannot be its episode.** Its length is `RUNTIME_TOLERANCE` percent (default 40) or more off TVDB's runtime for the episode, and another series in the Sonarr library shares the plain title (the title with a trailing bracketed country or year removed), which is how the wrong show gets filed there. One line per series names each file with its scene name and both runtimes ("S01E01 runs 55:01 against TVDB's 32 min"): delete the files in Sonarr and search again, and check the season's other files, since a smaller difference hides the same mistake (five of the eight Queer as Folk files were 29 to 39 percent long). Without a same-named series the mismatch is shown under `-v` only, because TVDB's slot lengths (60 minutes for a 44-minute drama) and extended episodes are off by that much on their own. Multi-episode files, files Sonarr has no media info for, and episodes TVDB gives no runtime are not compared.

Thresholds come from the environment: `STUCK_DAYS=5 MOVIE_STUCK_DAYS=14 MAX_SEARCHES=20 SEARCH_PAUSE=3 RUNTIME_TOLERANCE=40 ./scripts/check-stuck-requests.sh`. Every release search hits the indexers for real, so they run `SEARCH_PAUSE` seconds apart and stop at `MAX_SEARCHES` a run: a burst of fifteen put NZBgeek and EZTV into Prowlarr's five-minute backoff, and every search in that window returned a zero that read as "nobody carries it". Without Prowlarr a zero can't be checked against backoff and the line says so. A film that isn't out yet, and an episode that was grabbed but failed to download, are left to Radarr, Sonarr and the [queue cleanup](#queue-cleanup).

### Automated (cron)

Daily is the point: a request that goes quiet shows up in the panel the day it passes the threshold, not five weeks later. On UGOS the admin user cannot write its own crontab, so install it the same way as the [audiobook mirror](#audiobooks-on-the-tv):

```bash
crontab -l > /tmp/cron.new
echo '30 8 * * * $NAS_STACK_DIR/scripts/check-stuck-requests.sh --post --apply >> $NAS_STACK_DIR/logs/check-stuck-requests.log 2>&1' >> /tmp/cron.new
sudo crontab -u <user> /tmp/cron.new
```

Prove the webhook once with `--test` and look at the Home Assistant panel: HA answers 200 to any webhook id, so the script's "posted" line only proves the POST arrived. A notice stays in the panel after you fix the requests, until you dismiss it, because nothing is posted on a clean day.

---

## Playback Formats

The custom formats `configure-apps.sh` sets up judge a release by its title, once, when it is grabbed. They never look at a file already on disk, and they can't see a format the title doesn't name. One library held twelve Dolby Vision Profile 5 episodes grabbed before the Profile 5 format existed, and a Simpsons episode whose release was titled `1080p.web.h264` but held 2160p Profile 5. On a Fire TV in the Jellyfin client each one showed a green and magenta picture for the whole episode.

`scripts/check-playback-formats.sh` reads what Sonarr's and Radarr's own mediainfo says each file is, and posts one `info` notice to the Home Assistant panel (tag `playback-formats`) naming the files to replace. It posts nothing when there are none.

```bash
./scripts/check-playback-formats.sh                 # dry run: report only
./scripts/check-playback-formats.sh --post          # post the notice if anything is found
./scripts/check-playback-formats.sh --apply         # queue a search for Profile 5 files
./scripts/check-playback-formats.sh --post --apply -v
./scripts/check-playback-formats.sh --test          # post a test notice, to prove the webhook
```

It reports two formats, the two that failed in the Jellyfin Android TV client on a Fire TV Cube when one of each format in the library was played:

- **Dolby Vision Profile 5** (mediainfo `DV`: Dolby Vision with no HDR10 base layer). The picture is green and magenta. The file scores `-1000` on the `DV (Profile 5)` format through its `[DV]` name, so any release of the same quality without it counts as an upgrade, and `--apply` queues the search that finds one. Netflix and Disney+ publish 4K only as Profile 5, so for their shows the search often takes nothing, because a 1080p release isn't an upgrade. The file is then reported again the next week: pick a 1080p release from its interactive search.
- **DTS with a 6.1 track** (DTS-ES, DTS-HD MA 6.1). The client passes DTS through as the core, and a 6.1 core stopped at 0 ms. The `DTS 6.1` format reads release titles only, so the file still scores 0 and a search would take nothing. Replace it from the interactive search.

Files with no mediainfo yet are counted but not judged.

These play, but not at their best, so they are not reported. Each was tested on a Fire TV Cube 3rd gen with the Jellyfin Android TV client 0.19.10:

| Format | What happens |
|---|---|
| Dolby Vision Profile 7 (UHD Blu-ray remuxes) | Transcoded, picture tone-mapped to SDR. The `DV HDR10 (Profile 8.1)` format no longer scores them. |
| TrueHD, with or without Atmos | Converted to AAC: lossy, and no Atmos |
| DTS-HD MA 5.1 and 7.1 | Direct play; the receiver gets the DTS core, not the lossless stream |
| HDR10+ with no Dolby Vision | Remuxed, video copied; played |

Kodi on the same box passes TrueHD and DTS-HD through to the receiver losslessly, because it packs the bitstream itself.

### Automated (cron)

Weekly is enough: a bad file sits until somebody plays it, and the notice names it before then. Install it the same way as the [stuck-request check](#stuck-requests):

```bash
crontab -l > /tmp/cron.new
echo '0 9 * * 0 $NAS_STACK_DIR/scripts/check-playback-formats.sh --post --apply >> $NAS_STACK_DIR/logs/check-playback-formats.log 2>&1' >> /tmp/cron.new
sudo crontab -u <user> /tmp/cron.new
```

---

## Executable Scan

Public torrent indexers sometimes serve a Windows executable padded to episode size and named after a real release group. qBittorrent rejects the usual extensions up front and Sonarr/Radarr refuse to import a release containing one — but a refused import leaves the payload in `/data/torrents`, inert on the NAS and one SMB browse away from a machine where it isn't. This reports anything already on disk:

```bash
./scripts/scan-executables.sh          # lists findings, exit 1 if any
./scripts/scan-executables.sh --quiet  # findings only, for cron
```

Weekly is plenty. Pair it with an Uptime Kuma push monitor the same way as the VPN check, or just log it:

```bash
0 4 * * 0 $NAS_STACK_DIR/scripts/scan-executables.sh --quiet >> $NAS_STACK_DIR/logs/scan-executables.log 2>&1
```

Anything it finds: verify, delete, then blocklist the release in Sonarr/Radarr (Activity → Queue → remove with **Blocklist** ticked) so the same grab isn't repeated. The e2e suite asserts the same steady state in `tests/e2e/media-hygiene.spec.ts`.

## Audiobooks on the TV

Jellyfin classifies a `.m4b` as an AudioBook, and the Android TV app cannot play AudioBook items — only the web client can. `scripts/audiobooks-tv-mirror.sh` hardlinks every `.m4b` in the audiobook folders (including the two `other` download lanes) as a `.m4a` under `/data/media/audiobooks-tv/`, where a *Music*-type Jellyfin library sees a plain audio track the TV plays. Same bytes, no extra space, originals untouched. It prunes a link whose source is gone.

```bash
./scripts/audiobooks-tv-mirror.sh --dry-run   # what it would link or prune
./scripts/audiobooks-tv-mirror.sh
```

On UGOS the admin user cannot write its own crontab (`crontab -` fails with `mkstemp: Permission denied`, and writing the spool file by hand is silently ignored — see [UTILITIES.md](UTILITIES.md#the-vpn-check-and-why-it-is-a-push-monitor)). Install it via root:

```bash
crontab -l > /tmp/cron.new
echo '*/15 * * * * $NAS_STACK_DIR/scripts/audiobooks-tv-mirror.sh >> $NAS_STACK_DIR/logs/audiobooks-tv-mirror.log 2>&1' >> /tmp/cron.new
sudo crontab -u <user> /tmp/cron.new
```

Trust it only once `logs/audiobooks-tv-mirror.log` shows a run.

The Jellyfin side is one library: Dashboard → Libraries → add a *Music* library named e.g. "Audiobooks (TV)" over `/data/media/audiobooks-tv` — see [APP-CONFIG.md § 4.1](APP-CONFIG.md#41-jellyfin-media-server). Chapter navigation exists only in the web's Books library; the TV gets resume.

## Health Checks

All services have Docker healthchecks. Check status:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

Services showing `(unhealthy)` may need attention. Common causes:
- **Gluetun unhealthy**: VPN connection lost — check `docker logs gluetun`
- **qBittorrent/SABnzbd/Prowlarr unhealthy**: Often caused by Gluetun being down (they share its network). Sonarr/Radarr are on the bridge and not affected by a gluetun outage.
- **Pi-hole unhealthy**: DNS resolution failing — check upstream DNS config

---

## Updating Images

Check for available updates:

```bash
# New versions arrive as tag bumps in this repo (Renovate opens a PR for each):
# git pull, then pull and recreate what changed

# Manual check
docker compose -f docker-compose.arr-stack.yml pull
# Review what changed, then recreate
docker compose -f docker-compose.arr-stack.yml up -d
```

**Before bumping a service that owns a database** (Pi-hole's gravity/FTL config, the \*arrs' SQLite), back up its config volume first — a minor-version bump can migrate the DB irreversibly:

```bash
docker run --rm -v <project>_<service>-config:/src:ro -v "$PWD/backups":/bak \
  alpine tar czf /bak/<service>-config-backup-$(date +%Y%m%d).tgz -C /src .
# e.g. arr-stack_pihole-etc-pihole  →  backups/pihole-config-backup-YYYYMMDD.tgz
```

**Pi-hole and Cloudflared notes:** recreating Pi-hole briefly drops LAN DNS (~20-30s) — expected; verify `.lan` and external resolution after. Cloudflared runs as its **own compose project** (`-f docker-compose.cloudflared.yml`), so bump it with that file, not via the arr-stack project.

See [Upgrading Guide](UPGRADING.md) for version-specific upgrade notes.
