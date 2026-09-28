# Backup & Restore

This stack uses Docker named volumes for service data. This guide covers backing up and restoring your configuration.

## Prerequisites

**USB Drive for Automated Backups (Recommended)**

For the automated daily backup to work, plug a USB drive into your NAS:

1. **Format** the USB drive (ext4 recommended, FAT32 works but has file size limits)
2. **Mount** it at `/mnt/arr-backup` (or update the cron job path)
3. The script will automatically keep 7 days of backups and rotate old ones

> Without a USB drive, backups go to `/tmp` which is cleared on reboot. You'd need to manually pull backups off-NAS.

---

## What Gets Backed Up

The backup script (`scripts/arr-backup.sh`) backs up the configs that are hard to recreate, and the Sonarr, Radarr and Jellyfin databases. Sizes are from one NAS (2026-09-29); yours scale with your library.

| Volume | Size | Contents |
|--------|------|----------|
| gluetun-config | ~7MB | VPN provider settings |
| qbittorrent-config | ~8MB | Client settings, categories |
| sabnzbd-config | ~28MB | Usenet provider credentials and settings |
| prowlarr-config | ~122MB | Indexer configs, API keys |
| bazarr-config | ~16MB | Subtitle provider credentials |
| uptime-kuma-data | ~35MB | Monitor configurations |
| seerr-config | ~7MB | User accounts, requests |
| sonarr-config | ~7.5MB | Sonarr's own backup zip: `config.xml` and `sonarr.db` |
| radarr-config | ~4MB | Radarr's own backup zip: `config.xml` and `radarr.db` |
| jellyfin-config | ~57MB (~18MB compressed) | `config/`, `root/` (library definitions), `plugins/`, and a snapshot of `data/jellyfin.db` |
| `.env` | | Saved as `dot-env` |

**Total: ~290MB uncompressed, ~66MB compressed a night.** Seven days kept on the USB drive is about 0.5GB. The whole run took 76 seconds.

### Why Sonarr, Radarr and Jellyfin get special handling

Their volumes hold what a re-scan cannot rebuild: quality profiles and custom-format scores, naming formats, download-client and indexer settings, and Jellyfin's users and watch history. They also hold live SQLite databases in WAL mode, so a plain file copy taken while the app writes can pair a half-updated `.db` with the wrong `-wal`. In a test against a throwaway database under a busy writer, 26 of 30 slowed file copies came out torn. None of these three is copied as files:

- **Sonarr and Radarr:** the script runs each app's own **Backup** command through its API (`POST /api/v3/command`, the same as *System → Backup → Backup Now*), copies the zip it writes, then deletes the app's copy through the same API. Manual backups never rotate on their own, so every night's would otherwise stay in the volume. The API key is read from the container's `config.xml`, so there is nothing to configure. The app must be running: if it isn't, that volume fails and the script says so.
- **Jellyfin:** the script copies the database with SQLite's online backup API from a **read-only** mount, which gives one consistent snapshot while Jellyfin keeps writing, WAL included. Jellyfin 12's own backup (`/Backup/Create`) was not used: it needs an admin API key the stack doesn't hold, it has no delete endpoint (its zips would pile up in the volume), and it stores tables as JSON that only its own restore can read.

Each database copy is then checked with `PRAGMA integrity_check`, and a copy that fails is left out of the archive and counted as a failure. The check runs in the official `python:3.13-alpine` image (none of the app images has `sqlite3`), which Docker pulls on the first run.

What the apps leave behind: Sonarr and Radarr keep an empty `Backups/manual/` folder. Their own weekly scheduled backups (`Backups/scheduled/`) carry on as before and rotate themselves (28 days by default). The script mounts Jellyfin's volume read-only, so nothing is written to it.

The other volumes are still copied as plain files, including the SQLite databases that Prowlarr, Bazarr, Uptime Kuma and Seerr keep in them.

## What's NOT Backed Up

What regenerates on its own is excluded:

| Volume or folder | Size | Why Excluded |
|--------|------|--------------|
| jellyfin-config: `metadata/`, `log/`, `data/subtitles`, `data/attachments` | ~3GB | Images and metadata re-download on the next library scan; the rest are logs and extracted subtitles and fonts |
| sonarr-config, radarr-config: `MediaCover/`, `logs/`, `logs.db` | ~0.7GB | Posters re-download; logs |
| pihole-etc-pihole | ~138MB | Blocklists auto-download on startup |
| jellyfin-cache | ~43MB | Transcoding cache, fully regenerates |
| duc-index | ~20MB | Disk usage index, regenerates on restart |

---

## Running a Backup

### On the NAS

```bash
# SSH into your NAS first, then:
cd $NAS_STACK_DIR
./scripts/arr-backup.sh --tar
```

Output:
```
=== Arr-Stack Backup ===
Volume prefix: arr-stack_*
Backup dir:    /tmp/arr-stack-backup-20260929

Backing up .env... OK
Backing up gluetun-config... OK (7.1M)
Backing up qbittorrent-config... OK (8.2M)
...
Backing up sonarr-config... OK (7.4M, sonarr.db integrity ok)
Backing up radarr-config... OK (3.7M, radarr.db integrity ok)
Backing up jellyfin-config... OK (57M, data/jellyfin.db integrity ok)

Summary: 11 backed up, 0 skipped, 0 failed
Total size: 290M

Created: /tmp/arr-stack-backup-20260929.tar.gz (66M)
```

If anything fails, the line says why (`FAILED (sonarr is not running)`, `FAILED (... did not pass its check)`), the archive is still written with everything else, and the script **exits 1**, so cron and anything that reads its exit status see it.

### Copying Off-NAS

**Ugreen NAS** (scp doesn't work with /tmp):
```bash
ssh user@nas "cat /tmp/arr-stack-backup-*.tar.gz" > ./backup.tar.gz
```

**Other systems** (Synology, QNAP, Linux):
```bash
scp user@nas:/tmp/arr-stack-backup-*.tar.gz ./backup.tar.gz
```

> **Important:** Backups in `/tmp` are cleared on reboot. Copy off-NAS promptly!

---

## Restore

### Full Restore (New Installation)

1. Deploy the stack normally (see [Setup Guide](SETUP.md))
2. SSH into your NAS and stop the services (`stop`, never `down`):
   ```bash
   docker compose -f docker-compose.arr-stack.yml stop
   ```
3. Extract backup and restore each volume (an `--encrypt` backup ends `.tar.gz.gpg`: run `gpg --decrypt backup.tar.gz.gpg > backup.tar.gz` first):
   ```bash
   tar -xzf backup.tar.gz
   cd arr-stack-backup-20241217

   for dir in */; do
     case "${dir%/}" in sonarr-config|radarr-config|jellyfin-config) continue ;; esac
     vol="arr-stack_${dir%/}"
     echo "Restoring $vol..."
     docker run --rm \
       -v "$(pwd)/$dir":/source:ro \
       -v "$vol":/dest \
       alpine cp -a /source/. /dest/
   done
   ```
   Sonarr, Radarr and Jellyfin are skipped here: restore them as [RESTORE.md](RESTORE.md#restore-sonarr-and-radarr) describes.
4. Start services:
   ```bash
   docker compose -f docker-compose.arr-stack.yml up -d
   ```

### Single Volume Restore

```bash
# On NAS via SSH - example: restore seerr config
docker compose -f docker-compose.arr-stack.yml stop seerr

docker run --rm \
  -v ./backup/seerr-config:/source:ro \
  -v arr-stack_seerr-config:/dest \
  alpine cp -a /source/. /dest/

docker compose -f docker-compose.arr-stack.yml start seerr
```

This works for every volume except sonarr-config, radarr-config and jellyfin-config: see [Restore Sonarr and Radarr](RESTORE.md#restore-sonarr-and-radarr) and [Restore Jellyfin](RESTORE.md#restore-jellyfin).

---

## Script Options

```bash
./scripts/arr-backup.sh [OPTIONS] [BACKUP_DIR]

Options:
  --tar           Create .tar.gz archive (recommended)
  --encrypt       GPG-encrypt the tarball, symmetric (requires --tar);
                  the archive is named .tar.gz.gpg
  --prefix NAME   Override volume prefix (default: auto-detect)
  --usb DIR_NAME  Save to DIR_NAME on whichever USB drive is under /mnt/@usb/sd*/
                  (device letters change on reboot, so don't hardcode one)

Examples:
  ./scripts/arr-backup.sh --tar                    # Default location
  ./scripts/arr-backup.sh --tar /path/to/backup    # Custom location
  ./scripts/arr-backup.sh --tar --encrypt          # Encrypted tarball
  ./scripts/arr-backup.sh --tar --usb arr-backups  # Find the USB drive, save to arr-backups/
  ./scripts/arr-backup.sh --prefix media-stack     # Custom prefix
```

### Volume Prefix Auto-Detection

The compose files pin every volume's name to `arr-stack_<volume>`, so the prefix is `arr-stack` whatever your deploy directory is called. The script still detects it from the running gluetun container, and `--prefix` is there for volumes created under another prefix before the names were pinned:
```bash
./scripts/arr-backup.sh --tar --prefix media-stack
```

### Request Manager Detection

The script auto-detects which request manager volume exists and backs it up:
- `seerr-config` (Seerr)
- `overseerr-config` (Overseerr, if used instead)

---

## Automated Daily Backup

Nothing in the repo installs this; add a cron job yourself, e.g. daily at 6am to USB:

```bash
# View current cron
sudo crontab -l

# Example entry:
0 6 * * * $NAS_STACK_DIR/scripts/arr-backup.sh --tar /mnt/arr-backup >> /var/log/arr-backup.log 2>&1
```

**Features:**
- ✓ Backs up to `/tmp` first (reliable), then moves to USB
- ✓ Checks actual tarball size vs destination space before moving
- ✓ Falls back to `/tmp` if USB lacks space (with warning)
- ✓ Keeps 7 days of backups on USB, auto-rotates old ones (`.tar.gz` and encrypted `.tar.gz.gpg`)
- ✓ EXIT trap ensures critical services stay running no matter what
- ✓ Does NOT stop services during backup; Sonarr, Radarr and Jellyfin databases are copied consistently while they run
- ✓ Exits 1 if any volume failed, after writing the archive of the rest

**To modify the schedule:**
```bash
sudo crontab -e
# Change "0 6" to preferred hour (e.g., "0 4" for 4am)
```

---

## Troubleshooting

### "Permission denied" errors
The backup script runs docker containers which handle permissions internally. If you see permission errors, ensure:
- You're in the docker group: `groups` should show `docker`
- Docker daemon is running: `docker ps`

### "Volume not found"
- Ensure services have been started at least once (volumes are created on first run)
- Check the volume prefix matches: `docker volume ls | grep config`

### `sonarr-config` or `radarr-config` FAILED
- `(sonarr is not running)`: the app has to be up, because the script asks it for the backup. Start it and re-run.
- `(... Backup command not finished after 300s)`: the app is busy or stuck. Check *System → Tasks*, or give it longer with `ARR_BACKUP_API_TIMEOUT=600`.
- `(backed up, but ... is still in sonarr)`: the copy is in the archive, but the app's zip could not be deleted. Delete it under *System → Backup*.

### `jellyfin-config` FAILED
The lines under it say why. `integrity_check` means the snapshot of the database is damaged, which usually means the live database is too: check Jellyfin's log before anything else.

### Backup too large
If the archive is far over ~70MB compressed, extract it and check what grew: `du -sh arr-stack-backup-*/*`. Jellyfin's `metadata/` and the *arr `MediaCover/` folders are never included.
