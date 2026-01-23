# Changelog

All notable changes to this project will be documented in this file.

## [1.5.5] - 2026-01-23

### Changed
- **Removed unused traefik labels**: Services had `traefik.enable=true` labels that did nothing (routing uses file config, not Docker labels). Cleaned up to avoid confusion for users adding their own services.

---

## [1.5.4] - 2026-01-22

### Removed
- **WireGuard VPN server (wg-easy)**: Removed from stack. WireGuard requires port forwarding, which doesn't work for users behind CGNAT (common with many ISPs). Cloudflare Tunnel covers the main use case of remote access to Jellyfin/Jellyseerr.

### Documentation
- Added Tailscale note for users who need full remote network access (admin UIs, `.lan` domains from outside home)
- Clarified remote access is for watching/requesting (Jellyfin + Jellyseerr), not full network access

### Note
WireGuard as VPN *client* protocol (for Gluetun connecting to your VPN provider) is unchanged. This only removes the VPN *server* for incoming connections.

---

## [1.5.3] - 2026-01-20

### Added
- **Intel Quick Sync hardware transcoding**: GPU-accelerated video transcoding for Jellyfin on Intel NAS (Ugreen DXP4800+, etc.). Reduces CPU usage from ~80% to ~20% when transcoding.

### Documentation
- Hardware transcoding setup guide with Transcoding and Trickplay screenshots
- Verification steps to confirm hardware acceleration is working
- Fork recommended over clone in setup guide

---

## [1.5.2] - 2026-01-16

### Fixed
- **Cloudflared healthcheck**: Was always failing (missing tunnel ID), causing deunhealth to restart cloudflared every ~2.5 minutes. Now uses `cloudflared tunnel info nas-tunnel`
- **DNS config git tracking**: `pihole/02-local-dns.conf` was tracked despite being in `.gitignore`, causing `git pull` to overwrite user's local DNS config
- **DNS resolution conflicts**: Stale entries in `pihole.toml` could conflict with dnsmasq config, causing unpredictable `.lan` domain resolution

### Added
- **Beszel system monitoring**: Lightweight metrics for CPU, RAM, disk, network, and Docker containers (hub + agent with healthchecks)
- **DNS duplicate detection**: Pre-commit hook (check 9) and standalone script (`./scripts/check-dns-duplicates.sh`) to warn if same `.lan` domain defined in both dnsmasq and pihole.toml
- **Domain accessibility check**: Pre-commit hook (check 10) verifies all `.lan` and external domains are reachable

### Changed
- **Renamed "Optional extras"**: Now "Utilities (optional)" for consistency with `docker-compose.utilities.yml`

### Documentation
- Beszel setup instructions in SETUP.md
- Clarified `.lan` DNS guidance: don't define same domain in both dnsmasq config and Pi-hole web UI
- Clarified Docker requirements: NAS users often have Docker preinstalled (UGOS) or one-click install (Synology/QNAP)

---

## [1.5.1] - 2026-01-13

### Added
- **Auto-restart VPN services**: When Gluetun reconnects to VPN, dependent services (qBittorrent, Sonarr, Radarr, Prowlarr, SABnzbd) now automatically restart via `deunhealth` container

### Fixed
- VPN reconnection previously left services with stale network attachments, causing "Unable to connect" errors until manual restart

---

## [1.5] - 2026-01-08

### Changed
- **Removed env var fallbacks**: Compose files no longer have default values for required variables. Missing variables now fail fast with clear errors instead of silently using defaults

### Documentation
- Clarified which variables are required vs optional in `.env.example`

---

## [1.4] - 2026-01-02

### Changed
- **Network renamed**: `traefik-proxy` → `arr-stack` (clearer - network is used by all services, not just Traefik)
- **qbit-scheduler configurable**: Pause/resume hours now set via `QBIT_PAUSE_HOUR` and `QBIT_RESUME_HOUR` env vars

### Documentation
- **Setup levels clarified**: Core / + local DNS / + remote access terminology consistent throughout
- **Step 4 reordered**: Jellyfin first (user-facing), then backend services in dependency order
- **Removed redundant tables**: Service connection table now only in REFERENCE.md

### Migration
See [UPGRADING.md](docs/UPGRADING.md) for network rename instructions.

---

## [1.3] - 2025-12-25

### Changed
- **Network subnet**: Changed from `192.168.100.0/24` to `172.20.0.0/24` to avoid conflicts with common LAN ranges
- **Jellyfin discovery ports**: Added 7359/udp (client discovery) and 1900/udp (DLNA) for better app auto-detection
- **duc.lan support**: duc now on arr-stack network (172.20.0.14) with .lan domain access

### Documentation
- **Prerequisites consolidated**: Simplified to just Hardware and Software/Services lists
- **SETUP.md restructured**: External Access moved to end; steps renumbered for clearer flow
- **Cloudflare Tunnel expanded**: No longer in collapsed section

### Migration
See [UPGRADING.md](docs/UPGRADING.md) for network migration instructions.

## [1.2] - 2025-12-17

### Documentation
- **Restructured docs**: Split into focused files (SETUP.md, REFERENCE.md, UPGRADING.md, HOME-ASSISTANT.md)
- **Setup screenshots**: Step-by-step Surfshark WireGuard and Cloudflare Tunnel setup with images
- **Home Assistant integration**: Notification setup guide for download events
- **VPN provider agnostic**: Documentation now generic; supports 30+ Gluetun providers (was Surfshark-specific)

### Added
- **docker-compose.utilities.yml**: Separate compose file for optional services:
  - **deunhealth**: Auto-restart services when VPN recovers
  - **Uptime Kuma**: Service monitoring dashboard
  - **duc**: Disk usage analyzer with treemap UI
  - **qbit-scheduler**: Pauses torrents overnight (20:00-06:00) for disk spin-down
- **VueTorrent**: Mobile-friendly alternative UI for qBittorrent
- **Pre-commit hooks**: Automated validation for secrets, env vars, YAML syntax, port/IP conflicts

### Changed
- **Cloudflare Tunnel**: Now uses local config file instead of Cloudflare web dashboard - simpler setup, version controlled, supports wildcard routing with just 2 DNS records
- **Security hardening**: Admin services now local-only; only Jellyfin, Jellyseerr, WireGuard exposed via Cloudflare Tunnel
- **Deployment workflow**: Git-based deployment (commit/push locally, git pull on NAS)
- **Pi-hole web UI**: Now on port 8081

### Fixed
- qBittorrent API v5.0+ compatibility (`stop`/`start` instead of `pause`/`resume`)
- Pre-commit drift check service counting

## [1.1] - 2025-12-07

### Added
- Initial public release
- Complete media automation stack with Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr
- VPN-protected downloads via Gluetun
- Remote access via Cloudflare Tunnel
- WireGuard VPN server for secure home network access
- Pi-hole for DNS and ad-blocking
