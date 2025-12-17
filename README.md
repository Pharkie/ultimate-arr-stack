# Media Automation Stack for Ugreen NAS

A complete, production-ready Docker Compose stack for automated media management with VPN routing, SSL certificates, and remote access.

**Tested on Ugreen NAS DXP4800+** but should work on any Docker host (Synology, QNAP, Linux server, etc.).

## Legal Notice

This project provides configuration files for **legal, open-source software** designed for managing personal media libraries. All included tools have legitimate purposes - see **[LEGAL.md](docs/LEGAL.md)** for details on intended use, user responsibilities, and disclaimer.

---

## Documentation

| Doc | Purpose |
|-----|---------|
| **[Setup Guide](docs/SETUP.md)** | Step-by-step deployment |
| [Quick Reference](docs/REFERENCE.md) | URLs, commands, IPs |
| [Updating](docs/UPDATING.md) | Pull updates, redeploy |
| [Backup & Restore](docs/BACKUP.md) | Backup configs, restore |
| [Home Assistant](docs/HOME-ASSISTANT.md) | Notifications integration |
| [Legal](docs/LEGAL.md) | Intended use, disclaimer |

<details>
<summary>Using Claude Code for guided setup</summary>

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) can walk you through deployment, executing commands and troubleshooting as you go. Works in terminal, VS Code, or Cursor.

```bash
npm install -g @anthropic-ai/claude-code
cd arr-stack-ugreennas && claude
```

Ask Claude to help deploy the stack - it reads [`.claude/instructions.md`](.claude/instructions.md) automatically.

</details>

---

## Features

**Core Stack**
- **VPN-protected networking** via Gluetun (supports 30+ providers)
- **Automated SSL/TLS** certificates via Traefik + Cloudflare
- **Media library management** with Sonarr, Radarr, Prowlarr, Bazarr
- **Media streaming** with Jellyfin (or Plex variant available)
- **Request management** with Jellyseerr (or Overseerr for Plex)
- **Remote access** via WireGuard VPN server
- **Ad-blocking DNS** with Pi-hole

**Operational**
- **Backup script** for essential configs (~13MB) - auto-detects setup variant
- **Auto-recovery** restarts services when VPN reconnects (deunhealth)
- **Service monitoring** with Uptime Kuma dashboard
- **Torrent scheduler** pauses downloads overnight for NAS disk spin-down
- **Docker named volumes** for portable, self-contained configs

**For Contributors**
- **Pre-commit hooks** validate secrets, YAML syntax, port conflicts, and more
- **Claude Code ready** - includes instructions for AI-assisted deployment and troubleshooting
- See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup

## Services

### `docker-compose.traefik.yml` - Infrastructure

| Service | Description | Local Port | Domain URL |
|---------|-------------|------------|------------|
| **Traefik** | Reverse proxy with automatic SSL | 8080, 8443, 9090 | traefik.yourdomain.com |

### `docker-compose.cloudflared.yml` - External Access *(optional - for remote access)*

| Service | Description | Local Port | Domain URL |
|---------|-------------|------------|------------|
| **Cloudflared** | Cloudflare Tunnel for remote access | - | Internal |

### `docker-compose.arr-stack.yml` - Media Stack

**User-facing services** (local + remote access if configured):

| Service | Description | Local | Remote (if configured) |
|---------|-------------|-------|------------------------|
| **Jellyfin** | Media streaming server | NAS_IP:8096 | jellyfin.yourdomain.com |
| **Jellyseerr** | Media request system | NAS_IP:5055 | jellyseerr.yourdomain.com |
| **WireGuard** | VPN server for remote access | NAS_IP:51820/udp | wg.yourdomain.com |

**Admin services** (local-only for security):

| Service | Description | Local |
|---------|-------------|-------|
| **Gluetun** | VPN gateway for network privacy | - |
| **qBittorrent** | BitTorrent client (VueTorrent UI) | NAS_IP:8085 |
| **Sonarr** | TV show library management | NAS_IP:8989 |
| **Radarr** | Movie library management | NAS_IP:7878 |
| **Prowlarr** | Search aggregator | NAS_IP:9696 |
| **Bazarr** | Subtitle management | NAS_IP:6767 |
| **Pi-hole** | DNS + Ad-blocking | NAS_IP:8081 |
| **FlareSolverr** | CAPTCHA solver | NAS_IP:8191 |

> **Don't need all these?** Remove any service by deleting its section from the compose file. Core dependency: Gluetun (VPN gateway).
>
> **Prefer Plex?** See `docker-compose.plex-arr-stack.yml` for an untested Plex/Overseerr variant.

### `docker-compose.utilities.yml` - Optional Utilities

| Service | Description | Local | Remote |
|---------|-------------|-------|--------|
| **deunhealth** | Auto-restart services if VPN drops and recovers | - | - |
| **Uptime Kuma** | Service monitoring dashboard | NAS_IP:3001 | Via WireGuard |
| **duc** | Disk usage analyzer (treemap UI) | NAS_IP:8838 | Via WireGuard |
| **qbit-scheduler** | Pauses torrents overnight (20:00-06:00) for disk spin-down | - | - |

## Alternative Providers

**VPN:** Configured for Surfshark but Gluetun supports 30+ providers (NordVPN, PIA, Mullvad, etc.). See [Gluetun providers](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers).

**DNS/SSL:** Configured for Cloudflare (DNS + Tunnel). Other providers work with modifications to Traefik config. See [Traefik ACME docs](https://doc.traefik.io/traefik/https/acme/).

## Security

Admin services (Sonarr, Radarr, etc.) are local-only by design - not exposed via Cloudflare Tunnel. Still recommend enabling auth.

## License

Documentation, configuration files, and examples in this repository are licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) (Attribution-NonCommercial). Individual software components (Sonarr, Radarr, Jellyfin, etc.) retain their own licenses.

## Acknowledgments

Forked from [TheRealCodeVoyage/arr-stack-setup-with-pihole](https://github.com/TheRealCodeVoyage/arr-stack-setup-with-pihole). Thanks to [@benjamin-awd](https://github.com/benjamin-awd) for VPN config improvements.
