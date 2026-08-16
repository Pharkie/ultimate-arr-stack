<!--
  LLM-ASSISTED DOCUMENT: drafted with Claude, human-reviewed. Read and
  understand each step before running it. The curl snippets mutate live app
  config on the NAS — review them against your actual settings first.
-->

# Migration: move Sonarr + Radarr off the VPN

**Branch:** `feat/arr-off-vpn` · **Status:** merged and live — this migration shipped; Sonarr and
Radarr already run off the VPN namespace in `docker-compose.arr-stack.yml`. Kept here as a record
of why and how. Note: the `arr-stack` Docker network referenced throughout this doc was later
renamed to `arr-core` (same CIDR, no renumbering) during a subsequent network-segmentation pass —
the IPs/procedure below are otherwise unchanged.

## Why

Today qBittorrent, SABnzbd, **Sonarr, Radarr**, Prowlarr and FlareSolverr all share
gluetun's network namespace (`network_mode: service:gluetun`). Every VPN reconnect
or gluetun health blip makes **all** of them briefly unreachable to the bridge
services (Jellyseerr, Bazarr). That is the cause of the intermittent
`Unable to get queue from Radarr/Sonarr` errors and the in-flight Jellyseerr
request failures we saw on 2026-06-27.

Sonarr and Radarr never talk to indexers or peers — only to metadata providers
(TVDB/TMDB) and internal services. So they gain nothing from the VPN. Moving just
those two onto the `arr-stack` bridge makes the Jellyseerr/Bazarr ↔ Sonarr/Radarr
path immune to VPN flaps, and means a gluetun restart no longer SIGKILLs them.

## Why Prowlarr stays behind the VPN (scope decision)

The original idea included Prowlarr. **It is deliberately excluded.** Prowlarr (with
FlareSolverr) is the component that actually queries the torrent indexers — that is
exactly the traffic the VPN exists to hide. Moving it out would:

1. **Expose indexer scraping to your home/ISP IP** (privacy/legal regression).
2. **Re-introduce geo-blocking** — UK home IP gets HTTP 451 on EZTV; the Netherlands
   VPN exit is what fixed that (`vpn_exit_country_indexer_block`).
3. **Break FlareSolverr** — its solved Cloudflare cookies must match Prowlarr's exit
   IP, which requires them to share the gluetun namespace.

If you want Prowlarr moved anyway, that is a separate decision with the above costs.

## What the branch changes (in git)

| File | Change |
|------|--------|
| `docker-compose.arr-stack.yml` | Sonarr → bridge IP `172.20.0.10`, own `8989:8989`; Radarr → bridge IP `172.20.0.11`, own `7878:7878`. Removed `network_mode: service:gluetun`, the gluetun `depends_on`, and the `gluetun.dependent` label from both. Removed 8989/7878 from gluetun's `ports`. |
| `traefik/dynamic/local-services.yml` | `sonarr-lan` → `172.20.0.10:8989`, `radarr-lan` → `172.20.0.11:7878`. |
| `docs/REFERENCE.md` | Service Connection Guide updated to the new topology. |

Static IPs `.10`/`.11` are free (outside the `172.20.0.128/25` dynamic range) and
avoid the gluetun-IP-collision class of bug noted in `CLAUDE.md`.

## What must change on the NAS (app config — NOT in git)

These live in the config volumes, so they are applied during deploy, not by the
branch. New connection targets:

| From | To | Old value | **New value** |
|------|-----|-----------|---------------|
| Sonarr → qBittorrent | download client | `localhost:8085` | `gluetun:8085` |
| Sonarr → SABnzbd | download client | `localhost:8080` | `gluetun:8080` |
| Radarr → qBittorrent | download client | `localhost:8085` | `gluetun:8085` |
| Radarr → SABnzbd | download client | `localhost:8080` | `gluetun:8080` |
| Prowlarr → Sonarr | Settings ▸ Apps, "Sonarr server" | `localhost:8989` | `sonarr:8989` |
| Prowlarr → Radarr | Settings ▸ Apps, "Radarr server" | `localhost:7878` | `radarr:7878` |
| Prowlarr → Sonarr/Radarr | the "Prowlarr Server" URL field in each app | `localhost:9696` | `gluetun:9696` |
| Bazarr → Sonarr | Settings ▸ Sonarr | `gluetun:8989` | `sonarr:8989` |
| Bazarr → Radarr | Settings ▸ Radarr | `gluetun:7878` | `radarr:7878` |
| Jellyseerr → Sonarr | Settings ▸ Services | `gluetun:8989` | `sonarr:8989` |
| Jellyseerr → Radarr | Settings ▸ Services | `gluetun:7878` | `radarr:7878` |

> Prowlarr stays in the VPN namespace, so within Prowlarr the FlareSolverr proxy
> stays `localhost:8191` (unchanged). Prowlarr reaches the bridge-side Sonarr/Radarr
> because gluetun's `FIREWALL_OUTBOUND_SUBNETS` already allows `172.20.0.0/24`.

## Deploy procedure (branch-first, per CLAUDE.md)

```sh
# 0. PRE-FLIGHT — back up the four config volumes
stamp=$(date +%Y%m%d-%H%M%S)
for v in sonarr-config radarr-config prowlarr-config bazarr-config; do
  docker run --rm -v arr-stack_${v}:/src:ro -v /mnt/@usb/sdd1/arr-backups:/bak alpine \
    tar czf /bak/${v}-premigration-${stamp}.tgz -C /src .
done

# 1. Pull the branch on the NAS
cd /volume1/docker/arr-stack && git fetch && git checkout feat/arr-off-vpn

# 2. Recreate ONLY the affected services (never `down` — kills Pi-hole DNS)
#    gluetun must recreate too because its published ports changed.
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate \
  gluetun sonarr radarr qbittorrent sabnzbd prowlarr flaresolverr

# 3. Apply the NAS app-config changes from the table above (UI or the API
#    snippets below), then restart traefik to reload the dynamic config:
docker exec traefik kill -HUP 1 2>/dev/null || docker restart traefik
```

### Optional: scripted app-config updates (review before running)

```sh
RK=<radarr-key>; SK=<sonarr-key>   # from each container's /config/config.xml
# Sonarr/Radarr download clients: flip host localhost -> gluetun
for pair in "8989:$SK" "7878:$RK"; do
  port=${pair%%:*}; key=${pair##*:}
  curl -s -H "X-Api-Key: $key" "http://localhost:$port/api/v3/downloadclient" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);[print(c["id"],c["name"],[f for f in c["fields"] if f["name"]=="host"]) for c in d]'
  # inspect, then PUT each client back with field host="gluetun"
done
```
(qBit/SAB hosts and the Prowlarr/Bazarr/Jellyseerr URLs are easiest to flip in each
UI — they are a handful of fields. Do the UI route unless you want to script all.)

## Verification (all must pass before merge)

1. `docker ps` — sonarr/radarr **healthy**, on `arr-stack` (`docker inspect sonarr --format '{{json .NetworkSettings.Networks}}'` shows `172.20.0.10`, no `service:gluetun`).
2. Sonarr/Radarr **Settings ▸ Download Clients ▸ Test** → green (reaching `gluetun:8085`/`8080`).
3. Prowlarr **Settings ▸ Apps ▸ Test** both → green (reaching `sonarr`/`radarr`).
4. Bazarr + Jellyseerr → Sonarr/Radarr connections test green.
5. Jellyseerr: no `Unable to get queue` errors for 10 min (`docker logs seerr --since 10m | grep -i "download tracker"` → empty).
6. End-to-end: request a test title in Jellyseerr → it reaches Radarr → grabs → qBit downloads → imports.
7. `npm test` — bats + full Playwright suite, all green (run in background).
8. **VPN-still-protects check:** `tests/e2e/vpn-security.spec.ts` codifies this as an automated regression guard — it asserts qBittorrent/Prowlarr/SABnzbd/FlareSolverr egress IPs match Gluetun's exit IP (not home), and that Sonarr/Radarr egress IPs match the host WAN IP (not Gluetun). Manual spot-check if needed: `docker exec qbittorrent curl -s ifconfig.me` returns the **VPN** IP, not home; `docker exec prowlarr curl -s ifconfig.me` returns the **VPN** IP; Sonarr/Radarr will now show the home IP — expected.

## Rollback

```sh
cd /volume1/docker/arr-stack && git checkout main
docker compose -f docker-compose.arr-stack.yml up -d --force-recreate \
  gluetun sonarr radarr qbittorrent sabnzbd prowlarr flaresolverr
# revert the app-config hosts to localhost/gluetun (or restore the volume backups)
docker exec traefik kill -HUP 1 || docker restart traefik
```

## Residual risks

- **Migration breakage** (the real one): ~10 connection fields across 5 apps. A wrong
  host silently breaks one link (e.g. Sonarr can't reach qBit). Mitigated by the
  per-link Test buttons in step 2–4 and the E2E run.
- **Sonarr/Radarr metadata now uses the home IP** — benign (TVDB/TMDB lookups only).
- **Prowlarr still flaps with the VPN** — acceptable: Prowlarr↔Sonarr/Radarr sync is
  not real-time and not the user-facing path; the fix targets the Jellyseerr path.
