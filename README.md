# Pharkie's Ultimate Arr Stack for Ugreen and Beyond

[![GitHub release](https://img.shields.io/github/v/release/Pharkie/arr-stack-ugreennas)](https://github.com/Pharkie/arr-stack-ugreennas/releases)

<table>
<tr>
<td width="50%" valign="top">

A Docker Compose stack for automated media management. Request a show or movie, it downloads and appears in Jellyfin—ready to watch, VPN-protected.

Works on Ugreen, Synology, QNAP, or any Docker host.

</td>
<td width="50%">

![Demo](docs/images/demo/demo.gif)

</td>
</tr>
</table>

## Why "Ultimate"?

- **Everything you need** — Jellyfin (media server), Sonarr (TV), Radarr (movies), Prowlarr (indexers), Bazarr (subtitles), Jellyseerr (requests), qBittorrent (torrents), SABnzbd (Usenet), Pi-hole (ad-blocking DNS for your network), WireGuard (remote access), Cloudflare Tunnel (external access). Easy to add or remove.
- **Flexible** — Plex variant included. Supports 30+ VPN providers (Surfshark, NordVPN, PIA, Mullvad, ProtonVPN, etc.).
- **Step-by-step setup guide** — Not just a docker-compose file in a repo.
- **Privacy by default** — All downloads route through your VPN. No IP leaks.

<details>
<summary>Technical features</summary>

- **Local `.lan` domains** — `http://sonarr.lan` instead of port numbers
- **Auto-recovery** — Services restart when VPN reconnects
- **Production healthchecks** — Not just "is the process running?"
- **One-command backup script** — Essential configs to ~13MB
- **Pre-commit hooks** — For contributors: validates secrets, YAML, port conflicts

</details>

## Get Started

**[Setup Guide →](docs/SETUP.md)**

## Support

If this project helped you, give it a ⭐ to help others find it, or buy me a coffee:

<a href='https://ko-fi.com/X8X01NIXRB' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi6.png?v=6' border='0' alt='Buy Me a Coffee at ko-fi.com' /></a>

---

## License

Documentation, configuration files, and examples in this repository are licensed under [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) (Attribution-NonCommercial). Individual software components (Sonarr, Radarr, Jellyfin, etc.) retain their own licenses.

## Acknowledgments

Forked from [TheRealCodeVoyage/arr-stack-setup-with-pihole](https://github.com/TheRealCodeVoyage/arr-stack-setup-with-pihole). Thanks to [@benjamin-awd](https://github.com/benjamin-awd) for VPN config improvements.

## Legal Notice

This project provides configuration files for **legal, open-source software** designed for managing personal media libraries. All included tools have legitimate purposes - see **[LEGAL.md](docs/LEGAL.md)** for details on intended use, user responsibilities, and disclaimer.
