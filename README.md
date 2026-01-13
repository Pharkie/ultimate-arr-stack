# Pharkie's Ultimate Arr Stack for Ugreen and Beyond

[![GitHub release](https://img.shields.io/github/v/release/Pharkie/arr-stack-ugreennas)](https://github.com/Pharkie/arr-stack-ugreennas/releases)

<img align="right" width="45%" src="docs/images/demo/demo.gif">

A Docker Compose stack for automated media management. Request a show or movie, it downloads and appears in Jellyfin—ready to watch, VPN-protected.

Works on Ugreen, Synology, QNAP, or any Docker host.

<br clear="right">

## Why "Ultimate"?

- **Production-ready** — Real healthchecks, auto-recovery when VPN reconnects, backup script. Not just "it runs."
- **Battle-tested** — Edge cases found and fixed across multiple NAS setups. More resilient than most.
- **Everything you need** — Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, Jellyseerr, qBittorrent, SABnzbd, Pi-hole, WireGuard, Cloudflare Tunnel. Modular — skip what you don't need, add what you do (e.g. Lidarr).
- **Step-by-step guide** — Not just a docker-compose file in a repo.
- **Flexible** — Plex variant included. Supports 30+ VPN providers.
- **Privacy by default** — All downloads route through your VPN.

<details>
<summary>Technical features</summary>

- **Local `.lan` domains** — `http://sonarr.lan` instead of port numbers
- **Auto-recovery** — Services restart when VPN reconnects
- **Production healthchecks** — Not just "is the process running?"
- **One-command backup script** — Essential configs to ~13MB
- **Pre-commit hooks** — For contributors: validates secrets, YAML, port conflicts

</details>

## How It Works

**The flow:** Someone requests a show → it downloads automatically → appears in your media library.

Request: Jellyseerr → Sonarr/Radarr → Prowlarr
Download: qBittorrent (torrents) or SABnzbd (Usenet) — both via VPN (Gluetun)
Watch: Jellyfin — locally or remotely via Traefik

**Choose your setup:**
| Setup | How you access | What you need |
|-------|----------------|---------------|
| **Core** | `192.168.1.50:8096` | Just the stack |
| **+ local DNS** | `jellyfin.lan` | Configure Pi-hole + add Traefik |
| **+ remote access** | `jellyfin.yourdomain.com` | Add Cloudflare Tunnel |

## Get Started

**[Setup Guide →](docs/SETUP.md)**

| Doc | Purpose |
|-----|---------|
| [Architecture](docs/ARCHITECTURE.md) | Understand how the stack fits together |
| [Quick Reference](docs/REFERENCE.md) | Cheat sheet: all URLs, ports, IPs, common commands |
| [Upgrading](docs/UPGRADING.md) | How to pull updates and redeploy |
| [Backup & Restore](docs/BACKUP.md) | Backup your configs, restore after disaster |
| [Home Assistant](docs/HOME-ASSISTANT.md) | Get notifications when downloads complete |
| [Legal](docs/LEGAL.md) | What this software is for, disclaimer |

## Like This Project?

If this project helped you, give it a ⭐ to help others find it, or buy me a coffee:

<a href='https://ko-fi.com/X8X01NIXRB' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi6.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>

---

## License

Documentation, configuration files, and examples in this repository are licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) (Attribution-NonCommercial). Individual software components (Sonarr, Radarr, Jellyfin, etc.) retain their own licenses.

## Acknowledgments

Forked from [TheRealCodeVoyage/arr-stack-setup-with-pihole](https://github.com/TheRealCodeVoyage/arr-stack-setup-with-pihole).

## Legal Notice

This project provides configuration files for **legal, open-source software** designed for managing personal media libraries. All included tools have legitimate purposes - see **[LEGAL.md](docs/LEGAL.md)** for details on intended use, user responsibilities, and disclaimer.
