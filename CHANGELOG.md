# Changelog

All notable changes to this project will be documented in this file.

## [1.7.29] - 2026-08-15

### Changed
- **Version bumps: Sonarr, Radarr, Prowlarr, Bazarr** — routine updates to the latest
  LinuxServer.io images: Sonarr `4.0.17`→`4.0.19`, Radarr `6.1.1`→`6.3.0`, Prowlarr `2.3.0`→`2.5.2`,
  Bazarr `1.5.6`→`1.6.0`. SABnzbd's `4.x`→`5.x` major-version bump is tracked separately given the
  higher risk of a breaking change to the just-verified Usenet pipeline. Jellyfin (`10.11.11`) was
  already current — no change needed.

## [1.7.28] - 2026-08-15

### Added
- **SABnzbd wired into Sonarr/Radarr for Usenet downloads via TorBox**: fixed SABnzbd's storage
  paths (`complete_dir`/`download_dir` were relative, resolving inside SABnzbd's own config volume
  instead of the shared media volume), added `tv`/`movies` categories, and added SABnzbd as a
  download client in both Sonarr and Radarr (host `172.20.0.3:8080` — gluetun's bridge IP and
  SABnzbd's internal port; using the IP directly avoids SABnzbd's hostname-whitelist `403`). See
  `docs/APP-CONFIG.md` §4.4/§4.5, which also fixes a pre-existing bug listing Radarr's SABnzbd host
  as `localhost` (unreachable since Radarr moved onto the bridge network). Added e2e coverage for
  both new download clients.

- **Trakt integration**: Jellyfin's Trakt plugin installed and authorized (bidirectional
  watched-status sync + scrobbling) via its native device-code flow. Sonarr/Radarr Trakt import
  lists (auto-add from watchlist/trending/a list URL) were attempted but are currently **blocked
  by an upstream bug**, not a config issue — see `docs/APP-CONFIG.md` §4.6a for detail and tracking
  links.

### Fixed
- **Prowlarr's stale `Internet Archive` indexer removed** — had been failing DNS/connectivity for
  6+ hours, tripping Sonarr/Radarr's "all indexers unavailable" health check. Replaced with a
  working free Usenet indexer (Usenet-Crawler, via Prowlarr's Generic Newznab definition).
- **SABnzbd's TorBox Usenet connection**: real end-to-end grab confirmed working after regenerating
  the account's NNTP username/password from TorBox's dashboard. The `482 Invalid username or
  password` error seen earlier looked like a plan-tier rate limit (TorBox's account API showed a
  `cooldown_until` field at the time) but was actually just stale credentials — correcting that
  earlier theory. See `docs/APP-CONFIG.md` §4.6.

## [1.7.27] - 2026-08-14

### Added
- **Tailscale exit node**: the NAS now advertises `--advertise-exit-node` alongside its existing subnet route, so a tailnet device can route *all* its internet traffic through home, not just LAN traffic. Meant as a substitute for an always-on VPN app on mobile, where the OS only runs one VPN tunnel at a time — confirmed live that connecting Tailscale and ProtonVPN (always-on) on the same Android device disconnect each other, even with ProtonVPN's own split-tunneling excluding the Tailscale app (that setting only affects traffic routing within an already-active tunnel, not concurrent VPN apps). Approved via the Tailscale API (`0.0.0.0/0` + `::/0` enabled routes on the NAS device). Also needed two host sysctls this NAS didn't have by default — `net.ipv6.conf.all.forwarding=1` and `net.ipv4.conf.all.src_valid_mark=1` — persisted in `/etc/sysctl.conf` so they survive reboots; without them Tailscale reports "Subnet routing is enabled, but IP forwarding is disabled" even though `net.ipv4.ip_forward` was already on. See `docs/TAILSCALE.md`.

## [1.7.26] - 2026-08-05

### Changed
- **Image bumps:** cloudflared `2026.6.1` → `2026.7.3`, Pi-hole `2026.06.0` → `2026.07.2`, Tailscale `v1.98.4` → `v1.98.10`, and the docker CLI used by `gluetun-recover` `26.1-cli` → `29.7-cli`. Verified on the NAS from the branch before merge: all four containers healthy on the new tags, no unhealthy containers anywhere, Pi-hole resolving public and `.lan` names with its `${NAS_IP}:53` bindings published, Tailscale re-registered on the tailnet, and all `.lan` services answering through Traefik. The docker-CLI jump is three majors, so `gluetun-recover` was checked specifically — 0 restarts and it can still drive the docker socket (`docker exec gluetun-recover docker ps` lists containers), which is the only API surface it uses.

### Documentation
- **A Pi-hole restart poisons macOS's DNS cache for `.lan` when clients have a public fallback resolver.** While Pi-hole is down, `.lan` lookups fall through to the secondary (e.g. `1.1.1.1`), which answers **NXDOMAIN** authoritatively; macOS caches that negative answer and keeps serving it after Pi-hole returns, so every `.lan` domain looks dead while `dig @<NAS_IP>` works perfectly. Observed during this bump. The fix on each Mac is an `/etc/resolver/lan` file pinning that TLD to Pi-hole, which bypasses the fallback for `.lan` only and keeps the fallback protecting general internet access.

## [1.7.25] - 2026-08-05

### Fixed
- **Docker no longer leaves host-IP-pinned ports unpublished after a reboot** — the fault that took the entire home network's DNS down on 2026-08-05. At boot the Docker *daemon* restores `restart: always` containers itself (compose is never involved), and bindings pinned to `${NAS_IP}` silently fail to be established while the container starts anyway. Reproduced on three consecutive reboots: **pihole, baserow and therapybot — the only three `${NAS_IP}`-pinned containers — failed every time; all 13 wildcard-bound containers were unaffected.** One failed binding drops the container's whole mapping set, so Pi-hole also lost its `0.0.0.0:8081` UI. Pi-hole reported **healthy** throughout, because its healthcheck digs `127.0.0.1` from *inside* the container — so `docker ps`, health status and `deunhealth` were all blind to it. Fixed by `scripts/boot-compose-up.sh`, run at boot via `scripts/boot-compose-up.service`, which runs `docker compose up -d` across all nine deployed stacks and re-establishes the bindings. DNS is back ~20s after boot (Pi-hole's stack is ordered first); the full sweep takes ~5 minutes.

### Added
- **`scripts/boot-compose-up.sh` + `scripts/boot-compose-up.service`**, deployed to `/volume1/docker/boot-compose-up.sh` (symlinked into this repo so `git pull` updates it) and `/etc/systemd/system/`. The script waits for dockerd to accept connections before doing anything, brings each stack up independently so one failure can't block the rest (DNS matters more than Immich), logs to `/volume1/docker/boot-compose-up.log` with self-trimming, and deliberately never passes `--remove-orphans` (see the existing TROUBLESHOOTING entry — it would delete the other compose files' containers).

### Documentation
- **TROUBLESHOOTING.md "Docker: Ports Not Published After Reboot"**: the full incident, and how it differs from the neighbouring exit-128 Pi-hole entry — there the container is *stopped*; here it is *running and answering nobody*, which is much harder to spot. Three things learned the hard way and now written down: (1) the systemd unit must use `Wants=`, never `Requires=`/`RequiresMountsFor=` — the first version failed the job nine seconds into boot because `/volume1` wasn't mounted yet and **never retried**, leaving it `inactive (dead)` with nothing in `systemctl status`; (2) a **static IP does not fix this**, unlike the exit-128 case — UGOS reverts the Control Panel setting to DHCP on reboot and overrides `ifcfg-eth0` (which has said `static` since February) via its own `dhclient@eth0.service`; (3) `mooseadmin` must be in the `systemd-journal` group or `journalctl` returns nothing in a way that reads as "no logs" rather than "no permission".

## [1.7.24] - 2026-08-01

### Changed
- **Seerr** v3.3.0 → v3.4.1. The bump was made live on the NAS first (config volume backed up to `seerr-config-backup-20260801-202225.tgz` beforehand); this release absorbs it into the repo. Verified on the NAS: container healthy, `/api/v1/status` reports 3.4.1, and Seerr reaches qBittorrent through `gluetun:8085`.
- **Diun now notifies about new release tags, not just digest changes of the pinned tag**: added `DIUN_DEFAULTS_WATCHREPO=true` plus a semver-only `DIUN_DEFAULTS_INCLUDETAGS=^v?\d+\.\d+\.\d+$` filter (nightlies/betas/rc tags stay silent), capped at the 25 highest tags per repo (`SORTTAGS=semver` + `MAXTAGS=25`) so daily scans don't hammer registries. Without `watchRepo`, diun only reported when e.g. `:v3.3.0` itself was re-pushed — which is why the Seerr v3.4.x releases were never noticed. Deployment gotcha (verified in diun's source — `db.First()` tracks "first check" per *repo*, not per tag): enabling `watchRepo` against an existing diun DB fires a notification for every historical tag it hasn't seen, several hundred across the stack. The DB was moved aside (`diun.db.pre-watchrepo`) so the first scan primed silently; only genuinely new releases notify from now on.

### Fixed
- **`gluetun-recover` no longer fails silently after a gluetun RECREATE**: `docker restart` of a dependent only works when gluetun was *restarted* (same container ID). When gluetun is *recreated* — which any `docker compose up -d`, even of an unrelated service, will do if gluetun's config has drifted — the dependents still point at the old container ID and restart fails with "joining network namespace … No such container". The watcher now logs that failure loudly, including the exact `docker compose up -d --force-recreate <service>` command to run. (It cannot self-heal this case: fixing it requires compose, which the watcher doesn't have.)

### Documentation
- **TROUBLESHOOTING.md "After a Gluetun RECREATE"**: documents the 2026-08-01 incident — `docker compose up -d seerr` recreated gluetun (config drift), SIGKILLing qBittorrent/SABnzbd/Prowlarr/FlareSolverr (exit 137); `gluetun-recover` and plain `docker restart` both failed on the stale container ID; FlareSolverr then wedged in a `Dead` state dockerd could never remove ("removal of container is already in progress"), which blocked compose and required a Docker daemon restart to clear. Includes the compose-recreate fix, the daemon-restart escape hatch, and a `--dry-run` check to spot an imminent gluetun recreate before it bites.

## [1.7.23] - 2026-06-27

### Changed
- **Sonarr and Radarr moved off the VPN onto the `arr-stack` bridge** (static IPs `172.20.0.10` / `172.20.0.11`), dropping `network_mode: service:gluetun`. They only ever contact metadata providers (TVDB/TMDB) and internal services — never indexers or peers — so they gain nothing from the VPN, and sharing gluetun's namespace meant every VPN reconnect briefly cut them off from Jellyseerr/Bazarr. qBittorrent, SABnzbd, Prowlarr and FlareSolverr **stay** behind gluetun (that is the traffic the VPN exists to hide). Gluetun no longer publishes 8989/7878; Sonarr/Radarr publish their own ports. Traefik routes updated to the new IPs.

### Fixed
- **Jellyseerr requests no longer fail when the VPN reconnects.** This is the structural fix for the class of problem patched defensively in 1.7.21 (gluetun namespace churn leaving Jellyseerr unable to reach Radarr/Sonarr, requests stuck on *Failed*, `Unable to get queue` errors). With Sonarr/Radarr on the bridge, the Jellyseerr/Bazarr → Sonarr/Radarr path is immune to VPN flaps. Verified end-to-end on the NAS: download-client / app-sync / Bazarr / Jellyseerr connections all test green, `Unable to get queue` errors dropped to 0, qBittorrent + Prowlarr still exit via the VPN IP (Sonarr via the home IP, as intended), and all 14 E2E tests pass.
- **Uptime Kuma monitors** for Sonarr/Radarr were still pinging `gluetun:8989`/`7878` (dead after the move) and false-alarming — repointed to `sonarr:8989` / `radarr:7878`, both back to `200 - OK`.

### Documentation
- **`docs/MIGRATION-arr-off-vpn.md`**: full runbook (backups, recreate, the NAS-side app-config changes, verification incl. a VPN-still-protects check, rollback).
- **Swept all docs to the new topology**: `REFERENCE.md` (Service Connection Guide, IP table, startup order), `APP-CONFIG.md` (download-client hosts → `gluetun`, Prowlarr apps → bridge IPs, Seerr/Bazarr → `sonarr`/`radarr`, SAB `host_whitelist` note), `ARCHITECTURE.md` (data-flow + VPN diagrams, connection examples, network table), `UTILITIES.md` (monitor URLs), `TROUBLESHOOTING.md` (stale-namespace section now scoped to qBit/SAB/Prowlarr/FlareSolverr), `MAINTENANCE.md`. Two boundary gotchas documented: VPN-side services reach bridge services by **IP** (the VPN namespace's DNS is Pi-hole, which can't resolve container names), and SABnzbd's `host_whitelist` must include `gluetun`.

## [1.7.22] - 2026-06-19

### Changed
- **Cloudflared** 2026.6.0 → 2026.6.1. Verified on the live tunnel (container healthy, Jellyfin returned HTTP 302 through the tunnel via HTTPS).
- **Pi-hole** 2026.05.0 → 2026.06.0. Config volume backed up before the bump; verified after recreate (FTL healthy in ~24s, `.lan` domains and external DNS both resolving).

## [1.7.21] - 2026-06-19

### Fixed
- **`gluetun-recover` now revives *running* zombies, not just `Exited` containers**: when gluetun restarts to rebuild its tunnel, its shared network namespace is destroyed and dependents (`network_mode: service:gluetun`) lose networking. Some are SIGKILLed and stay `Exited` (already handled); others keep **running** on the dead namespace — reachable on `localhost`, invisible to the rest of the stack, and still showing **Up (healthy)** because their healthcheck is localhost-based. The old exited-only `recover()` skipped these, which is how Jellyseerr lost Radarr/Sonarr (requests stuck on *Failed*) and Prowlarr lost FlareSolverr while every container looked healthy. `recover()` now also restarts any `gluetun.dependent=true` container whose `StartedAt` predates gluetun's current start (whole-second RFC3339 comparison, busybox-safe). Verified end-to-end on the NAS: a `docker restart gluetun` left all 6 dependents as running zombies, and the watcher auto-restarted every one once gluetun went healthy — no manual intervention.

### Documentation
- **TROUBLESHOOTING.md "Apps Unreachable After a VPN Reconnect (Stale Network Namespace)"**: documents the zombie symptom (Seerr "Unable to connect to Radarr/Sonarr", Failed requests, everything showing Up), why localhost healthchecks mask it, the built-in auto-recovery, and the manual StartedAt check/fix

## [1.7.20] - 2026-06-10

### Changed
- **Jellyseerr** v3.2.0 → v3.3.0

## [1.7.19] - 2026-06-09

### Changed
- **Cloudflared** 2026.5.2 → 2026.6.0

## [1.7.18] - 2026-06-06

### Changed
- **Cloudflared** 2026.5.1 → 2026.5.2
- **Diun** 4.31.0 → 4.33.0
- **Tailscale** v1.98.3 → v1.98.4

## [1.7.17] - 2026-06-06

### Added
- **`gluetun-recover` service**: a lightweight `docker:cli` watcher that revives any VPN-bound container that was SIGKILLed (exit 137) and left `Exited` when gluetun restarts to rebuild its tunnel. Closes a gap deunhealth structurally cannot cover — deunhealth only restarts *running-but-unhealthy* containers, never `Exited` ones, and compose's `depends_on: restart: true` only fires for compose-driven restarts, not gluetun's own `restart: always`. The watcher recovers dead dependents both on its own startup and on each gluetun `health_status: healthy` event. Triggered after qBittorrent silently stayed down for ~8h following a gluetun restart (uptime-kuma alerted but nothing auto-recovered it)

### Changed
- **Six VPN-bound services** (qBittorrent, SABnzbd, Sonarr, Radarr, Prowlarr, FlareSolverr) now carry a `gluetun.dependent=true` label so `gluetun-recover` can identify and restart them

## [1.7.16] - 2026-05-26

### Changed
- **Cloudflared** 2026.5.0 → 2026.5.1. Tested against the live tunnel via one-off container swap (precheck PASS on all 5 DNS/UDP/TCP targets, Jellyfin returned 302 via HTTPS, no behaviour change observed)

### Fixed
- **`configure-apps.sh` timing out on first-boot installs**: `wait_for_service` had a hard 60s deadline, but Sonarr/Radarr first-run DB migrations routinely take 90-120s on NAS hardware. The script would fail every app in sequence on a fresh stack. Default raised to 180s with a `WAIT_TIMEOUT` env override for tuning. Reported on Reddit
- **Cloudflared `config.yml` silently failing to write**: REMOTE-ACCESS.md instructed `sudo chown -R 65532:65532 cloudflared/` at step 1 (correctly — the container needs to write `cert.pem` during `tunnel login`), then `cat > cloudflared/config.yml` at step 3 — which now silently fails because the shell user no longer owns the directory. Step 3 file ops switched to `sudo tee` + `sudo chown`, with a one-line note explaining why. Reported on Reddit
- **`mv cloudflared/*.json cloudflared/credentials.json` erroring on re-run**: if a user re-ran setup, the glob matched only the already-renamed `credentials.json` and `mv` refused to move a file to itself. Replaced with `find ... -not -name credentials.json` which is idempotent. Reported on Reddit

### Added
- **REMOTE-ACCESS.md Traefik prerequisite callout**: the Cloudflare tunnel forwards to `http://traefik:80`; without Traefik running the tunnel comes up clean and then errors with 1016 / `no such host`, which is hard to diagnose. Added an upfront prereq pointing to LOCAL-DNS.md (or a single deploy command). Reported on Reddit
- **REMOTE-ACCESS.md note on apex DNS conflicts**: Cloudflare auto-creates an A record for the apex when a domain is added, so `tunnel route dns ... yourdomain.com` errors with "already exists" on the apex command (the wildcard succeeds). Added a one-liner pointing users to delete the existing record in the Cloudflare dashboard
- **TROUBLESHOOTING.md "Gluetun: Harmless Log Noise on Startup"**: documents the two cosmetic gluetun warnings (`/tmp/gluetun/ip permission denied` and the ICMP healthcheck falling back to DNS) that users keep reading as fatal. Includes a `wget ifconfig.me` test to confirm the VPN is actually working. Reported on Reddit
- **SETUP.md docker group tip**: kept the existing `sudo` recommendation but added the `usermod -aG docker $USER` one-liner so users who want to skip the `sudo` prefix know how

### Documentation
- **REFERENCE.md FlareSolverr row**: now notes the service is inactive until added as an Indexer Proxy in Prowlarr (with a link to the APP-CONFIG step). New users had FlareSolverr running but no Prowlarr proxy configured, then assumed it was broken when no traffic appeared in its logs

---

## [1.7.15] - 2026-05-25

### Changed
- **dnscrypt-proxy** 2.1.14 → 2.1.16

### Added
- **Tailscale subnet router** (optional): new `docker-compose.tailscale.yml` and [docs/TAILSCALE.md](docs/TAILSCALE.md) for reaching the whole LAN (Pi-hole, `*.lan` domains, admin UIs, Home Assistant) from anywhere — including hotel WiFi and CGNAT networks where IPv4 inbound is unavailable. Pinned to `tailscale/tailscale:v1.98.3`, runs as a host-network container with `NET_ADMIN`, advertises `LAN_SUBNET` from `.env`. Complementary to Cloudflared, not a replacement

### Documentation
- **`+ remote access` reframed as one tier with two combinable paths** — Cloudflared (public HTTPS for Jellyfin/Seerr) and Tailscale (private mesh VPN for the whole LAN). Updated across SETUP, README, REMOTE-ACCESS, TAILSCALE, REFERENCE, ARCHITECTURE. The decision point lives in SETUP.md's "+ remote access" section; per-path docs are scoped to that path with a brief cross-link to the other
- **REMOTE-ACCESS.md**: now scoped to the Cloudflared path, with a one-line callout pointing to TAILSCALE.md for the alternate path

---

## [1.7.14] - 2026-05-23

### Changed
- **Pi-hole** 2026.04.1 → 2026.05.0
- **Cloudflared** 2026.3.0 → 2026.5.0
- **Traefik** v3.6 → v3.7

### Fixed
- **`configure-apps.sh` hanging at "Configuring qBittorrent..."**: `wait_for_service` polled with `curl` and no `--max-time`, so a single hung connection (qBit accepting TCP but not responding during Gluetun init) silently extended the advertised 60s timeout into many minutes. Now bounded per-call, bounded wall-clock, with a 10s heartbeat showing the last HTTP code so users know it's working. Reported on Reddit
- **Cloudflared `No file cert.pem` on tunnel create**: the `sudo chown -R 65532:65532 cloudflared/` step (required on UGOS/Synology where NAS ACLs override POSIX perms) was buried as a "troubleshooting note" after the `tunnel login` command. Most users hit this on first run before seeing the note. Promoted to a required pre-step. Dropped the `chmod 777` line — doesn't actually work under ACLs. Reported on Reddit

### Added
- **`configure-apps.sh` Gluetun pre-flight check**: bail fast with a clear message if Gluetun isn't `healthy`. qBittorrent and the *arr services share Gluetun's network namespace, so without it they can't respond — without this check, the user just sees a long hang
- **TROUBLESHOOTING.md "Seerr: /app/config volume mount was not configured properly"**: documents the Seerr first-run startup check (stricter than Jellyseerr was), usually caused by a half-initialised `seerr-config` volume from an interrupted start. Fix is wipe + recreate. Reported on Reddit

---

## [1.7.13] - 2026-05-02

### Changed
- **Sonarr** 4.0.16 → 4.0.17 (patch)
- **Radarr** 6.0.4 → 6.1.1 (minor)

---

## [1.7.12] - 2026-04-28

### Changed
- **Pi-hole** 2026.04.0 → 2026.04.1 (Core 6.4.1 → 6.4.2, FTL 6.6 → 6.6.1)

### Documentation
- **TROUBLESHOOTING.md**: Added "Pi-hole: Gravity Update Fails With Empty Status" — the empty `Status: ()` symptom comes from a root-owned file in `/etc/pihole/listsCache/` (a relic from older Pi-hole images). Includes diagnose and `chown` fix
- **Routine `up -d` examples** (REFERENCE.md, UPGRADING.md): Note that users who also run utilities (beszel, configarr, duc, diun, deunhealth, uptime-kuma) should add `-f docker-compose.utilities.yml` to suppress the "orphan containers" warning. Core-only users can ignore. MAINTENANCE.md already has a dedicated "All Stacks" section for the multi-file invocation

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
