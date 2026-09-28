# Restore Guide

Step-by-step procedures for restoring from backups. See [Backup & Restore](BACKUP.md) for backup procedures and what's included.

## Prerequisites

- A backup tarball from `scripts/arr-backup.sh --tar` (or `--encrypt`)
- Docker installed and the stack repo cloned (see [Setup Guide](SETUP.md))
- SSH access to your NAS

---

## Restore from Volume Backup

These steps restore service configs backed up by `scripts/arr-backup.sh`.

### 1. Transfer Backup to NAS

```bash
# From your local machine:
scp backup.tar.gz user@nas:/tmp/

# Ugreen NAS (if scp to /tmp doesn't work):
cat backup.tar.gz | ssh user@nas "cat > /tmp/backup.tar.gz"
```

### 2. Decrypt (if encrypted)

A backup created with `--encrypt` ends in `.tar.gz.gpg`. Keep that name when you copy it, then decrypt:

```bash
gpg --decrypt /tmp/backup.tar.gz.gpg > /tmp/backup.tar.gz
```

> **Older encrypted backups:** before this was fixed, `--encrypt` with a destination directory or `--usb` saved the encrypted file as `.tar.gz`, and `tar` rejects it ("not in gzip format"). If `file backup.tar.gz` reports `PGP symmetric key encrypted data`, decrypt it as above before extracting.

### 3. Extract

```bash
cd /tmp
tar -xzf backup.tar.gz
ls arr-stack-backup-*/
# Should show: gluetun-config/ qbittorrent-config/ prowlarr-config/ etc.,
# plus sonarr-config/ radarr-config/ jellyfin-config/ from backups made since
# the databases were added
```

### 4. Deploy Fresh Stack

If restoring to a new system, deploy first so Docker creates the volumes:

```bash
cd $NAS_STACK_DIR
cp .env.example .env
# Edit .env with your settings
docker compose -f docker-compose.arr-stack.yml up -d
docker compose -f docker-compose.arr-stack.yml stop   # stop, never down
```

### 5. Restore Volumes

```bash
cd /tmp/arr-stack-backup-*

for dir in */; do
  # These three hold databases and restore their own way (below)
  case "${dir%/}" in sonarr-config|radarr-config|jellyfin-config) continue ;; esac
  vol="arr-stack_${dir%/}"
  echo "Restoring $vol..."
  docker run --rm \
    -v "$(pwd)/$dir":/source:ro \
    -v "$vol":/dest \
    alpine cp -a /source/. /dest/
done
```

Then restore [Sonarr and Radarr](#restore-sonarr-and-radarr) and [Jellyfin](#restore-jellyfin), if the backup has them.

### 6. Start Services

```bash
cd $NAS_STACK_DIR
docker compose -f docker-compose.arr-stack.yml up -d
```

### 7. Verify

- Check all containers are running: `docker ps`
- Access each service UI and confirm settings are restored
- Run `./scripts/check-vpn.sh` to verify VPN is working

---

## Restore a Single Volume

To restore just one service (e.g., after corrupted config):

```bash
# Stop the service
docker compose -f docker-compose.arr-stack.yml stop seerr

# Restore from backup
docker run --rm \
  -v /tmp/arr-stack-backup-20250101/seerr-config:/source:ro \
  -v arr-stack_seerr-config:/dest \
  alpine cp -a /source/. /dest/

# Restart
docker compose -f docker-compose.arr-stack.yml start seerr
```

Not for sonarr-config, radarr-config or jellyfin-config: they follow.

---

## Restore Sonarr and Radarr

The backup holds each app's own backup zip, e.g. `sonarr-config/sonarr_backup_v4.0.20.3014_2026.09.29_06.00.47.zip`, with `config.xml` (API key, port, login settings) and the database (series or movies, quality profiles, custom formats, naming, download clients, indexers). Restore it into the **same version of the app or a newer one**: the version is in the file name, and an older version can't open a newer database.

**From the app's UI** (simplest; the app must be running):

1. Copy the zip to the computer you browse from.
2. In Sonarr, go to *System → Backup → Restore Backup*, choose the zip, and restore. On a fresh install, create the login it asks for first.
3. Sonarr restarts on the restored database. Log in with the account from the backup.

The same for Radarr, with `radarr-config/radarr_backup_*.zip`.

**From the command line** (the app stopped; shown for Sonarr, for Radarr swap `sonarr` for `radarr` throughout):

```bash
cd /tmp/arr-stack-backup-*
docker compose -f $NAS_STACK_DIR/docker-compose.arr-stack.yml stop sonarr

# Remove the old database's -wal/-shm first: a leftover -wal would be replayed
# onto the restored database and corrupt it. 1000:1000 is PUID:PGID from .env.
docker run --rm \
  -v "$(pwd)/sonarr-config":/backup:ro \
  -v arr-stack_sonarr-config:/config \
  alpine sh -c 'cd /config && rm -f sonarr.db-wal sonarr.db-shm &&
    unzip -o /backup/sonarr_backup_*.zip config.xml sonarr.db &&
    chown 1000:1000 config.xml sonarr.db'

docker compose -f $NAS_STACK_DIR/docker-compose.arr-stack.yml start sonarr
```

Posters (`MediaCover/`) are not in the backup; the app downloads them again.

---

## Restore Jellyfin

The backup's `jellyfin-config/` has the same layout as the volume: `config/` (server settings, users), `root/` (library definitions), `plugins/`, and `data/jellyfin.db` (items, users, watch history). Restore it into the **same Jellyfin version or a newer one**: Jellyfin migrates the database forward on start, but an older version can't open a newer one.

```bash
cd /tmp/arr-stack-backup-*
docker compose -f $NAS_STACK_DIR/docker-compose.arr-stack.yml stop jellyfin

# Remove the old database's -wal/-shm first: a leftover -wal would be replayed
# onto the restored database and corrupt it.
docker run --rm \
  -v "$(pwd)/jellyfin-config":/backup:ro \
  -v arr-stack_jellyfin-config:/config \
  alpine sh -c 'rm -f /config/data/jellyfin.db-wal /config/data/jellyfin.db-shm &&
    cp -a /backup/. /config/'

docker compose -f $NAS_STACK_DIR/docker-compose.arr-stack.yml start jellyfin
```

This copies over what is in the backup and leaves the rest of the volume alone, so an existing `metadata/` folder stays. On a fresh install, images and metadata come back with a library scan (*Dashboard → Libraries → Scan All Libraries*).

To roll back only the database, copy just `data/jellyfin.db` the same way (Jellyfin stopped, `-wal` and `-shm` removed first).

---

## Restore `.env` from Backup

The backup includes your `.env` file (saved as `dot-env`):

```bash
cp /tmp/arr-stack-backup-*/dot-env $NAS_STACK_DIR/.env
chmod 600 $NAS_STACK_DIR/.env
```

Compose files and Traefik config don't need restoring — they're in git. Just `git clone` the repo again.

---

## After Restore

Some services may need post-restore steps:

| Service | Post-restore action |
|---------|-------------------|
| Jellyfin | Run a library scan (Dashboard > Libraries > Scan) to bring back images and metadata; users and watch history come back with the database |
| Sonarr/Radarr | Verify download clients are connected (Settings > Download Clients > Test) |
| Prowlarr | Sync indexers (Settings > Apps > Sync App Indexers) |
| Pi-hole | Verify upstream DNS (Settings > DNS) |
| qBittorrent | Check categories exist (right-click sidebar) |

If `configure-apps.sh` was used for initial setup, re-running it will fix any missing configuration — it's safe to re-run (idempotent).

---

## Troubleshooting

### "Volume not found" during restore

Volumes are created when you first `docker compose up`. If restoring to a fresh system, run `up -d` then `stop` first (Step 4 above).

### Permissions errors

The alpine container in the restore command runs as root, so permissions should work. If you see errors, check that Docker is running and your user is in the docker group.

### Wrong volume prefix

The compose files pin every volume name to `arr-stack_<volume>`, whatever the project directory is called, so the loop above matches them. Only volumes created under another prefix before the names were pinned differ. Check with:
```bash
docker volume ls | grep config
```
Then adjust the `vol=` line in the restore loop accordingly.
