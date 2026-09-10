# ultimate-arr-stack

A Docker Compose media stack for a NAS: request a film or a series, it downloads through a VPN, and it appears in Jellyfin. Ships the *arr apps, two download clients, encrypted local DNS with `.lan` names, HTTPS with auth, monitoring, and tiered backups.

[![License: CC BY-NC 4.0](https://img.shields.io/badge/license-CC%20BY--NC%204.0-lightgrey)](https://creativecommons.org/licenses/by-nc/4.0/)

> **This is a fork, and a substantially modified one.** Upstream is [Pharkie/ultimate-arr-stack](https://github.com/Pharkie/ultimate-arr-stack), itself forked from [TheRealCodeVoyage/arr-stack-setup-with-pihole](https://github.com/TheRealCodeVoyage/arr-stack-setup-with-pihole). This tree runs on a Ugreen NAS on a segmented home network, and everything below describes **this** tree — commands are checked against the scripts they ship in, not copied from upstream's README. What changed, and why it matters if you deploy this: [Differences from upstream](#differences-from-upstream).

**Contents:** [What's in the stack](#whats-in-the-stack) · [Architecture](#architecture) · [Requirements](#requirements) · [Quick start](#quick-start) · [Access](#access) · [Common operations](#common-operations) · [Testing](#testing) · [Backups and restore](#backups-and-restore) · [Troubleshooting](#troubleshooting) · [Documentation](#documentation) · [Repository layout](#repository-layout) · [Differences from upstream](#differences-from-upstream) · [Development and verification](#development-and-verification) · [License and attribution](#license-and-attribution)

## What's in the stack

| Group | Services | Role |
|---|---|---|
| Requests | **Seerr** | The front door: users ask for a title, it routes to the right app |
| Library | **Sonarr**, **Radarr** | Series and film management, quality profiles, imports |
| Indexers | **Prowlarr** | Indexer manager; keeps Sonarr/Radarr in sync |
| Subtitles | **Bazarr** | Subtitle search and sync |
| Downloads | **qBittorrent** (torrents), **SABnzbd** (Usenet), **Decypharr** (debrid) | All egress through the VPN except where deliberately not |
| Playback | **Jellyfin** | Media server and apps |
| VPN | **Gluetun**, **vpn-socks5** | WireGuard tunnel for the download clients; SOCKS proxy |
| DNS | **Pi-hole**, **dnscrypt-proxy** | Network-wide DNS + ad blocking, upstream encrypted |
| Edge | **Traefik**, **Tailscale**, **cloudflared** (opt-in) | Reverse proxy, mesh VPN, Cloudflare tunnel |
| Add-ons | **Magnetio** (addon, scraper, redis), **stremio-jellyfin** | Optional extras |
| Operations | **Uptime Kuma**, **Homepage**, **Beszel** + agent, **diun**, **duc**, **configarr**, **deunhealth**, **gluetun-recover**, **gluetun-rotator**, **docker-socket-proxy** | Monitoring, dashboards, disk usage, config-as-code, self-healing |

## Architecture

```
   browser ──▶ Traefik ──────────────┐   HTTPS + basic auth, *.lan names
              (arr-core bridge,      │
               172.20.0.0/24)        │
                                     ▼
   Seerr ──▶ Sonarr / Radarr ──▶ qBittorrent / SABnzbd ──▶ Gluetun ──▶ VPN provider
                    │                                          ▲
                    ▼                                          │
                Jellyfin ◀── media volume (hardlinked, no copies)
                    ▲
   LAN clients ──▶ Pi-hole ──▶ dnscrypt-proxy ──▶ encrypted upstream
```

Three invariants hold the design together:

- **Downloads share Gluetun's network namespace.** A service that should be tunneled is joined to `network_mode: "service:gluetun"`, so a VPN drop stops its traffic rather than leaking it. Recreating Gluetun orphans its dependents — `./scripts/detect-vpn-zombies.sh` exists because those containers keep reporting healthy while having no network at all.
- **One volume, hardlinks.** Media and downloads are siblings on the same filesystem, so an import is a link, not a copy: instant, and no second copy of every file.
- **Pi-hole is a single point of failure by design.** The router hands its address to every DHCP pool, so a Pi-hole that is down is a house with no DNS. That is why restarts never use `docker compose down`, and why the boot reconcile exists.

## Requirements

| | |
|---|---|
| Host | Any Docker host — Ugreen, Synology, QNAP, a Linux box, or a Raspberry Pi 4+. The reference deployment is a Ugreen NAS (aarch64). |
| Docker | Engine + Compose v2, with the ability to run `network_mode: service:*` and macvlan networks |
| Static IP | **Required.** Pi-hole binds `${NAS_IP}:53`; if the address arrives by DHCP after Docker starts, Pi-hole never binds and the network loses DNS |
| Storage | One volume holding `media/` plus `torrents/` and/or `usenet/` as siblings, for hardlinks |
| Secrets | A `.env` (gitignored) built from [.env.example](.env.example) — VPN credentials, app API keys, LAN addresses |
| Optional | Intel/AMD iGPU for hardware transcoding; a Cloudflare account for the tunnel; a Tailscale account; a domain for remote access |

## Quick start

```bash
# 1. Clone
git clone https://github.com/leonardoazeredo/ultimate-arr-stack.git
cd ultimate-arr-stack

# 2. Configure. .env is gitignored and holds every secret and every LAN address.
cp .env.example .env
$EDITOR .env     # NAS_IP, LAN_SUBNET, PUID/PGID, VPN credentials, app API keys

# 3. Bring up the core stack (it creates the arr-core network and DNS first)
docker compose -f docker-compose.arr-stack.yml up -d

# 4. Verify
docker compose -f docker-compose.arr-stack.yml ps      # every service healthy?
dig @<NAS_IP> jellyfin.lan                             # DNS answering?
curl -sI http://<NAS_IP>:8096/System/Info/Public       # Jellyfin responding?
```

Then add the layers you want — each is a separate compose file so one can never take another down:

| Layer | Bring it up | Guide |
|---|---|---|
| Edge: Traefik, `*.lan` DNS, HTTPS with auth | `docker compose -f docker-compose.traefik.yml up -d` | [LOCAL-DNS.md](docs/LOCAL-DNS.md), [HTTPS-LOCAL.md](docs/HTTPS-LOCAL.md) |
| Monitoring, dashboards, configarr, recovery helpers | `docker compose -f docker-compose.utilities.yml up -d` | [UTILITIES.md](docs/UTILITIES.md) |
| Remote access via Tailscale | `docker compose -f docker-compose.tailscale.yml up -d` | [TAILSCALE.md](docs/TAILSCALE.md) |
| Remote access via Cloudflare tunnel | copy `cloudflared/config.yml.example` to `config.yml`, then `docker compose -f docker-compose.cloudflared.yml --profile tunnel up -d` | [REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md) |
| Magnetio add-on | `docker compose -f docker-compose.magnetio.yml up -d` | [UTILITIES.md](docs/UTILITIES.md) |

The cloudflared stack is **opt-in**: it sits behind a `tunnel` profile precisely so a `up -d` over every compose file cannot start a tunnel that has no config to read.

The full walkthrough — directories on the host, app configuration, DNS, HTTPS, remote access — is [docs/SETUP.md](docs/SETUP.md). App setup is either [script-assisted](docs/APP-CONFIG-QUICK.md) or [manual](docs/APP-CONFIG.md).

## Access

| Service | LAN | `.lan` (with the edge layer) | Remote |
|---|---|---|---|
| Jellyfin | `NAS_IP:8096` | `https://jellyfin.lan` | yes, if exposed |
| Seerr | `NAS_IP:5055` | `https://seerr.lan` | yes, if exposed |
| Sonarr / Radarr / Prowlarr / Bazarr | `NAS_IP:8989` / `:7878` / `:9696` / `:6767` | `https://sonarr.lan`, `https://radarr.lan`, `https://prowlarr.lan`, `https://bazarr.lan` | LAN only |
| qBittorrent / SABnzbd | `NAS_IP:8085` / `:8082` | `https://qbit.lan`, `https://sabnzbd.lan` | LAN only |
| Pi-hole admin | `NAS_IP:8081/admin` | `https://pihole.lan` | LAN only |
| Uptime Kuma | `NAS_IP:3001` | `https://uptime.lan` | LAN only |
| Traefik dashboard | — (see the note below) | `https://traefik.lan` | LAN only |
| Homepage / Beszel / duc | — (no published port; reached through Traefik) | `https://homepage.lan`, `https://beszel.lan`, `https://duc.lan` | LAN only |

> **On the Traefik dashboard port.** `docker-compose.traefik.yml` publishes `9090:8080`, but the
> live static config sets `api.insecure: false`, so that port accepts a connection and then resets
> it — nothing is served there. The dashboard is reached through `traefik.lan` (its router targets
> `api@internal` behind the auth middleware). The published mapping is a leftover, and removing it
> would be tidier than documenting it.

The `.lan` names need the edge layer, and the `https` URLs need its auth middleware; Jellyfin and Seerr keep their own app-level login on top. The complete matrix, including which services are deliberately unpublished, is [docs/REFERENCE.md](docs/REFERENCE.md).

## Common operations

| Task | Command |
|---|---|
| Health at a glance | `docker compose -f docker-compose.arr-stack.yml ps` |
| Restart safely — **never** `down` | `./scripts/restart-stack.sh [all\|arr\|traefik\|utilities\|magnetio\|cloudflared]` |
| Reconcile every stack after a reboot | `./scripts/boot-compose-up.sh` |
| Prove traffic is going through the VPN | `./scripts/check-vpn.sh` |
| Find containers stranded on a dead VPN namespace | `./scripts/detect-vpn-zombies.sh` |
| Detect the credential-propagation drift class | `./scripts/detect-credential-drift.sh` |
| Configure the apps through their APIs | `./scripts/configure-apps.sh` |
| Clear stuck download-queue items | `./scripts/queue-cleanup.sh` |
| Repair Sonarr folder names / Radarr paths | `./scripts/fix-sonarr-folders.sh`, `./scripts/fix-radarr-paths.sh` |
| Back up config volumes | `./scripts/arr-backup.sh` |
| Apply tiered retention to backups | `./scripts/backup-prune.sh` |
| Deploy the current branch to the host | `./scripts/sync-nas.sh` |
| Update images | [docs/UPGRADING.md](docs/UPGRADING.md) |

> ⚠️ **Two commands this repo never runs, and you should not either.** `docker compose down` takes Pi-hole with it and therefore kills DNS for the whole network; and `--remove-orphans` deletes every container from the *other* compose files, because this stack's services share a project name across files. Both have caused real outages — see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Testing

Three layers, and none of them needs a cloud CI account:

| Layer | Run it with | What it proves |
|---|---|---|
| Static + behavioural (bats) | `./tests/run-tests.sh` | Compose validity, duplicate ports and IPs, pinned images, secret hygiene, `.env` documentation, script behaviour, hook wiring. Needs no Docker and no host access. It ends with a census — `executed / skipped / failed`, the reasons for the skips, and a warning when the git-gated tests produced no verdict on this host. Read that line; "ok" is not the same as "covered". |
| Python toolkit | `./tests/toolkit/pytest.sh` | The `scripts/lib/*.py` modules. Exits **77**, never 0, when Docker is unavailable — an absent oracle must not read as a passing one. |
| End-to-end (Playwright) | `npm run test:e2e` | Real HTTP, UI, VPN-egress and DNS behaviour against a live stack. Sixteen of its tests need the Docker socket, so the full run happens on the host itself. A floor reporter fails any full-suite run that executed fewer than 30 tests: a missing or rotted `.env.e2e` used to produce a green run that had executed almost nothing. |

Guards here are **proved able to fail**, not assumed to work. [tests/mutation/](tests/mutation/) holds a corpus of defects this repo actually shipped, which the suite must kill; a generated sweep hunts for code no test guards; and `tests/mutation-corpus.bats` re-checks in seconds that every corpus pattern still changes its target. After touching a guard, run `./tests/mutation/run-mutations.sh` — and the manual deploy workflow does exactly that for the guards a change touches. The rules that keep this honest are written down in [tests/mutation/README.md](tests/mutation/README.md) and [docs/TEST-HARDENING-LOG.md](docs/TEST-HARDENING-LOG.md).

## Backups and restore

`./scripts/arr-backup.sh` archives the config volumes that cannot be regenerated — app databases, credentials, hand-edited resolver and DNS config — to a single tarball; `./scripts/backup-prune.sh` then applies grandfather-father-son tiers so the directory does not grow without bound. Coverage and caveats: [docs/BACKUP.md](docs/BACKUP.md). Rebuilding a host from a backup: [docs/RESTORE.md](docs/RESTORE.md).

## Troubleshooting

[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) is the full list. The four that cost the most time here:

- **DNS is dead but Pi-hole looks fine.** The container is running, healthy, and serving nobody, because its published ports vanished. The tell is an empty `PORTS` column in `docker ps` and nothing listening on `NAS_IP:53`.
- **Downloads stopped, everything is green.** A VPN recreate orphaned its dependents; containers that only check localhost keep reporting healthy with no network. Assert on egress, not on health status.
- **A reboot left services unreachable.** Docker restores `restart: always` containers itself, and address-pinned bindings can silently fail. `./scripts/boot-compose-up.sh` reconciles every stack; it is worth having scheduled at boot.
- **The stack came up half-missing.** Almost always `--remove-orphans`, or a service recreated through the wrong compose file.

## Documentation

| Doc | Purpose |
|---|---|
| [SETUP.md](docs/SETUP.md) | The full install walkthrough |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the pieces fit together |
| [REFERENCE.md](docs/REFERENCE.md) | Cheat sheet: URLs, ports, IPs, commands |
| [APP-CONFIG-QUICK.md](docs/APP-CONFIG-QUICK.md) / [APP-CONFIG.md](docs/APP-CONFIG.md) / [APP-CONFIG-ADVANCED.md](docs/APP-CONFIG-ADVANCED.md) | Configuring each app, script-assisted or manual |
| [LOCAL-DNS.md](docs/LOCAL-DNS.md) / [HTTPS-LOCAL.md](docs/HTTPS-LOCAL.md) | `.lan` names, TLS and auth |
| [REMOTE-ACCESS.md](docs/REMOTE-ACCESS.md) / [TAILSCALE.md](docs/TAILSCALE.md) | Reaching the stack from outside |
| [UTILITIES.md](docs/UTILITIES.md) | Monitoring, dashboards, configarr, disk usage |
| [UPGRADING.md](docs/UPGRADING.md) / [MAINTENANCE.md](docs/MAINTENANCE.md) | Image bumps and routine upkeep |
| [BACKUP.md](docs/BACKUP.md) / [RESTORE.md](docs/RESTORE.md) | Protecting and rebuilding config |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptom-first fixes |
| [HOME-ASSISTANT.md](docs/HOME-ASSISTANT.md) | Completion notifications |
| [MIGRATION-arr-off-vpn.md](docs/MIGRATION-arr-off-vpn.md) | Why Sonarr and Radarr are deliberately outside the tunnel |
| [EXIT-NODE-PROJECT-LOG.md](docs/EXIT-NODE-PROJECT-LOG.md) / [TEST-HARDENING-LOG.md](docs/TEST-HARDENING-LOG.md) | Audited project logs: what shipped, what was wrong, what is still open |
| [LEGAL.md](docs/LEGAL.md) | Intended use and disclaimer |

## Repository layout

```
docker-compose.arr-stack.yml     core: VPN, apps, downloads, DNS, media
docker-compose.traefik.yml       reverse proxy + macvlan for *.lan
docker-compose.utilities.yml     monitoring, dashboards, configarr, recover/rotate helpers
docker-compose.tailscale.yml     Tailscale subnet router
docker-compose.cloudflared.yml   optional Cloudflare tunnel (opt-in profile)
docker-compose.magnetio.yml      Magnetio add-on, scraper and redis
scripts/                         operations, one concern per script
tests/                           bats suite, Python toolkit, Playwright e2e, mutation framework
docs/                            every guide, plus the audited project logs
pihole/dnsmasq.d/                local DNS records
traefik/dynamic/                 routers and middleware
terraform/                       app configuration as code
```

## Differences from upstream

Deploying this fork is not the same as deploying upstream's. The load-bearing differences:

- **The Docker network is `arr-core`** (upstream: `arr-stack`), and compose project/volume names are pinned explicitly so a rename cannot orphan data. Anything referencing the old network name needs updating.
- **DNS is encrypted end to end.** Pi-hole forwards to the in-stack `dnscrypt-proxy` rather than to a public resolver in the clear.
- **The Cloudflare tunnel is opt-in** behind a compose profile, so an unconditional `up -d` cannot start a tunnel with no configuration and crash-loop it.
- **The Tailscale exit-node role runs on the router**, not in this stack; the NAS-side implementation was built, measured, and decommissioned. The history and the numbers are in [docs/EXIT-NODE-PROJECT-LOG.md](docs/EXIT-NODE-PROJECT-LOG.md).
- **A much heavier verification harness**: a mutation corpus with a triage ledger, a containerised Python and coverage toolkit, an executed-count floor on the end-to-end suite, and a skip census in the bats runner.
- **Additional operations scripts**: boot reconciliation, VPN zombie detection, credential-drift detection, branch deployment, Sonarr/Radarr repair.

## Development and verification

**LLM-generated, human-reviewed.** This code was written with [Claude Code](https://claude.ai/claude-code) (Anthropic), planned, directed and verified by the human author, whose review extends past the generated output to the tests and the deployments. It has still had limited manual review — make your own checks before trusting it with your library.

Work lands the same way every time: a **feature branch**, tested against the real deployment before it can reach `main`, and `main` deployed from git rather than by copying files. The full rule, including why testing happens on the host rather than in CI, is in [CLAUDE.md](CLAUDE.md).

## License and attribution

Documentation, configuration files and examples are licensed [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) (Attribution-NonCommercial). The bundled applications (Sonarr, Radarr, Jellyfin, and the rest) keep their own licenses.

Forked from [Pharkie/ultimate-arr-stack](https://github.com/Pharkie/ultimate-arr-stack), itself forked from [TheRealCodeVoyage/arr-stack-setup-with-pihole](https://github.com/TheRealCodeVoyage/arr-stack-setup-with-pihole).

This project provides configuration for **legal, open-source software** for managing a personal media library. See [docs/LEGAL.md](docs/LEGAL.md) for intended use, your responsibilities, and the disclaimer.
