# Changelog

All notable changes to this project will be documented in this file.

## [1.7.12] - 2026-04-27

### Changed
- **Pi-hole** 2026.04.0 → 2026.04.1 (Core 6.4.1 → 6.4.2, FTL 6.6 → 6.6.1)

### Documentation
- **TROUBLESHOOTING.md**: Added "Pi-hole: Gravity Update Fails With Empty Status" — the empty `Status: ()` symptom comes from a root-owned file in `/etc/pihole/listsCache/` (a relic from older Pi-hole images). Includes diagnose and `chown` fix

---

## [1.7.11] - 2026-04-25

### Documentation
- **SETUP.md Step 2.1**: Added a short "How to edit `.env`" note covering `nano` for SSH users and GUI options (NAS web file manager, VS Code Remote-SSH). Beginners were trying to paste `.env` line snippets straight into the shell because the docs never said which editor to use. Reported on Reddit

---

## [1.7.10] - 2026-04-21

### Fixed
- **SETUP.md clone block**: The Ugreen and Synology sections referenced `$NAS_STACK_DIR` in `chown` before `.env` existed, causing `chown: missing operand`. The variable is now set as a shell var at the top of the clone block, so volume2 users change one line and the whole block works. Reported by u/OatStraw on Reddit

---

## [1.7.9] - 2026-04-19

### Fixed
- **Pi-hole startup failure on multi-volume NAS setups** (#16): Introduced `NAS_STACK_DIR` env var so Pi-hole's config bind-mount resolves correctly when the stack lives on a non-default volume (e.g. `/volume2/docker/arr-stack`). Pi-hole's `dnsmasq.d` config moved under `pihole/dnsmasq.d/` — see UPGRADING.md for the migration command

### Changed
- **Pi-hole** 2026.02.0 → 2026.04.0

### Documentation
- **SETUP.md**: Added multi-volume NAS note explaining `NAS_STACK_DIR` vs `MEDIA_ROOT` split (stack on one volume, media library on another)
- **README**: Clarified LLM attribution; mention Opus 4.7

---

## [1.7.8] - 2026-04-17

### Added
- **dnscrypt-proxy service** (#15, from @gncnpk): Encrypts DNS queries between Pi-hole and upstream resolvers. Runs internally on the arr-stack network with no host port exposure. Configure-apps.sh now sets up Pi-hole to use it

### Changed
- **Seerr** v3.1.0 → v3.2.0

### Fixed
- **Queue-cleanup cron silently failing**: Log path moved from `/var/log/` (which `mooseadmin` can't write to on UGOS) to `$NAS_STACK_DIR/logs/`. Also added detection for `importBlocked` and `importPending` items (already-imported packs, executable files, quality mismatches) that were accumulating unhandled
- **Pi-hole config**: Removed unsupported `-q` flag from `pihole-FTL --config` and switched from `pihole restartdns` (which fails under `cap_drop: ALL`) to `docker restart pihole`

### Security
- **dnscrypt-proxy hardening**: Pinned image to 2.1.14 (from `:latest`), removed unnecessary `NET_ADMIN`/`NET_RAW` caps (port 5053 is unprivileged), set `no-new-privileges: true`

### Documentation
- **MAINTENANCE.md** and HA webhook: Updated queue-cleanup log path references

---

## [1.7.7] - 2026-03-31

### Fixed
- **`cap_drop: ALL` breaking non-LSIO services on fresh install**: v1.7.6 dropped all Linux capabilities by default, but several non-LSIO services (Pi-hole, etc.) need `CHOWN` + `DAC_OVERRIDE` to write to volume directories. Added them back via targeted `cap_add`. Existing installs were unaffected — this only bit fresh deploys

### Added
- **Pi-hole DNS in Uptime Kuma**: Uptime Kuma now uses Pi-hole as its DNS resolver so `.lan` monitor URLs resolve correctly

### Documentation
- **ARCHITECTURE.md**: Corrected security docs — x-security services aren't "fully locked down"; volume-writing services need `CHOWN` + `DAC_OVERRIDE`

---

## [1.7.6] - 2026-03-28

### Security
- **Container security hardening**: Every container across all four compose files now runs with `cap_drop: ALL` and `no-new-privileges: true`. LSIO images get `CHOWN`/`SETUID`/`SETGID`/`DAC_OVERRIDE` back for s6-overlay init. Gluetun keeps `NET_ADMIN` for VPN tunnels. Pi-hole gets targeted caps for the FTL binary. See [Container Security](docs/ARCHITECTURE.md#container-security)

### Added
- **Weekly queue cleanup script** (`scripts/queue-cleanup.sh`): Identifies stuck Sonarr/Radarr queue items (stalled torrents, metadata-stuck, failed imports, 0% for 24h+), removes them with blocklist, and triggers fresh searches. Dry-run by default; suggested cron: Thu 2am
- **Renovate config**: Automated Docker image update PRs, grouped by category (LSIO, infrastructure, utilities), scheduled weekly Monday mornings. Auto-merges LSIO patch updates

---

## [1.7.5] - 2026-03-18

### Changed
- **Bazarr** 1.5.5 → 1.5.6
- **Cloudflared** 2026.2.0 → 2026.3.0
- **Configarr** 1.23.0 → 1.24.0
- **Pre-commit image cache TTL** increased from 1 hour to 24 hours to reduce registry rate-limiting during repeated commits

### Documentation
- **Plex setup guide**: Rewritten with full YAML example, option to run Plex alongside Jellyfin (not just replace), anchor link (`SETUP.md#plex`), and reference to old Plex compose in git history. Clarified that Seerr supports Plex natively

---

## [1.7.3] - 2026-03-06

### Added
- **`fix-sonarr-folders.sh` script**: Renames Sonarr series folders via the API so that Sonarr's database stays in sync (renaming folders directly on disk breaks tracking). LLM-generated and human-reviewed — check the script before running
- **qBittorrent stall timeout**: Pauses torrents after 30 minutes of inactivity so Sonarr/Radarr can detect them and automatically search for alternatives
- **Pi-hole AAAA DNS fix**: `address=/lan/::` entry in dnsmasq config returns `::` for AAAA queries on `.lan` domains instead of NXDOMAIN. Fixes DNS failures in Alpine/musl containers (e.g., Gluetun) that treat AAAA NXDOMAIN as a hard failure

### Removed
- **qbit-scheduler**: Removed the cron-based torrent scheduler (paused all torrents overnight). Replaced by qBittorrent's built-in stall timeout (30-min inactivity → pause) which is more targeted — only pauses stalled torrents instead of everything

### Fixed
- **Seerr library sync and quality defaults**: Documented that Jellyfin libraries must be enabled in Seerr settings and synced, otherwise movies/shows stay stuck at "Requested". Default quality profiles set to `UHD Bluray + WEB` (Radarr) and `Ultra-HD` (Sonarr)
- **qBittorrent auth subnet whitelist**: Documented local network whitelist (`172.20.0.0/24, 10.10.0.0/24, 127.0.0.0/8`) to prevent IP bans from Sonarr/Radarr reconnections and API scripts after container restarts

### Documentation
- **UPGRADING.md**: v1.7.3 migration steps for Seerr library sync, quality profile defaults, and qBit auth whitelist
- **APP-CONFIG docs**: Seerr quality profiles and library sync steps added to both script-assisted and manual guides
- **APP-CONFIG-ADVANCED.md**: qBittorrent auth bypass section with subnet whitelist instructions
- **SETUP.md**: Clarified script-assisted vs manual setup trade-offs, security review note for configure-apps.sh

---

## [1.7.2] - 2026-03-01

### Changed
- **Container renamed: `jellyseerr` → `seerr`**: Container name, service name, and Docker volume all renamed from `jellyseerr`/`jellyseerr-config` to `seerr`/`seerr-config`. Completes the rebrand started in v1.6.4. Existing users must migrate the volume — see UPGRADING.md
- **Parallel domain checks in pre-commit hook**: `.lan` and external domain lookups now run concurrently instead of sequentially — reduces check time from ~28s to <1s

### Fixed
- **Uptime Kuma monitor URL**: Updated from `http://jellyseerr:5055` to `http://seerr:5055`
- **Missing `sudo` in UGOS setup**: `mkdir` and `chown` commands for media directories now use `sudo`, matching the Linux Server section. Fixes "not writable by user" errors for non-root NAS users (fixes #11)

### Documentation
- **App configuration split into 3 focused guides**: [Script-Assisted](docs/APP-CONFIG-QUICK.md) (~5 min), [Manual](docs/APP-CONFIG.md) (~30 min), and [Advanced](docs/APP-CONFIG-ADVANCED.md) (optional tuning). Clearer step-by-step flow with strict separation of access setup vs. configuration
- **SETUP.md improvements**: Slimmed Step 4 handoff, added SABnzbd/Bazarr to Stack Overview, clearer "Core Complete" section with service URLs and Quick Reference link

---

## [1.7.1] - 2026-02-28

### Security
- **VPN leak check script**: New `scripts/check-vpn.sh` compares Gluetun's exit IP against the NAS LAN IP and exits non-zero on leak. Suitable for cron monitoring
- **Backup encryption**: `scripts/arr-backup.sh --encrypt` encrypts tarballs with GPG symmetric encryption (AES-256). Opt-in via `--encrypt` flag
- **`.env` included in backups**: `arr-backup.sh` now backs up `.env` (saved as `dot-env` with 600 permissions). Use `--encrypt` to protect secrets at rest

### Fixed
- **Network definition duplication**: `arr-stack` network was fully defined in 3 compose files. Now owned by `docker-compose.arr-stack.yml` only; traefik and utilities compose files use `external: true`
- **Bazarr missing healthcheck start_period**: Added `start_period: 60s` to prevent false unhealthy status during startup
- **Inconsistent script error handling**: All scripts now use `set -euo pipefail` (`arr-backup.sh`, `check-network.sh`)
- **Consolidated backup scripts**: Merged `backup-volumes.sh` into `arr-backup.sh` — one script for all backups (volumes, `.env`, encryption, USB discovery, HA webhooks)

### Added
- **`--verbose` mode for configure-apps.sh**: Prints curl response bodies on API failures for easier debugging
- **`--help` flag for configure-apps.sh**: Shows usage and confirms idempotency
- **Shared `qbit_auth()` helper**: Extracted qBittorrent authentication into `scripts/lib/configure-helpers.sh`, reducing duplication with `configure-apps.sh`
- **VPN connectivity E2E test**: Verifies VPN-tunneled services are reachable (Gluetun healthy)
- **Maintenance guide** (`docs/MAINTENANCE.md`): Multi-compose command reference, VPN verification, health check guidance
- **Restore guide** (`docs/RESTORE.md`): Step-by-step restore procedures for volume backups and arr-backup tarballs

### Documentation
- SETUP.md: Pi-hole static IP warning added to Step 2.5
- APP-CONFIG.md: Idempotency note for configure-apps.sh (safe to re-run)

---

## [1.7.0] - 2026-02-28

### Added
- **Hardlinks and instant moves**: All download services (qBittorrent, SABnzbd, Sonarr, Radarr) now share a single `/data` volume mount instead of separate `/downloads`, `/tv`, `/movies` mounts. This enables hardlinks — imports are instant and use zero extra disk space. Follows [TRaSH Guides hardlink recommendations](https://trash-guides.info/Hardlinks/Hardlinks-and-Instant-Moves/)
- **TRaSH naming schemes**: Radarr and Sonarr now use TRaSH-recommended file naming with quality, codec, HDR, and release group info. Existing files mass-renamed on upgrade
- **Separated download directories**: Torrents and Usenet downloads now go to separate directories (`torrents/{tv,movies}` and `usenet/{incomplete,complete/{tv,movies}}`) instead of a flat `downloads/` folder
- **SABnzbd hardening**: Sorting disabled, propagation delay, SFV checking, deobfuscation — follows TRaSH SABnzbd recommendations
- **qBittorrent tuning**: UPnP disabled, uTP rate limiting, LAN peer limiting, encryption mode — follows TRaSH qBittorrent recommendations
- **NFO metadata for Radarr and Sonarr**: Recommended setup step — Radarr and Sonarr now write `.nfo` files containing correct TMDB/IMDB/TVDB IDs alongside each media file. Jellyfin reads these instead of guessing from filenames, preventing metadata mismatches that cause Seerr to show "Requested" when files are already downloaded. Especially important for foreign-language films and titles shared by multiple movies
- **Configarr**: New utility container that syncs TRaSH Guides quality profiles and custom formats to Sonarr/Radarr. One-shot job (runs once and exits) — run manually with `docker compose -f docker-compose.utilities.yml run --rm configarr`. Includes dry-run mode
- **AI disclosure**: README now discloses that this codebase was generated with Claude Code, with human oversight throughout
- **Playwright E2E tests**: Automated UI screenshot tests for all 9 services plus API assertions for root folders and media libraries. Run with `npm run test:e2e`

### Changed
- **Volume mounts restructured**: qBittorrent, SABnzbd, Sonarr, Radarr now mount `${MEDIA_ROOT}:/data` (single mount). Jellyfin and Bazarr mount specific subdirectories under `/data/`. This is a breaking change for existing users — see UPGRADING.md
- **Download categories renamed**: qBittorrent categories changed from `sonarr`/`radarr` to `tv`/`movies` to match directory structure and SABnzbd categories
- **Jellyfin library paths**: Changed from `/media/movies` and `/media/tv` to `/data/media/movies` and `/data/media/tv` — follows TRaSH recommended `media/` subdirectory structure
- **Repo renamed**: `arr-stack-ugreennas` → `ultimate-arr-stack`. GitHub auto-redirects old URLs

### Documentation
- APP-CONFIG.md: Complete rewrite of paths, categories, and folder setup for all services
- APP-CONFIG.md: TRaSH naming scheme configuration added to Sonarr and Radarr setup steps
- APP-CONFIG.md: SABnzbd hardening section added with TRaSH recommendations
- APP-CONFIG.md: qBittorrent tuning section added with TRaSH recommendations
- APP-CONFIG.md: Bazarr subtitle sync (`ffsubsync`) added as setup step
- APP-CONFIG.md: NFO metadata added as step 4 in both Sonarr and Radarr setup
- SETUP.md: Updated directory structure diagram and mkdir commands for hardlink-compatible layout
- UPGRADING.md: Full v1.6.5→v1.7 migration guide with step-by-step root folder migration, category changes, naming config
- TROUBLESHOOTING.md: Updated SABnzbd paths from `downloads/` to `usenet/`
- TROUBLESHOOTING.md: SSH post-quantum key exchange warning fix for macOS OpenSSH 10.x connecting to UGOS NAS
- UTILITIES.md: Configarr setup and usage guide
- REFERENCE.md: Configarr added to service tables
- CONTRIBUTING.md: E2E tests added to pre-release checklist

---

## [1.6.5] - 2026-02-22

### Fixed
- **FlareSolverr Cloudflare bypass fails** (fixes #5): FlareSolverr was running outside the VPN, so it solved Cloudflare challenges from a different IP than Prowlarr's VPN exit IP — Cloudflare rejected the mismatched cookies. FlareSolverr now runs behind Gluetun (`network_mode: "service:gluetun"`), sharing the same tunnel and IP as Prowlarr. This also fixes ISP DNS blocking of torrent domains, since FlareSolverr inherits Gluetun's Pi-hole DNS automatically

### Changed
- Prowlarr FlareSolverr host: `http://172.20.0.10:8191` → `http://localhost:8191` (same network namespace)
- Uptime Kuma FlareSolverr monitor: `http://172.20.0.10:8191` → `http://172.20.0.3:8191` (via Gluetun)
- Removed `flaresolverr.lan` DNS entry (no longer has its own IP)
- Removed FlareSolverr static IP `172.20.0.10` from network tables (docs, config templates)

---

## [1.6.4] - 2026-02-20

### Changed
- **Jellyseerr → Seerr**: Migrated from `fallenbagel/jellyseerr:2.7` to `ghcr.io/seerr-team/seerr:v3.0.1` (the official rebrand). Runs as non-root (UID 1000), requires `init: true`. Container and volume renamed to `seerr` / `seerr-config` in v1.7.2
- **jellyseerr.lan → seerr.lan**: Primary domain renamed. Permanent 301 redirects from `jellyseerr.lan` and `jellyseer.lan` to `seerr.lan` (Traefik + external). Existing bookmarks continue to work
- **FlareSolverr healthcheck**: Reduced `start_period` from 2m to 60s to exit `starting` state faster

### Removed
- **Plex compose file deleted**: `docker-compose.plex-arr-stack.yml` and `vpn-services-plex.yml.example` removed. Plex users should modify the Jellyfin compose directly — see "Prefer Plex?" section in SETUP.md
- **Compose drift pre-commit check**: Removed (was comparing Jellyfin/Plex files for consistency — no longer needed)

### Documentation
- All docs updated: Jellyseerr → Seerr throughout (SETUP, REFERENCE, ARCHITECTURE, LEGAL, README, instructions)
- Pi-hole DNS: clarified that `pihole reloaddns` does NOT pick up bind-mount file changes — must use `docker restart pihole`
- CONTRIBUTING.md: updated scripts structure, pre-commit hooks table, project structure

---

## [1.6.3] - 2026-02-18

### Fixed
- **Bazarr, Overseerr, Plex, DIUN images fail to pull** (fixes #4): Five image tags were wrong — `bazarr:v1.5.5` (should be `1.5.5`), `overseerr:1.33` (should be `1.35.0`), `plex:1.41` (should be `1.43.0`), `diun:v4.31.0` (should be `4.31.0`). Containers kept running from cached `:latest` pulls so the bad tags were never caught
- **WireGuard secret detection test was always passing**: Test fixture path matched the `tests/fixtures/*` skip rule in `check_secrets`, so the test never actually ran the detection logic

### Added
- **Image tag registry validation test**: New BATS test checks every `image:tag` in all compose files actually exists on its registry (Docker Hub, GHCR, LSCR) via HTTP API. No Docker CLI or pull required — would have caught all five bad tags instantly
- **Pre-release checklist**: `CONTRIBUTING.md` now documents mandatory steps before any release — run BATS tests, full `docker compose pull` on the NAS, bring stack up and verify

---

## [1.6.2] - 2026-02-13

### Added
- **Swappiness tuning**: Set `vm.swappiness=10` via root `@reboot` crontab. UGOS default (60) aggressively swaps out app pages even with plenty of free RAM. Reduces unnecessary zram overhead and keeps container memory resident
- **Backup to USB**: `arr-backup.sh --usb DIR_NAME` dynamically finds USB devices under `/mnt/@usb/sd*/` (device letters change on reboot). Includes 7-day rotation
- **Backup failure notifications**: Home Assistant webhook alerts when backup fails, with step-level error reporting (`HA_WEBHOOK_URL` env var)

### Documentation
- **RAM upgrade 5-day analysis**: Full Beszel comparison (97 pre vs 289 post samples) showing 91% disk read reduction, 40% CPU drop, zero disk swap. Container memory steady-state measurements. NVMe-for-Docker assessment reconfirmed as not worth it
- **Swappiness troubleshooting**: New section in TROUBLESHOOTING.md for diagnosing and fixing unnecessary swap with free RAM available

---

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
