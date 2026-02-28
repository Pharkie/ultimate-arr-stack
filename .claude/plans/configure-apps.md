# Plan: Automated App Configuration Script

## Context

APP-CONFIG.md walks users through ~40+ manual web UI steps across 8 services. Most of these are deterministic settings (root folders, download clients, metadata, naming, inter-service connections) with known values. The goal is a single script so users can choose:

- **Option A:** Run `./scripts/configure-apps.sh` (~30 seconds)
- **Option B:** Configure manually via web UIs (existing docs)

## What gets automated

| Service | Steps automated |
|---------|----------------|
| **qBittorrent** | Create `tv` + `movies` categories with `/data/torrents/{tv,movies}` save paths; set Torrent Management Mode to Automatic; tuning (disable UPnP, uTP rate limiting, LAN peer limiting, encryption mode) |
| **Sonarr** | Root folder `/data/media/tv`, qBit download client (category `tv`), SABnzbd client (if running, category `tv`), NFO metadata, TRaSH naming scheme, Reject ISO custom format + quality profile scoring, delay profile (if SABnzbd) |
| **Radarr** | Same as Sonarr but `/data/media/movies` + category `movies` |
| **Prowlarr** | FlareSolverr proxy, Sonarr app sync, Radarr app sync |
| **Bazarr** | Sonarr/Radarr connections (via `gluetun`), subtitle sync (ffsubsync) enabled with thresholds |

## What stays manual

1. **Jellyfin** — Initial wizard, libraries, hardware transcoding (device-specific)
2. **qBittorrent** — Change default password (security — user should choose)
3. **Prowlarr** — Add indexers (user-specific credentials)
4. **Seerr** — Initial Jellyfin login + service connections
5. **SABnzbd** — Usenet provider credentials + folder config (user-specific)
6. **Pi-hole** — Upstream DNS (simple, 1 step)

## New file: `scripts/configure-apps.sh`

Self-contained bash script (~500-600 lines) that runs **on the NAS**. Follows patterns from `backup-volumes.sh` (structure, error handling, summary) and `pause-resume.sh` (qBit API auth).

### Script flow

```
1. Parse arguments (--dry-run)
2. Validate prerequisites (docker available, key containers running)
3. Auto-discover API keys from container configs (docker exec → config.xml/config.yaml)
4. Get qBit temp password from docker logs (or $QBIT_PASSWORD env var for re-runs)
5. Detect NAS IP via hostname -I
6. Wait for each service to be healthy (60s timeout each)
7. Configure qBittorrent (categories, torrent management mode, tuning)
8. Configure Sonarr (root folder, download clients, metadata, naming, custom format)
9. Configure Radarr (same as Sonarr with movie-specific values)
10. Configure Prowlarr (FlareSolverr, Sonarr/Radarr apps)
11. Configure Bazarr (connections, subtitle sync)
12. Print summary: configured / skipped / failed + remaining manual steps
```

### API key discovery (no new .env vars needed)

| Service | Source |
|---------|--------|
| Sonarr/Radarr/Prowlarr | `docker exec <name> cat /config/config.xml` → `<ApiKey>` tag |
| Bazarr | `docker exec bazarr` → `/config/config/config.yaml` → `auth.apikey` |
| SABnzbd | `docker exec sabnzbd grep api_key /config/sabnzbd.ini` |
| qBittorrent | `docker logs qbittorrent` → temp password, or `$QBIT_PASSWORD` env var |

### Key API calls by service

**qBittorrent** (`NAS_IP:8085`, form-encoded):
- `POST /api/v2/auth/login` — authenticate
- `POST /api/v2/torrents/createCategory` — `tv` → `/data/torrents/tv`, `movies` → `/data/torrents/movies` (409 = already exists, OK)
- `POST /api/v2/app/setPreferences` — `{"torrent_content_layout":"Original","auto_tmm_enabled":true,"upnp":false,"utp_rate_limited":true,"limit_lan_peers":true,"encryption":1}`

**Sonarr** (`NAS_IP:8989`, `/api/v3`, `X-Api-Key` header):
- `GET /api/v3/rootfolder` → check for `/data/media/tv`, `POST` if missing
- `GET /api/v3/downloadclient` → check for qBittorrent, `POST` if missing (host: `localhost`, port: 8085, category: `tv`)
- Conditional: if SABnzbd running, add SABnzbd client (host: `localhost`, port: 8080, category: `tv`)
- `GET /api/v3/metadata` → find Kodi/XBMC entry, `PUT` to enable (seriesMetadata + episodeMetadata, images off)
- `PUT /api/v3/config/naming` — set TRaSH naming formats (standard/daily/anime episode, season folder, series folder)
- `GET /api/v3/customformat` → check for "Reject ISO", `POST` if missing (ReleaseTitleSpecification, `\.iso$`)
- `GET /api/v3/qualityprofile` → `PUT` to add Reject ISO at -10000 in each profile
- Conditional: if SABnzbd running, `POST /api/v3/delayprofile` (usenet: 0, torrent: 30 min)

**Radarr** (`NAS_IP:7878`, `/api/v3`):
- Same structure as Sonarr, but: root `/data/media/movies`, category `movies`, movieMetadata, TRaSH movie naming format

**Prowlarr** (`NAS_IP:9696`, `/api/v1`):
- `GET /api/v1/indexerProxy` → check for FlareSolverr, `POST` if missing (host: `http://localhost:8191`)
- `GET /api/v1/applications` → check for Sonarr, `POST` if missing (baseUrl: `http://localhost:8989`, fullSync)
- Same for Radarr (baseUrl: `http://localhost:7878`)

**Bazarr** (`NAS_IP:6767`, `/api/system/settings`, `X-API-KEY` header):
- `POST /api/system/settings` — Sonarr connection (ip: `gluetun`, port: 8989), Radarr connection (ip: `gluetun`, port: 7878), subsync enabled with thresholds
- `docker restart bazarr` after config change

### Key design decisions

- **Idempotent** — GETs current state before POSTing; skips if already configured
- **No jq dependency** — uses grep for JSON parsing (NAS may not have jq)
- **Non-fatal failures** — each service wrapped independently, continues on failure
- **`--dry-run` flag** — preview without making changes
- **SABnzbd-conditional** — delay profiles and usenet download clients only if SABnzbd container is running
- **Networking** — follows REFERENCE.md Service Connection Guide: `localhost` within Gluetun stack, `gluetun` hostname for Bazarr/Seerr

## Files modified

| File | Change |
|------|--------|
| `docs/APP-CONFIG.md` | Add "Option A: Automated / Option B: Manual" block at top of Step 4 |
| `docs/SETUP.md` | Update Step 4 to mention both options |
| `CHANGELOG.md` | Add entry under v1.7.0 |

## Verification

1. Run `./scripts/configure-apps.sh --dry-run` — verify output describes correct steps
2. Run `./scripts/configure-apps.sh` — verify all steps succeed
3. Run `./scripts/configure-apps.sh` again — verify all steps show "SKIP" (idempotent)
4. Run `npm run test:e2e` — E2E tests verify root folders, download clients, and media libraries via API
5. Spot-check web UIs: Sonarr has root folder + qBit client + naming, Prowlarr has Sonarr/Radarr apps, Bazarr shows connected
