# Architecture Overview

This guide explains how the stack fits together and why it's designed this way.

## The Request-to-Watch Flow

When someone requests a movie or TV show, here's what happens:

```
┌─────────────┐     ┌──────────────┐     ┌───────────┐     ┌─────────────┐     ┌──────────┐
│   Seerr     │────▶│ Sonarr/Radarr│────▶│ Prowlarr  │────▶│ qBittorrent │────▶│ Jellyfin │
│ (request)   │     │ (manage)     │     │ (indexers)│     │   SABnzbd   │     │ (watch)  │
│             │     │              │     │           │     │ (download)  │     │          │
└─────────────┘     └──────────────┘     └───────────┘     └─────────────┘     └──────────┘
                                              │                   │                  │
                                              └───────────────────┘                  │
                                          Through VPN (Gluetun)               Not through VPN
```

> Only **Prowlarr** and the **download clients** (qBittorrent/SABnzbd) run through the VPN. Seerr, Sonarr, Radarr and Jellyfin run on the bridge — Sonarr/Radarr only contact metadata providers and internal services, so they need no VPN.

1. **Seerr** - User requests a show or movie
2. **Sonarr/Radarr** - Searches for releases, sends to download client
3. **Prowlarr** - Provides indexers (torrent + Usenet) to Sonarr/Radarr
4. **qBittorrent** - Downloads torrents (through VPN)
5. **SABnzbd** - Downloads from Usenet (through VPN)
6. **Jellyfin** - Streams the completed files

> **Why both qBittorrent and SABnzbd?** Torrents are free but can be slow/unreliable. Usenet costs ~$5/month but is faster, more reliable, and has no ratio requirements. Most users configure both - Sonarr/Radarr will try Usenet first, fall back to torrents.

## VPN Protection

**Why VPN?** Your ISP can see BitTorrent traffic. The VPN encrypts this so they only see "encrypted traffic to VPN server".

**Why not everything through VPN?** Streaming from Jellyfin doesn't need protection (you're watching your own files) and VPN would slow it down.

```
                              ┌─────────────────────────────────────────┐
                              │            GLUETUN (VPN)                │
                              │                                         │
Internet ◄───VPN Tunnel───────│  qBit   SABnzbd   Prowlarr   Flare      │
                              │    ▲        ▲         ▲        ▲        │
                              │    │        │         │        │        │
                              │    └────────┴─────────┴────────┘        │
                              │         All share localhost             │
                              └─────────────────────────────────────────┘
                                                 │
                                    ─ ─ ─ ─ ─ ─ ─│─ ─ ─ ─ ─ ─ ─
                                                 │
                              ┌──────────────────┴──────────────────────┐
Internet ◄──Cloudflare Tunnel─│  Jellyfin    Seerr                     │
  (remote)                    │  (stream)    (requests)                 │
                              │                                         │
LAN only ◄────────────────────│  Pi-hole   Sonarr    Radarr   Bazarr   │
  (local)                     │  (DNS)     (manage)  (manage)  (subs)   │
                              └─────────────────────────────────────────┘
```

> **Note:** Download services go through VPN to hide torrent traffic from your ISP. Streaming services don't need VPN protection. Remote access uses Cloudflare Tunnel (not VPN) - see [Access Levels](#access-levels).

## Service Connections

Services behind Gluetun (qBittorrent, SABnzbd, Prowlarr, FlareSolverr) use `localhost` to talk to each other. Crossing the bridge↔VPN boundary needs care — the VPN namespace's DNS is Pi-hole, which can't resolve Docker container names, so VPN-side services must reach bridge services by **IP**.

```
Bridge → VPN-side (use gluetun):     VPN-side → bridge (use IP):
─────────────────────────────        ──────────────────────────
Sonarr → qBittorrent                 Prowlarr → Sonarr
  └── gluetun:8085                      └── 172.20.0.10:8989
Radarr → SABnzbd                     Prowlarr → Radarr
  └── gluetun:8080                      └── 172.20.0.11:7878

Bridge → bridge (use name):          Behind-VPN → behind-VPN (localhost):
─────────────────────────────        ──────────────────────────
Seerr/Bazarr → Sonarr                Prowlarr → FlareSolverr
  └── sonarr:8989 / radarr:7878        └── localhost:8191
Sonarr/Radarr → Decypharr
  └── decypharr:8282
```

## Network Layout

All services run on the `arr-stack` network with static IPs:

```
arr-stack network (172.20.0.0/24)
───────────────────────────────────────────────────────────────────────────────────
│ IP           │ Service      │ Notes                          │ Required for     │
├──────────────┼──────────────┼────────────────────────────────┼──────────────────│
│ 172.20.0.3   │ Gluetun      │ VPN gateway (qBit/SAB/Prowlarr)│ Core             │
│ 172.20.0.4   │ Jellyfin     │ Media server                   │ Core             │
│ 172.20.0.8   │ Seerr        │ Request portal                 │ Core             │
│ 172.20.0.9   │ Bazarr       │ Subtitles                      │ Core             │
│ 172.20.0.10  │ Sonarr       │ TV manager (bridge, not VPN)   │ Core             │
│ 172.20.0.11  │ Radarr       │ Movie manager (bridge, not VPN)│ Core             │
│ 172.20.0.5   │ Pi-hole      │ DNS server                     │ Core             │
│ 172.20.0.7   │ Decypharr    │ TorBox debrid client (bridge, not VPN) │ Core     │
│ 172.20.0.2   │ Traefik      │ Reverse proxy                  │ + local DNS      │
│ 172.20.0.12  │ Cloudflared  │ Tunnel to Cloudflare           │ + remote access (Cloudflared) │
│ host-network │ Tailscale    │ Mesh VPN subnet router         │ + remote access (Tailscale)   │
│ 172.20.0.13  │ Uptime Kuma  │ Monitoring                     │ Optional         │
│ 172.20.0.14  │ duc          │ Disk usage                     │ Optional         │
│ 172.20.0.15  │ Beszel       │ System monitoring              │ Optional         │
│ 172.20.0.16  │ DIUN         │ Image update notifier          │ Optional         │
│ 172.20.0.17  │ stremio-jellyfin │ Stremio addon for local Jellyfin library   │ Optional │
│ 172.20.0.18  │ magnetio-scraper │ Torrent provider scraper backend           │ Optional │
│ 172.20.0.19  │ magnetio-redis   │ Cache backend for Magnetio                 │ Optional │
───────────────────────────────────────────────────────────────────────────────────
```

## Access Levels

```
┌─────────────────────────────────────────────────────────────────────────┐
│                             CORE                                         │
│                      Access via NAS_IP:port                              │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌───────────┐            │
│  │ :8096     │  │ :8989     │  │ :7878     │  │ :5055     │  ...       │
│  │ Jellyfin  │  │ Sonarr    │  │ Radarr    │  │   Seerr   │            │
│  └───────────┘  └───────────┘  └───────────┘  └───────────┘            │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ + Pi-hole + Traefik
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          + LOCAL DNS                                     │
│                      Access via .lan domains                             │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐               │
│  │ jellyfin.lan  │  │ sonarr.lan    │  │ radarr.lan    │  ...          │
│  └───────────────┘  └───────────────┘  └───────────────┘               │
│                                                                          │
│  Your device → Pi-hole (DNS) → Traefik → Service                        │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ + Cloudflared and/or Tailscale
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        + REMOTE ACCESS                                   │
│                   Access from outside your home                          │
│                                                                          │
│  ┌─── Path a: Cloudflared (public HTTPS via your domain) ──────────┐    │
│  │                                                                  │    │
│  │  ┌─────────────────────┐  ┌─────────────────────┐               │    │
│  │  │ jellyfin.domain.com │  │ seerr.domain.com     │  ...          │    │
│  │  └─────────────────────┘  └─────────────────────┘               │    │
│  │  Phone → Cloudflare → Tunnel → Traefik → Service                │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  ┌─── Path b: Tailscale (private mesh VPN, full LAN access) ───────┐    │
│  │                                                                  │    │
│  │  ┌──────────────┐  ┌────────────────┐  ┌──────────────────────┐ │    │
│  │  │ sonarr.lan   │  │ pihole.lan     │  │ homeassistant.lan    │ │    │
│  │  └──────────────┘  └────────────────┘  └──────────────────────┘ │    │
│  │  Phone → Tailscale → LAN (10.10.0.0/24) → Service               │    │
│  │  (No public exposure; only authorised tailnet devices reach LAN)│    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  Combinable: run either path or both.                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

## Container Security

All containers run with hardened defaults:

- **`no-new-privileges`** — Prevents processes from gaining additional privileges via `setuid`/`setgid` binaries
- **`cap_drop: ALL`** — Drops all Linux capabilities by default

Two YAML anchors define security profiles in each compose file:

| Anchor | Used by | Capabilities |
|--------|---------|-------------|
| `x-security` | All non-LSIO services | None by default (services add back only what they need) |
| `x-security-lsio` | Sonarr, Radarr, Prowlarr, qBittorrent, SABnzbd, Bazarr | `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE` (s6-overlay needs these to switch users during init) |

Decypharr uses its own inline security block (not the shared anchor): same four caps plus `FOWNER` — its entrypoint's `chmod /app` during root-init-then-drop-privileges needs it, unlike the LSIO images.

Services that write to Docker volumes as root add back `CHOWN` + `DAC_OVERRIDE` (Jellyfin, Seerr, Uptime Kuma, DUC, Beszel, DIUN, Configarr). Services with read-only or no volumes don't need any (FlareSolverr, Cloudflared, Traefik, Deunhealth, Beszel-agent).

Additional requirements:
- **Gluetun** — adds `NET_ADMIN` (required to create VPN tunnel interfaces)
- **Uptime Kuma** — adds `FOWNER` (sets ownership on created files)
- **Pi-hole** — adds `NET_ADMIN`, `NET_RAW`, `CHOWN`, `SETUID`, `SETGID`, `SETFCAP`, `SYS_NICE`, `DAC_OVERRIDE`, and disables `no-new-privileges` (FTL uses `setcap` at startup)

## Design Decisions

**Static IPs:** Prevents "container not found" errors after restarts. Services always know where to find each other.

**Separate compose files:** Deploy only what you need. Core users don't need Traefik, Cloudflared, or Tailscale.

**VPN for downloads only:** Protects privacy where it matters, doesn't slow down streaming.

**Pi-hole for DNS:** Provides internal Docker DNS and ad-blocking. Optionally enables `.lan` domains (+ local DNS).

**Named volumes:** Data persists across container updates. Easy to backup with the included script.

**No fail2ban:** External access goes through Cloudflare Tunnel, which handles rate limiting and bot protection at the edge. LAN services aren't exposed to the internet. Services with auth (qBittorrent, Pi-hole, Traefik dashboard) have their own brute-force protections. fail2ban would add complexity with no practical benefit.
