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

The backup script (`scripts/arr-backup.sh`) backs up **essential configs only** - small files that are hard to recreate:

| Volume | Size | Contents |
|--------|------|----------|
| gluetun-config | ~7MB | VPN provider settings |
| qbittorrent-config | ~9MB | Client settings, categories |
| prowlarr-config | ~22MB | Indexer configs, API keys |
| bazarr-config | ~2MB | Subtitle provider credentials |
| uptime-kuma-data | ~14MB | Monitor configurations |
| pihole-etc-dnsmasq | ~4KB | Custom DNS settings |
| seerr-config | ~5MB | User accounts, requests |

**Total: ~60MB uncompressed, ~13MB compressed**

## What's NOT Backed Up

Large volumes that regenerate automatically are excluded:

| Volume | Size | Why Excluded |
|--------|------|--------------|
| jellyfin-config | ~407MB | Re-scan library to rebuild metadata |
| sonarr-config | ~43MB | Re-scan library to rebuild |
| radarr-config | ~110MB | Re-scan library to rebuild |
| pihole-etc-pihole | ~138MB | Blocklists auto-download on startup |
| jellyfin-cache | ~43MB | Transcoding cache, fully regenerates |
| duc-index | ~20MB | Disk usage index, regenerates on restart |

> **Note:** If you want to preserve watch history (Jellyfin) or avoid re-scanning, you can manually backup these volumes using the same docker command shown below.

---

## Running a Backup

### On the NAS

```bash
# SSH into your NAS first, then:
cd /volume1/docker/arr-stack
./scripts/arr-backup.sh --tar
```

Output:
```
=== Arr-Stack Backup ===
Volume prefix: arr-stack_*
Backup dir:    /tmp/arr-stack-backup-20241217

Backing up gluetun-config... OK (7.1M)
Backing up qbittorrent-config... OK (8.9M)
...
Summary: 8 backed up, 0 skipped, 0 failed
Total size: 58M

Created: /tmp/arr-stack-backup-20241217.tar.gz (13M)
```

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
2. SSH into your NAS and stop the services:
   ```bash
   docker compose -f docker-compose.arr-stack.yml down
   ```
3. Extract backup and restore each volume:
   ```bash
   tar -xzf backup.tar.gz
   cd arr-stack-backup-20241217

   for dir in */; do
     vol="arr-stack_${dir%/}"
     echo "Restoring $vol..."
     docker run --rm \
       -v "$(pwd)/$dir":/source:ro \
       -v "$vol":/dest \
       alpine cp -a /source/. /dest/
   done
   ```
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

---

## Script Options

```bash
./scripts/arr-backup.sh [OPTIONS] [BACKUP_DIR]

Options:
  --tar           Create .tar.gz archive (recommended)
  --prefix NAME   Override volume prefix (default: auto-detect)

Examples:
  ./scripts/arr-backup.sh --tar                    # Default location
  ./scripts/arr-backup.sh --tar /path/to/backup    # Custom location
  ./scripts/arr-backup.sh --prefix media-stack     # Custom prefix
```

### Volume Prefix Auto-Detection

The script auto-detects your volume prefix from running containers. If you cloned the repo to a different directory (e.g., `media-stack` instead of `arr-stack`), it will detect this automatically.

If auto-detection fails, use `--prefix`:
```bash
./scripts/arr-backup.sh --tar --prefix media-stack
```

### Request Manager Detection

The script auto-detects which request manager volume exists and backs it up:
- `seerr-config` (Seerr)
- `overseerr-config` (Overseerr, if used instead)

---

## Automated Daily Backup

A cron job runs daily at 6am, backing up to USB:

```bash
# View current cron
sudo crontab -l

# Default schedule (already configured):
0 6 * * * /volume1/docker/arr-stack/scripts/arr-backup.sh --tar /mnt/arr-backup >> /var/log/arr-backup.log 2>&1
```

**Features:**
- ✓ Backs up to `/tmp` first (reliable), then moves to USB
- ✓ Checks actual tarball size vs destination space before moving
- ✓ Falls back to `/tmp` if USB lacks space (with warning)
- ✓ Keeps 7 days of backups on USB, auto-rotates old ones
- ✓ EXIT trap ensures critical services stay running no matter what
- ✓ Does NOT stop services during backup

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

### Backup too large
If backup exceeds ~60MB, check if optional volumes were accidentally included. The script only backs up essential configs by default.
