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

If the backup was created with `--encrypt`:

```bash
gpg --decrypt /tmp/backup.tar.gz.gpg > /tmp/backup.tar.gz
```

### 3. Extract

```bash
cd /tmp
tar -xzf backup.tar.gz
ls arr-stack-backup-*/
# Should show: gluetun-config/ qbittorrent-config/ prowlarr-config/ etc.
```

### 4. Deploy Fresh Stack

If restoring to a new system, deploy first so Docker creates the volumes:

```bash
cd /volume1/docker/arr-stack
cp .env.example .env
# Edit .env with your settings
docker compose -f docker-compose.arr-stack.yml up -d
docker compose -f docker-compose.arr-stack.yml down
```

### 5. Restore Volumes

```bash
cd /tmp/arr-stack-backup-*

for dir in */; do
  vol="arr-stack_${dir%/}"
  echo "Restoring $vol..."
  docker run --rm \
    -v "$(pwd)/$dir":/source:ro \
    -v "$vol":/dest \
    alpine cp -a /source/. /dest/
done
```

### 6. Start Services

```bash
cd /volume1/docker/arr-stack
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

---

## Restore `.env` from Backup

The backup includes your `.env` file (saved as `dot-env`):

```bash
cp /tmp/arr-stack-backup-*/dot-env /volume1/docker/arr-stack/.env
chmod 600 /volume1/docker/arr-stack/.env
```

Compose files and Traefik config don't need restoring — they're in git. Just `git clone` the repo again.

---

## After Restore

Some services may need post-restore steps:

| Service | Post-restore action |
|---------|-------------------|
| Jellyfin | Run library scan (Dashboard > Libraries > Scan) |
| Sonarr/Radarr | Verify download clients are connected (Settings > Download Clients > Test) |
| Prowlarr | Sync indexers (Settings > Apps > Sync App Indexers) |
| Pi-hole | Verify upstream DNS (Settings > DNS) |
| qBittorrent | Check categories exist (right-click sidebar) |

If `configure-apps.sh` was used for initial setup, re-running it will fix any missing configuration — it's safe to re-run (idempotent).

---

## Troubleshooting

### "Volume not found" during restore

Volumes are created when you first `docker compose up`. If restoring to a fresh system, run `up -d` then `down` first (Step 4 above).

### Permissions errors

The alpine container in the restore command runs as root, so permissions should work. If you see errors, check that Docker is running and your user is in the docker group.

### Wrong volume prefix

If your project directory isn't named `arr-stack`, Docker uses a different prefix. Check with:
```bash
docker volume ls | grep config
```
Then adjust the `vol=` line in the restore loop accordingly.
