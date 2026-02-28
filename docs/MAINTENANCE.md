# Maintenance Guide

Day-to-day operations, multi-compose commands, and verification procedures.

## Multi-Compose Quick Reference

This stack uses multiple compose files. Here are common commands for each scenario.

### Core Stack Only

```bash
# Start / recreate
docker compose -f docker-compose.arr-stack.yml up -d

# Stop (without removing — safe, keeps Pi-hole running)
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

```bash
# Start all three
docker compose -f docker-compose.arr-stack.yml -f docker-compose.traefik.yml -f docker-compose.cloudflared.yml up -d
```

### Utilities (independent)

```bash
# Start utilities
docker compose -f docker-compose.utilities.yml up -d

# Rebuild qbit-scheduler after editing pause-resume.sh
docker compose -f docker-compose.utilities.yml build qbit-scheduler
docker compose -f docker-compose.utilities.yml up -d qbit-scheduler
```

### All Stacks

```bash
# Start everything
docker compose \
  -f docker-compose.arr-stack.yml \
  -f docker-compose.traefik.yml \
  -f docker-compose.cloudflared.yml \
  -f docker-compose.utilities.yml \
  up -d

# Pull all images
docker compose \
  -f docker-compose.arr-stack.yml \
  -f docker-compose.traefik.yml \
  -f docker-compose.cloudflared.yml \
  -f docker-compose.utilities.yml \
  pull
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

The `check-vpn.sh` script compares Gluetun's exit IP against your NAS LAN IP and exits non-zero if they match (leak detected). You can add it to cron for periodic monitoring:

```bash
# Check every 5 minutes, log failures
*/5 * * * * /volume1/docker/arr-stack/scripts/check-vpn.sh >> /var/log/vpn-check.log 2>&1
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

## Health Checks

All services have Docker healthchecks. Check status:

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
```

Services showing `(unhealthy)` may need attention. Common causes:
- **Gluetun unhealthy**: VPN connection lost — check `docker logs gluetun`
- **qBittorrent/Sonarr/Radarr unhealthy**: Often caused by Gluetun being down (they share its network)
- **Pi-hole unhealthy**: DNS resolution failing — check upstream DNS config

---

## Updating Images

Check for available updates:

```bash
# If using Diun (from utilities stack), it sends notifications automatically

# Manual check
docker compose -f docker-compose.arr-stack.yml pull
# Review what changed, then recreate
docker compose -f docker-compose.arr-stack.yml up -d
```

See [Upgrading Guide](UPGRADING.md) for version-specific upgrade notes.
