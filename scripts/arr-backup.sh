#!/bin/bash
set -euo pipefail
# arr-stack backup script - runs daily via cron
# Install: sudo cp scripts/arr-backup.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/arr-backup.sh
# Cron: 0 3 * * * /usr/local/bin/arr-backup.sh
#
# WARNING: This script backs up .env which contains secrets (API keys, VPN
# credentials, passwords) in plaintext. Ensure backup destination has
# restricted permissions and consider encrypting backups at rest.

BACKUP_DIR="/mnt/arr-backup"
SOURCE_DIR="/volume1/docker/arr-stack"
DATE=$(date +%Y%m%d)
KEEP_DAYS=7

# Check USB is mounted
if ! mountpoint -q "$BACKUP_DIR"; then
    echo "[$(date)] ERROR: Backup drive not mounted at $BACKUP_DIR" >> /var/log/arr-backup.log
    exit 1
fi

echo "[$(date)] Starting backup..." >> /var/log/arr-backup.log

# Create dated backup folder
mkdir -p "$BACKUP_DIR/$DATE"

# Backup compose files and traefik config
tar -czf "$BACKUP_DIR/$DATE/configs.tar.gz" -C "$SOURCE_DIR" \
    docker-compose.arr-stack.yml \
    .env \
    traefik/ \
    2>/dev/null

# Backup app data (Docker volumes with arr-stack_ prefix)
# Stop services briefly for consistent backup
docker compose -f "$SOURCE_DIR/docker-compose.arr-stack.yml" stop sonarr radarr prowlarr bazarr jellyseerr 2>/dev/null

# Backup named volumes (with project prefix)
for vol in sonarr-config radarr-config prowlarr-config qbittorrent-config jellyfin-config jellyfin-cache; do
    docker run --rm -v arr-stack_${vol}:/source -v "$BACKUP_DIR/$DATE":/backup alpine tar -czf /backup/${vol}.tar.gz -C /source . 2>/dev/null
done

# Backup bind mount directories
for dir in jellyseerr/config bazarr/config uptime-kuma pihole-etc-pihole pihole-etc-dnsmasq; do
    if [ -d "$SOURCE_DIR/$dir" ]; then
        tar -czf "$BACKUP_DIR/$DATE/$(echo $dir | tr '/' '-').tar.gz" -C "$SOURCE_DIR" "$dir" 2>/dev/null
    fi
done

# Restart services
docker compose -f "$SOURCE_DIR/docker-compose.arr-stack.yml" start sonarr radarr prowlarr bazarr jellyseerr 2>/dev/null

# Delete backups older than KEEP_DAYS
find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" -mtime +$KEEP_DAYS -exec rm -rf {} \;

echo "[$(date)] Backup complete: $BACKUP_DIR/$DATE" >> /var/log/arr-backup.log
