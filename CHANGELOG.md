# Changelog

All notable changes to this project will be documented in this file.

## [1.6.1] - 2026-02-12

### Fixed
- **Gluetun fails to start after power cut**: On simultaneous restart, containers from other compose projects (e.g. therapy-stack Baserow) could grab Gluetun's reserved IP (172.20.0.3) dynamically, causing "Address already in use" and taking down all VPN-dependent services. Fixed by adding `ip_range: 172.20.0.128/25` to the arr-stack network definition in `docker-compose.traefik.yml`, confining dynamic allocations to 128-255 and protecting static IPs
- **RAID5 tuning lost on reboot**: UGOS firmware updates silently overwrite `/etc/rc.local`, wiping custom tuning. Moved RAID5 streaming tuning (read-ahead + stripe cache) from rc.local to root crontab `@reboot` which survives UGOS updates

### Changed
- **arr-stack network ownership**: Network definition moved from manual `docker network create` (referenced as `external: true`) to `docker-compose.traefik.yml` with full IPAM config — `ip_range` is now version-controlled and applied automatically on `up -d`

### Documentation
- **rc.local warning**: All docs updated to recommend crontab `@reboot` instead of `/etc/rc.local` for UGOS

---

## [1.6.0] - 2026-02-08

### Fixed
- **Pi-hole fails to start on every reboot**: Pi-hole binds to `${NAS_IP}:53`, but if the IP comes from DHCP, Docker starts before the address is assigned — causing a silent exit 128 that Docker never retries. Removed Pi-hole from unnecessary `vpn-net` network (was causing a secondary race condition). Documented the root cause and fix (static IP on NAS) across `.env.example`, SETUP.md, and TROUBLESHOOTING.md
- **Jellyfin 4K playback stuttering**: UGOS default RAID5 read-ahead (384 KB) is too small for streaming large files, causing disk utilization to hit 96% and playback to freeze every 2-3 minutes. Increased read-ahead to 4096 KB and stripe cache to 4096 pages. Disk utilization during 4K playback drops from ~96% to ~10%

### Documentation
- **Static IP requirement for Pi-hole**: `.env.example` now explains why `NAS_IP` must be a static IP (not DHCP reservation), how to check, and how to fix
- **Pi-hole reboot troubleshooting guide**: Full diagnose/fix section in TROUBLESHOOTING.md with copy-paste commands
- **SETUP.md Pi-hole prerequisite**: Static IP callout with link to troubleshooting
- Clarified difference between static IP and DHCP reservation across all docs
- **RAID5 streaming tuning**: SETUP.md Jellyfin section + full diagnose/fix in TROUBLESHOOTING.md with iostat commands and permanent fix via crontab

---

## [1.5.7] - 2026-02-07

### Added
- **DIUN (Docker Image Update Notifier)**: New utility container that monitors all running containers and sends webhook notifications to Home Assistant when newer image versions are available on registries. Daily check at 6am (configurable via `DIUN_SCHEDULE`)
- **Pre-commit check 11 — Image version staleness**: Queries Docker Hub and GHCR to warn when pinned image versions have newer releases. Non-blocking (warning only), with 1-hour result cache for fast commits
- **BATS test framework**: 22 automated tests across 5 test suites validating compose structure, security policies, pre-commit checks, port/IP conflicts, and env var coverage. Run with `./tests/run-tests.sh`

### Security
- **Cross-file port/IP conflict detection**: Pre-commit hook now detects duplicate ports and IPs across different compose files (not just within each file)
- **New secret detection patterns**: OpenVPN credentials, Bearer/auth tokens, and SSH/generic passwords now caught by pre-commit secret scanner
- **Cron injection prevention**: qbit-scheduler validates `PAUSE_HOUR`/`RESUME_HOUR` are 0-23 before interpolating into crontab
- **Traefik logging**: Added missing `json-file` log driver with rotation (10m/3 files) — the only service that was missing it

### Documentation
- Home Assistant integration guide for DIUN webhook setup
- DIUN added to reference tables (network, utilities compose)

---

## [1.5.6] - 2026-02-06

### Documentation
- **SABnzbd troubleshooting guide**: Step-by-step fix for stuck unpack loops (obfuscated filenames + par2 files, no RARs). Covers diagnosis, `_UNPACK_*` cleanup, postproc queue reset, and Radarr re-import.
- **Beszel webhook setup**: How to configure Beszel alert webhooks for Discord/ntfy notifications, plus UGOS antivirus scanning tip
- **Fix Gluetun VPN check command**: Changed `grep -i "connected"` to `grep "Public IP address" | tail -1` — Gluetun (WireGuard) never logs "connected", it logs the public IP on successful connection
- **Fix VPN IP check command**: Replaced `ifconfig.me` with `ipinfo.io/ip` — ifconfig.me now returns HTML to wget instead of plain text

---

## [1.5.5] - 2026-01-23

### Changed
- **Removed unused traefik labels**: Services had `traefik.enable=true` labels that did nothing (routing uses file config, not Docker labels). Cleaned up to avoid confusion for users adding their own services.

### Documentation
- **Using tunnel for other services**: Added guide for routing additional subdomains through the same Cloudflare Tunnel (e.g., Home Assistant, blogs). Explains ingress rule ordering and DNS setup.
- **Kodi for Fire TV**: Added guide for using Kodi with Jellyfin add-on when experiencing passthrough issues (Dolby Vision, TrueHD Atmos). Includes Fire TV sideload instructions and fix for "Unable to connect" error caused by Docker networking.

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
