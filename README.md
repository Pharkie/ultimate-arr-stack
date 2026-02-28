# Pharkie's Ultimate Arr Stack for Ugreen and Beyond

[![GitHub release](https://img.shields.io/github/v/release/Pharkie/ultimate-arr-stack)](https://github.com/Pharkie/ultimate-arr-stack/releases)

<img align="right" width="45%" src="docs/images/demo/demo.gif">

A Docker Compose stack for automated media management. Request a show or movie, it downloads and appears in Jellyfin—ready to watch, VPN-protected.

Works on Ugreen, Synology, QNAP, or any Docker host.

<br clear="right">

## Why "Ultimate"?

- **Production-ready** — Real healthchecks, auto-recovery when VPN reconnects, backup script. Not just "it runs."
- **Battle-tested** — Edge cases found and fixed across multiple NAS setups. More resilient than most.
- **Best practices built in** — Downloads appear instantly without using extra disk space, files are named consistently, and download settings are tuned for security and performance. Based on [TRaSH Guides](https://trash-guides.info/).
- **Everything you need** — Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, Seerr, qBittorrent, SABnzbd, Pi-hole, Cloudflare Tunnel. Modular — skip what you don't need, add what you do (e.g. Lidarr).
- **Step-by-step guide** — Not just a docker-compose file in a repo.
- **Flexible** — Supports 30+ VPN providers. Plex users can swap Jellyfin (see [setup guide](docs/SETUP.md)).
- **Privacy by default** — All downloads route through your VPN.

<details>
<summary>Technical features</summary>

- **Hardlinks** — Single volume mount enables instant imports with zero extra disk space
- **TRaSH naming** — Standardised file naming with quality, codec, HDR, and release group info
- **Local `.lan` domains** — `http://sonarr.lan` instead of port numbers
- **Intel Quick Sync** — GPU-accelerated transcoding on Intel NAS (Ugreen DXP4800+, etc.). Remove 4 lines from compose file if no Intel GPU.
- **Auto-recovery** — Services restart when VPN reconnects
- **Production healthchecks** — Not just "is the process running?"
- **One-command backup script** — Essential configs to ~13MB
- **Pre-commit hooks** — For contributors: validates secrets, YAML, port conflicts

</details>

## How It Works

**The flow:** Someone requests a show → it downloads automatically → appears in your media library.

Request: Seerr → Sonarr/Radarr → Prowlarr
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
| [App Configuration](docs/APP-CONFIG.md) | Configure each app (Jellyfin, Sonarr, Radarr, etc.) |
| [Local DNS](docs/LOCAL-DNS.md) | Set up `.lan` domains with Pi-hole + Traefik |
| [Remote Access](docs/REMOTE-ACCESS.md) | Access from anywhere via Cloudflare Tunnel |
| [Utilities](docs/UTILITIES.md) | Monitoring, auto-recovery, disk usage tools |
| [Quick Reference](docs/REFERENCE.md) | Cheat sheet: all URLs, ports, IPs, common commands |
| [Upgrading](docs/UPGRADING.md) | How to pull updates and redeploy |
| [Backup & Restore](docs/BACKUP.md) | Backup your configs, restore after disaster |
| [Home Assistant](docs/HOME-ASSISTANT.md) | Get notifications when downloads complete |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Fix common issues: stuck downloads, DNS, 4K stuttering |
| [Legal](docs/LEGAL.md) | What this software is for, disclaimer |

## Like This Project?

If this project helped you, give it a ⭐ to help others find it, or buy me a coffee:

<a href='https://ko-fi.com/X8X01NIXRB' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi6.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>

---

## LLM Generated, Human Reviewed

This code was generated with [Claude Code](https://claude.ai/claude-code) (Anthropic, Claude Opus 4.6). Development was overseen by the human author with attention to reliability and security. Architectural decisions, configuration choices, and development sessions were closely planned, directed and verified by the human author throughout. The code and test results were reviewed and tested by the human author beyond the LLM. Still, the code has had limited manual review, I encourage you to make your own checks and use this code at your own risk.

## License

Documentation, configuration files, and examples in this repository are licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) (Attribution-NonCommercial). Individual software components (Sonarr, Radarr, Jellyfin, etc.) retain their own licenses.

## Acknowledgments

Forked from [TheRealCodeVoyage/arr-stack-setup-with-pihole](https://github.com/TheRealCodeVoyage/arr-stack-setup-with-pihole).

## Legal Notice

This project provides configuration files for **legal, open-source software** designed for managing personal media libraries. All included tools have legitimate purposes - see **[LEGAL.md](docs/LEGAL.md)** for details on intended use, user responsibilities, and disclaimer.
