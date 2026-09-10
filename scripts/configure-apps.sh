#!/bin/bash
#
# Automated app configuration for arr-stack
#
# Configures qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, and Pi-hole via their APIs.
# Replaces ~30 manual web UI steps with a single command.
#
# Usage:
#   ./scripts/configure-apps.sh [OPTIONS]
#
# Options:
#   --dry-run          Preview what would change without writing anything
#   --only <section>   Run one section: qbittorrent, sabnzbd, sonarr, radarr,
#                      prowlarr, bazarr or pihole. Everything else is untouched.
#   --verbose, -v      Print curl response bodies on failure (for debugging)
#
# Environment overrides:
#   BAZARR_CONTAINER   Bazarr container to configure (default: bazarr). Its host
#                      port is read from `docker port`, so pointing this at a
#                      throwaway instance is enough; BAZARR_PORT forces the port.
#                      Pair with `--only bazarr` or the rest of the live stack is
#                      configured too.
#   API_TIMEOUT        Seconds any one API request may take (default 60).
#   BAZARR_POST_TIMEOUT  Same, for Bazarr settings writes (default 60).
#   BAZARR_SCAN_TIMEOUT  For the Bazarr language-profile write, which rescans
#                      the whole library inside the request (default 600).
#
# Safe to re-run: The script is idempotent — it skips anything already
# configured and only applies missing settings. You can run it as many
# times as needed without side effects.
#
# Prerequisites:
#   - Docker available and containers running
#   - python3 available (for JSON parsing)
#   - Run on the NAS (not your dev machine)
#
# What stays manual after this script:
#   - Jellyfin: initial wizard, libraries, hardware transcoding
#   - qBittorrent: change default password
#   - Prowlarr: add indexers (user-specific credentials)
#   - Seerr: initial Jellyfin login + service connections
#   - SABnzbd: usenet provider credentials + folder config

# ============================================
# Source helpers
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/configure-helpers.sh"

# ============================================
# Globals
# ============================================

DRY_RUN=false
VERBOSE=false
NAS_IP=""
QBIT_COOKIE="/tmp/qbit_configure_cookie.txt"

# Counters
CONFIGURED=0
SKIPPED=0
FAILED=0
WOULD=0    # dry-run only: steps whose state check found them missing

# API keys (discovered at runtime)
SONARR_API_KEY=""
RADARR_API_KEY=""
PROWLARR_API_KEY=""
BAZARR_API_KEY=""
BAZARR_CONTAINER="${BAZARR_CONTAINER:-bazarr}"
BAZARR_PORT="${BAZARR_PORT:-}"   # derived from the container after the docker check unless set
ONLY=""
SABNZBD_API_KEY=""
QBIT_USERNAME="${QBIT_USERNAME:-}"
QBIT_PASSWORD="${QBIT_PASSWORD:-}"

# ============================================
# Parse arguments
# ============================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --only)
            ONLY="${2:-}"
            case "$ONLY" in
                qbittorrent|sabnzbd|sonarr|radarr|prowlarr|bazarr|pihole) ;;
                *) echo "Unknown section for --only: '${ONLY}'"; echo "Sections: qbittorrent sabnzbd sonarr radarr prowlarr bazarr pihole"; exit 1 ;;
            esac
            shift 2
            ;;
        --help|-h)
            # The header comment block, however long it grows: from line 3 to
            # the first line that is not a comment. Fixed head/tail offsets
            # silently dropped the tail of it every time a line was added.
            awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
            echo ""
            echo "This script is idempotent — safe to re-run at any time."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--only <section>] [--verbose|-v] [--help|-h]"
            exit 1
            ;;
    esac
done

# ============================================
# Prerequisites
# ============================================

echo "=== Arr-Stack App Configuration ==="
echo ""

if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found. Run this on the NAS."
    exit 1
fi

# Detect NAS IP
NAS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$NAS_IP" ]]; then
    echo "ERROR: Could not detect NAS IP"
    exit 1
fi
log "NAS IP: $NAS_IP"

if $DRY_RUN; then
    log "DRY RUN — no changes will be made"
fi
echo ""

# Check key containers are running
case "$ONLY" in
    "")            REQUIRED_CONTAINERS="gluetun qbittorrent sonarr radarr prowlarr ${BAZARR_CONTAINER}" ;;
    sonarr|radarr) REQUIRED_CONTAINERS="gluetun qbittorrent $ONLY" ;;   # they test their download client on save
    bazarr)        REQUIRED_CONTAINERS="${BAZARR_CONTAINER}" ;;
    pihole)        REQUIRED_CONTAINERS="pihole" ;;
    *)             REQUIRED_CONTAINERS="gluetun $ONLY" ;;
esac
MISSING=""
for c in $REQUIRED_CONTAINERS; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
        MISSING="$MISSING $c"
    fi
done
if [[ -n "$MISSING" ]]; then
    echo "ERROR: Required containers not running:$MISSING"
    echo "Start the stack first: docker compose -f docker-compose.arr-stack.yml up -d"
    exit 1
fi

# Bazarr's host port comes from the container, so BAZARR_CONTAINER alone is
# enough to target a throwaway. The two used to be independent knobs, and
# setting one without the other read a throwaway's API key while writing to
# the live port.
if [[ -z "$BAZARR_PORT" ]]; then
    BAZARR_PORT=$(docker port "$BAZARR_CONTAINER" 6767/tcp 2>/dev/null | head -1 | sed 's/.*://')
    if [[ -z "$BAZARR_PORT" ]]; then
        if [[ "$BAZARR_CONTAINER" == "bazarr" ]]; then
            BAZARR_PORT=6767
        else
            echo "ERROR: could not read the published port of container '${BAZARR_CONTAINER}' (docker port ... 6767/tcp). Set BAZARR_PORT."
            exit 1
        fi
    fi
fi

# Gluetun must be healthy — qBittorrent and the *arr services share its network
# namespace, so if the VPN isn't up, they won't respond on any port. Checking here
# turns a 4-minute mysterious hang into a clear error.
GLUETUN_HEALTH=$(docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null || echo unknown)
if [[ "$GLUETUN_HEALTH" != "healthy" ]]; then
    echo "ERROR: Gluetun is '$GLUETUN_HEALTH' (need 'healthy')."
    echo "       qBit and the *arr services share Gluetun's network — they can't respond until the VPN is up."
    echo "       Wait for it to connect, then re-run. Diagnose: docker logs gluetun --tail 50"
    exit 1
fi

# Check if SABnzbd is running (optional)
SABNZBD_RUNNING=false
if docker ps --format '{{.Names}}' | grep -q "^sabnzbd$"; then
    SABNZBD_RUNNING=true
fi

# ============================================
# Discover API keys
# ============================================

log "Discovering API keys..."

# Sonarr
SONARR_API_KEY=$(docker exec sonarr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+' || true)
if [[ -z "$SONARR_API_KEY" ]]; then
    fail "Could not discover Sonarr API key"
else
    info "Sonarr API key: ${SONARR_API_KEY:0:8}..."
fi

# Radarr
RADARR_API_KEY=$(docker exec radarr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+' || true)
if [[ -z "$RADARR_API_KEY" ]]; then
    fail "Could not discover Radarr API key"
else
    info "Radarr API key: ${RADARR_API_KEY:0:8}..."
fi

# Prowlarr
PROWLARR_API_KEY=$(docker exec prowlarr cat /config/config.xml 2>/dev/null | grep -oP '(?<=<ApiKey>)[^<]+' || true)
if [[ -z "$PROWLARR_API_KEY" ]]; then
    fail "Could not discover Prowlarr API key"
else
    info "Prowlarr API key: ${PROWLARR_API_KEY:0:8}..."
fi

# Bazarr — apikey is on same line as key: "  apikey: abc123"
BAZARR_API_KEY=$(docker exec "$BAZARR_CONTAINER" grep '^\s*apikey:' /config/config/config.yaml 2>/dev/null | head -1 | sed 's/.*apikey:\s*//' | tr -d ' ' || true)
if [[ -z "$BAZARR_API_KEY" ]]; then
    fail "Could not discover Bazarr API key"
else
    info "Bazarr API key: ${BAZARR_API_KEY:0:8}..."
fi

# SABnzbd (optional)
if $SABNZBD_RUNNING; then
    SABNZBD_API_KEY=$(docker exec sabnzbd grep '^api_key' /config/sabnzbd.ini 2>/dev/null | head -1 | sed 's/^api_key = //' | tr -d ' ' || true)
    if [[ -n "$SABNZBD_API_KEY" ]]; then
        info "SABnzbd API key: ${SABNZBD_API_KEY:0:8}..."
    fi
fi

# qBittorrent username: env var → .env file → "admin"
#
# .env stores this as QBIT_USER, which is why the username needs its own
# lookup rather than riding on the password's: before this, the script only
# ever read the QBIT_USERNAME env var and otherwise assumed "admin", so any
# deployment that renamed the qBittorrent account failed to authenticate
# even though the password resolved from .env perfectly well.
# QBIT_USERNAME is accepted from .env too, so either spelling works.
if [[ -z "$QBIT_USERNAME" && -f .env ]]; then
    QBIT_USERNAME=$(grep -E '^QBIT_(USER|USERNAME)=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)
fi
QBIT_USERNAME="${QBIT_USERNAME:-admin}"

# qBittorrent password: env var → .env file → docker logs temp password
if [[ -z "$QBIT_PASSWORD" && -f .env ]]; then
    QBIT_PASSWORD=$(grep '^QBIT_PASSWORD=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)
fi
if [[ -z "$QBIT_PASSWORD" ]]; then
    QBIT_PASSWORD=$(docker logs qbittorrent 2>&1 | grep -oP 'temporary password is provided.*: \K\S+' | tail -1 || true)
fi
if [[ -z "$QBIT_PASSWORD" ]]; then
    echo ""
    echo "WARNING: Could not find qBittorrent password."
    echo "         Set QBIT_PASSWORD env var if you've changed the default, e.g.:"
    echo "         QBIT_PASSWORD=mypassword ./scripts/configure-apps.sh"
    echo ""
fi

echo ""

# ============================================
# 1. qBittorrent
# ============================================

configure_qbittorrent() {
    log "Configuring qBittorrent..."

    local QBIT_URL="http://${NAS_IP}:8085"

    if ! wait_for_service "qBittorrent" "$QBIT_URL"; then return; fi

    if [[ -z "$QBIT_PASSWORD" ]]; then
        fail "qBittorrent: no password available, skipping"
        return
    fi

    # Authenticate using shared helper (see lib/configure-helpers.sh).
    # This runs in a dry run too: it is a session login, not a config write,
    # and without it none of the state reads below are possible.
    local http_code
    if ! qbit_auth "$QBIT_URL" "$QBIT_USERNAME" "$QBIT_PASSWORD" "$QBIT_COOKIE"; then
        fail "qBittorrent: authentication failed (check QBIT_USERNAME/QBIT_PASSWORD)"
        return
    fi

    # Create categories. The list is read first so a dry run can tell "exists"
    # from "would create" — inferring existence from a 409 on the write only
    # works if the write is sent. 409 is still handled for the race case.
    local existing_cats
    existing_cats=$(curl -s -b "$QBIT_COOKIE" "${QBIT_URL}/api/v2/torrents/categories" 2>/dev/null)
    for cat_name in tv movies other; do
        local save_path="/data/torrents/${cat_name}"
        if json_extract "$existing_cats" "sys.exit(0 if '${cat_name}' in data else 1)"; then
            skip "qBittorrent: category '${cat_name}'"
            continue
        fi
        if $DRY_RUN; then
            ok "qBittorrent: created category '${cat_name}' → ${save_path}"
            continue
        fi
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -b "$QBIT_COOKIE" \
            --data-urlencode "category=${cat_name}" \
            --data-urlencode "savePath=${save_path}" \
            "${QBIT_URL}/api/v2/torrents/createCategory")

        if [[ "$http_code" == "200" ]]; then
            ok "qBittorrent: created category '${cat_name}' → ${save_path}"
        elif [[ "$http_code" == "409" ]]; then
            skip "qBittorrent: category '${cat_name}'"
        else
            fail "qBittorrent: create category '${cat_name}' (HTTP $http_code)"
        fi
    done

    # Set preferences (skip if already correct)
    local current_prefs
    current_prefs=$(curl -s -b "$QBIT_COOKIE" "${QBIT_URL}/api/v2/app/preferences" 2>/dev/null)

    # Reject executables at the metadata stage, before any bytes transfer.
    # Public torrent indexers serve droppers that impersonate real release groups:
    # a ~1GB .exe padded to episode size, named e.g.
    # "Reacher S04E08 1080p WEB H264-CAKES.exe". Sonarr does catch these on import
    # ("Caution: Found executable file") but only AFTER the full download, and it
    # cannot see one nested inside a folder until the release is already on disk.
    # qBittorrent's exclusion list drops the matching files from the torrent
    # up front, so a poisoned release arrives as a 0-byte no-op instead.
    # See memory: indexer_poisoning_limetorrents (5 poisoned grabs, 2026-09-10).
    local excluded_names='*.exe\n*.scr\n*.bat\n*.cmd\n*.com\n*.msi\n*.lnk\n*.vbs\n*.ps1\n*.jar'

    if json_extract "$current_prefs" "
p = data
if not p.get('auto_tmm_enabled', False): sys.exit(1)
if p.get('upnp', True): sys.exit(1)
if not p.get('limit_utp_rate', False): sys.exit(1)
if not p.get('limit_lan_peers', False): sys.exit(1)
if p.get('encryption', 0) != 1: sys.exit(1)
if not p.get('max_inactive_seeding_time_enabled', False): sys.exit(1)
if p.get('max_inactive_seeding_time', -1) != 30: sys.exit(1)
if p.get('max_ratio_act', -1) != 0: sys.exit(1)
if p.get('max_active_downloads', -1) != 5: sys.exit(1)
if p.get('max_active_torrents', -1) != 10: sys.exit(1)
if p.get('max_active_uploads', -1) != 5: sys.exit(1)
if p.get('current_network_interface', '') != 'tun0': sys.exit(1)
if not p.get('excluded_file_names_enabled', False): sys.exit(1)
if p.get('excluded_file_names', '') != '${excluded_names}': sys.exit(1)
"; then
        skip "qBittorrent: preferences"
    else
        # current_network_interface=tun0 pins BitTorrent traffic to gluetun's
        # WireGuard tunnel. Without it libtorrent announces from every address in
        # the shared netns; gluetun's firewall drops the non-tunnel ones with
        # EPERM, so no announce escapes, no peers are found, and every torrent
        # stalls at metaDL while the WebUI and usenet both look healthy.
        # See docs/TROUBLESHOOTING.md -> "Torrents Stall Forever at 0% / metaDL".
        local prefs='{"auto_tmm_enabled":true,"upnp":false,"limit_utp_rate":true,"limit_lan_peers":true,"encryption":1,"max_inactive_seeding_time_enabled":true,"max_inactive_seeding_time":30,"max_ratio_act":0,"max_active_downloads":5,"max_active_torrents":10,"max_active_uploads":5,"current_network_interface":"tun0","current_interface_address":"","excluded_file_names_enabled":true,"excluded_file_names":"'"${excluded_names}"'"}'
        if $DRY_RUN; then
            http_code=200
        else
            http_code=$(curl -s -o /dev/null -w '%{http_code}' \
                -b "$QBIT_COOKIE" \
                --data-urlencode "json=${prefs}" \
                "${QBIT_URL}/api/v2/app/setPreferences")
        fi

        if [[ "$http_code" == "200" ]]; then
            ok "qBittorrent: set preferences (auto TMM, UPnP off, encryption, stall timeout, concurrent limits, VPN interface binding, executable exclusions)"
        else
            fail "qBittorrent: set preferences (HTTP $http_code)"
        fi
    fi

    rm -f "$QBIT_COOKIE"
}

# ============================================
# 1b. SABnzbd
# ============================================
configure_sabnzbd() {
    log "Configuring SABnzbd..."

    if [[ -z "$SABNZBD_API_KEY" ]]; then
        fail "SABnzbd: no API key, skipping"
        return
    fi

    local SAB_URL="http://${NAS_IP}:8082"

    # The `other` category is where anything grabbed from Prowlarr's own search
    # page lands — audiobooks, ISOs, music, whatever is neither TV nor a movie
    # and so has no Sonarr/Radarr path. With an empty folder field SABnzbd files
    # it under <complete_dir>/other, next to the tv/ and movies/ folders Sonarr
    # and Radarr already collect from. Nothing imports from it; it is a landing
    # spot, not a pipeline.
    local cats
    cats=$(curl -s -m 15 "${SAB_URL}/api?mode=get_config&section=categories&output=json&apikey=${SABNZBD_API_KEY}" 2>/dev/null) || true
    local has_other='sys.exit(0 if any(c.get("name") == "other" for c in data.get("config", {}).get("categories", [])) else 1)'
    if [[ -z "$cats" ]]; then
        fail "SABnzbd: could not read categories"
    elif json_extract "$cats" "$has_other"; then
        skip "SABnzbd: category 'other'"
    elif $DRY_RUN; then
        ok "SABnzbd: created category 'other' → /data/usenet/complete/other"
    else
        curl -s -m 15 -o /dev/null "${SAB_URL}/api?mode=set_config&section=categories&name=other&dir=&pp=&script=Default&priority=-100&output=json&apikey=${SABNZBD_API_KEY}" || true
        # Read back rather than trust the write: set_config answers 200 with the
        # config it holds, whether or not it accepted the change.
        cats=$(curl -s -m 15 "${SAB_URL}/api?mode=get_config&section=categories&output=json&apikey=${SABNZBD_API_KEY}" 2>/dev/null) || true
        if json_extract "$cats" "$has_other"; then
            ok "SABnzbd: created category 'other' → /data/usenet/complete/other"
        else
            fail "SABnzbd: create category 'other' (not present after write)"
        fi
    fi
}

# ============================================
# 2. Sonarr & Radarr (via shared configure_arr_service)
# ============================================

# Sonarr metadata fields
SONARR_METADATA_FIELDS='[{"name":"seriesMetadata","value":true},{"name":"seriesMetadataEpisodeGuide","value":true},{"name":"seriesMetadataUrl","value":false},{"name":"episodeMetadata","value":true},{"name":"seriesImages","value":false},{"name":"seasonImages","value":false},{"name":"episodeImages","value":false}]'

# Sonarr naming payload (TRaSH guide)
SONARR_NAMING_PAYLOAD=$(cat <<'EOF'
{"renameEpisodes":true,"replaceIllegalCharacters":true,"multiEpisodeStyle":5,"standardEpisodeFormat":"{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}","dailyEpisodeFormat":"{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}","animeEpisodeFormat":"{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels}{MediaInfo AudioLanguages}]{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec][ Mediainfo VideoBitDepth]bit}{-Release Group}","seasonFolderFormat":"Season {season:00}","seriesFolderFormat":"{Series TitleYear} [tvdbid-{TvdbId}]"}
EOF
)

# Radarr metadata fields
RADARR_METADATA_FIELDS='[{"name":"movieMetadata","value":true},{"name":"movieMetadataURL","value":false},{"name":"movieMetadataLanguage","value":1},{"name":"movieImages","value":false},{"name":"useMovieNfo","value":true}]'

# Radarr naming payload (TRaSH guide)
RADARR_NAMING_PAYLOAD=$(cat <<'EOF'
{"renameMovies":true,"replaceIllegalCharacters":true,"standardMovieFormat":"{Movie CleanTitle} {(Release Year)} {imdb-{ImdbId}} - {Edition Tags }{[Custom Formats]}{[Quality Full]}{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}","movieFolderFormat":"{Movie CleanTitle} ({Release Year})"}
EOF
)

# ============================================
# 3. Prowlarr
# ============================================

configure_prowlarr() {
    log "Configuring Prowlarr..."

    if [[ -z "$PROWLARR_API_KEY" ]]; then
        fail "Prowlarr: no API key, skipping"
        return
    fi

    local BASE="http://${NAS_IP}:9696"
    local AUTH="X-Api-Key: ${PROWLARR_API_KEY}"

    if ! wait_for_service "Prowlarr" "${BASE}/api/v1/health"; then return; fi

    # FlareSolverr proxy
    local proxies
    proxies=$(api_get "${BASE}/api/v1/indexerProxy" "$AUTH") || true
    if json_extract "$proxies" "sys.exit(0 if any(p.get('name','').lower() == 'flaresolverr' for p in data) else 1)"; then
        skip "Prowlarr: FlareSolverr proxy"
    else
        local fs_payload='{"name":"FlareSolverr","implementation":"FlareSolverr","configContract":"FlareSolverrSettings","fields":[{"name":"host","value":"http://localhost:8191"},{"name":"requestTimeout","value":60}],"tags":[]}'
        if api_post "${BASE}/api/v1/indexerProxy" "application/json" "$fs_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Prowlarr: added FlareSolverr proxy"
        else
            fail "Prowlarr: add FlareSolverr proxy"
        fi
    fi

    # Applications: Sonarr and Radarr. Both live on the bridge with static IPs
    # (docker-compose.arr-stack.yml), and Prowlarr is inside gluetun's namespace
    # where DNS is Pi-hole and cannot resolve container names — so the app URL
    # is the IP, and the URL Sonarr/Radarr use to call back is gluetun's name.
    # `localhost` on either side reaches nothing (docs/MIGRATION-arr-off-vpn.md).
    local apps
    apps=$(api_get "${BASE}/api/v1/applications" "$AUTH") || true

    local arr_name arr_port arr_ip arr_categories
    for arr_name in Sonarr Radarr; do
        local key_var="${arr_name^^}_API_KEY"
        local arr_key="${!key_var}"
        if [[ "$arr_name" == "Sonarr" ]]; then
            arr_port=8989; arr_ip=172.20.0.10; arr_categories="[5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080]"
        else
            arr_port=7878; arr_ip=172.20.0.11; arr_categories="[2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080]"
        fi

        local name_lower="${arr_name,,}"
        if json_extract "$apps" "sys.exit(0 if any(a.get('name','').lower() == '${name_lower}' for a in data) else 1)"; then
            skip "Prowlarr: ${arr_name} application"
        elif [[ -z "$arr_key" ]]; then
            fail "Prowlarr: add ${arr_name} (no ${arr_name} API key)"
        else
            local app_payload="{\"name\":\"${arr_name}\",\"syncLevel\":\"fullSync\",\"implementation\":\"${arr_name}\",\"configContract\":\"${arr_name}Settings\",\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://gluetun:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://${arr_ip}:${arr_port}\"},{\"name\":\"apiKey\",\"value\":\"${arr_key}\"},{\"name\":\"syncCategories\",\"value\":${arr_categories}}],\"tags\":[]}"
            if api_post "${BASE}/api/v1/applications" "application/json" "$app_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Prowlarr: added ${arr_name} application"
            else
                fail "Prowlarr: add ${arr_name} application"
            fi
        fi
    done

    # Download clients for Prowlarr's OWN search page. Sonarr and Radarr grab
    # through their own clients; this pair serves only the manual search here,
    # and lands everything in the `other` category — the one lane the stack has
    # for something that is neither TV nor a movie. Without it the search page's
    # download button silently does nothing: no grab event, no error, nothing in
    # History (found the hard way, 2026-09-10). Prowlarr shares gluetun's
    # namespace, so both clients are `localhost` — unlike Sonarr/Radarr, which
    # sit on the bridge and must go via `gluetun:PORT`.
    local dl_clients
    dl_clients=$(api_get "${BASE}/api/v1/downloadclient" "$AUTH") || true

    if json_extract "$dl_clients" "sys.exit(0 if any(c.get('name','').lower() == 'qbittorrent' for c in data) else 1)"; then
        skip "Prowlarr: qBittorrent download client"
    else
        local pq_payload
        pq_payload=$(cat <<PQ_JSON
{
    "enable": true,
    "protocol": "torrent",
    "priority": 1,
    "name": "qBittorrent",
    "implementation": "QBittorrent",
    "configContract": "QBittorrentSettings",
    "categories": [],
    "tags": [],
    "fields": [
        {"name": "host", "value": "localhost"},
        {"name": "port", "value": 8085},
        {"name": "username", "value": "${QBIT_USERNAME}"},
        {"name": "password", "value": "${QBIT_PASSWORD}"},
        {"name": "category", "value": "other"},
        {"name": "priority", "value": 0},
        {"name": "initialState", "value": 0},
        {"name": "sequentialOrder", "value": false},
        {"name": "firstAndLast", "value": false},
        {"name": "contentLayout", "value": 0}
    ]
}
PQ_JSON
)
        if api_post "${BASE}/api/v1/downloadclient" "application/json" "$pq_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Prowlarr: added qBittorrent download client (search-page grabs → category 'other')"
        else
            fail "Prowlarr: add qBittorrent download client"
        fi
    fi

    if $SABNZBD_RUNNING && [[ -n "$SABNZBD_API_KEY" ]]; then
        if json_extract "$dl_clients" "sys.exit(0 if any(c.get('name','').lower() == 'sabnzbd' for c in data) else 1)"; then
            skip "Prowlarr: SABnzbd download client"
        else
            local ps_payload
            ps_payload=$(cat <<PS_JSON
{
    "enable": true,
    "protocol": "usenet",
    "priority": 1,
    "name": "SABnzbd",
    "implementation": "Sabnzbd",
    "configContract": "SabnzbdSettings",
    "categories": [],
    "tags": [],
    "fields": [
        {"name": "host", "value": "localhost"},
        {"name": "port", "value": 8080},
        {"name": "apiKey", "value": "${SABNZBD_API_KEY}"},
        {"name": "category", "value": "other"},
        {"name": "priority", "value": -100}
    ]
}
PS_JSON
)
            if api_post "${BASE}/api/v1/downloadclient" "application/json" "$ps_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Prowlarr: added SABnzbd download client (search-page grabs → category 'other')"
            else
                fail "Prowlarr: add SABnzbd download client"
            fi
        fi
    fi
}

# ============================================
# 4. Bazarr
# ============================================

configure_bazarr() {
    log "Configuring Bazarr..."

    if [[ -z "$BAZARR_API_KEY" ]]; then
        fail "Bazarr: no API key, skipping"
        return
    fi

    local BASE="http://${NAS_IP}:${BAZARR_PORT}"
    local AUTH="X-API-KEY: ${BAZARR_API_KEY}"

    if ! wait_for_service "Bazarr" "${BASE}/api/system/status"; then return; fi

    # Get current settings. Nothing below changes a key another step compares,
    # so one read serves the whole section (the language step reads its own
    # two endpoints).
    local settings
    settings=$(api_get "${BASE}/api/system/settings" "$AUTH") || true

    if [[ -z "$settings" ]]; then
        fail "Bazarr: could not fetch current settings"
        return
    fi

    # Bazarr applies every setting inside the POST (in memory, then
    # config.yaml) and never restarts its process for them — read from the
    # v1.6.0 source. There is no container bounce at the end of this section.

    # --- Subtitle language profile: find, adopt or create; then reconcile ---
    #
    # This runs FIRST, before Sonarr and Radarr are connected, because Bazarr
    # stamps the default profile onto each series and movie when the row is
    # inserted — and connecting Sonarr/Radarr starts the initial library sync
    # immediately. Set the profile afterwards and the whole existing library
    # has none, and only titles added later get it.
    #
    # The decision lives in lib/bazarr-language-plan.py (unit-tested in
    # tests/bazarr-language-plan.bats): the profile named
    # SUBTITLE_PROFILE_NAME is managed, else a profile whose languages are
    # exactly SUBTITLE_LANGUAGES is adopted, else one is created with the next
    # free id — never a hard-coded 1. Other profiles are never modified.
    # Languages Filter ticks become the wanted languages plus whatever other
    # profiles use, so a stray tick (Latvian, 2026-09-10) is cleared without
    # unticking a language another profile depends on.
    #
    # Bazarr rescans the whole library inside a languages-profiles write, so
    # this one call gets BAZARR_SCAN_TIMEOUT rather than the usual bound. On a
    # fresh install it runs before use_sonarr/use_radarr are set, so there is
    # nothing to scan yet.
    local SUBTITLE_LANGUAGES="en"          # space-separated code2 list — the managed profile's contents
    local SUBTITLE_PROFILE_NAME="English"  # name when creating; an existing profile with this name is managed

    local lang_profiles enabled_langs plan
    lang_profiles=$(api_get "${BASE}/api/system/languages/profiles" "$AUTH") || true
    enabled_langs=$(api_get "${BASE}/api/system/languages" "$AUTH") || true
    plan=$(python3 "${SCRIPT_DIR}/lib/bazarr-language-plan.py" "$lang_profiles" "$enabled_langs" "$SUBTITLE_LANGUAGES" "$SUBTITLE_PROFILE_NAME" 2>/dev/null)

    local lang_action="" profile_id="" profile_name="" lang_added lang_removed tick_added tick_removed lang_enabled plan_profiles
    IFS='|' read -r lang_action profile_id profile_name lang_added lang_removed tick_added tick_removed lang_enabled <<< "$(printf '%s\n' "$plan" | head -1)"
    plan_profiles=$(printf '%s\n' "$plan" | sed -n '2p')

    if [[ -z "$lang_action" ]]; then
        fail "Bazarr: could not read the language profiles or the enabled-language list"
    elif [[ "$lang_action" == "MATCH" ]]; then
        skip "Bazarr: subtitle profile '${profile_name}' (id ${profile_id}) = ${SUBTITLE_LANGUAGES}"
    else
        local enabled_args=() code change=""
        for code in $lang_enabled; do enabled_args+=("languages-enabled=${code}"); done
        [[ -n "$lang_added" ]]   && change+=" languages +${lang_added// /,+}"
        [[ -n "$lang_removed" ]] && change+=" languages -${lang_removed// /,-}"
        [[ -n "$tick_added" ]]   && change+=" ticks +${tick_added// /,+}"
        [[ -n "$tick_removed" ]] && change+=" ticks -${tick_removed// /,-}"
        if API_MAX_TIME="$BAZARR_SCAN_TIMEOUT" bazarr_settings_post "$BASE" "$AUTH" "${enabled_args[@]}" "languages-profiles=${plan_profiles}"; then
            if [[ "$lang_action" == "CREATE" ]]; then
                ok "Bazarr: created subtitle profile '${profile_name}' (id ${profile_id}) = ${SUBTITLE_LANGUAGES}"
            else
                ok "Bazarr: reconciled subtitle profile '${profile_name}' (id ${profile_id}):${change}"
            fi
        else
            fail "Bazarr: ${lang_action,,} subtitle profile '${profile_name}'"
        fi
    fi

    # --- Default subtitle profile for new series and movies ---
    #
    # Points at the profile the step above found or created — by its real id.
    # It was hard-coded to 1, which reported ✓ while aiming the defaults at a
    # profile that did not exist. Bazarr only type-checks the value.
    if [[ -z "$profile_id" ]]; then
        fail "Bazarr: default subtitle profile — no profile to point at (see above)"
    else
        local lang_state
        lang_state=$(json_extract "$settings" "
want = {
    'serie_default_enabled': True,
    'serie_default_profile': ${profile_id},
    'movie_default_enabled': True,
    'movie_default_profile': ${profile_id},
}
current = data.get('general', {})
def norm(k, v):
    return int(v) if k.endswith('_profile') and str(v).isdigit() else v
diff = [k for k, v in sorted(want.items()) if norm(k, current.get(k)) != v]
print(' '.join(diff) if diff else 'MATCH')")

        if [[ -z "$lang_state" ]]; then
            fail "Bazarr: could not compare default subtitle profile settings"
        elif [[ "$lang_state" == "MATCH" ]]; then
            skip "Bazarr: default subtitle profile (id ${profile_id})"
        else
            if bazarr_settings_post "$BASE" "$AUTH" \
                "settings-general-serie_default_enabled=true" \
                "settings-general-serie_default_profile=${profile_id}" \
                "settings-general-movie_default_enabled=true" \
                "settings-general-movie_default_profile=${profile_id}"; then
                ok "Bazarr: set default subtitle profile to '${profile_name}' (id ${profile_id}) (${lang_state})"
            else
                fail "Bazarr: set default subtitle profile"
            fi
        fi
    fi

    # --- Sonarr/Radarr connections ---
    #
    # Bazarr reaches Sonarr and Radarr by container name over the arr-stack
    # bridge. Both moved out of Gluetun's network namespace on 2026-06-27 and
    # have their own bridge IPs since; "gluetun:8989" has not reached Sonarr
    # from Bazarr since that change (verified on the NAS 2026-08-17: gluetun:8989
    # and gluetun:7878 both fail to connect, sonarr:8989 and radarr:7878 both
    # answer HTTP 401). Change these only alongside the compose networking.
    #
    # If Bazarr cannot reach them, its handler blocks inside this POST with no
    # attempt limit; bazarr_settings_post bounds that and explains it.
    local sonarr_host="sonarr" sonarr_port=8989
    local radarr_host="radarr" radarr_port=7878

    # Compare every field this step would write, so a run that would change
    # nothing skips instead of POSTing. Prints MATCH when the live config
    # already matches, otherwise the differing fields. Empty output means the
    # comparison itself broke (bad JSON, python error) — that is reported as a
    # failure, never as a silent skip.
    local conn_state
    conn_state=$(json_extract "$settings" "
want = {
    'sonarr': {'ip': '''${sonarr_host}''', 'port': ${sonarr_port}, 'base_url': '', 'ssl': False, 'apikey': '''${SONARR_API_KEY}'''},
    'radarr': {'ip': '''${radarr_host}''', 'port': ${radarr_port}, 'base_url': '', 'ssl': False, 'apikey': '''${RADARR_API_KEY}'''},
}
general = data.get('general', {})
diff = []
for section, fields in sorted(want.items()):
    current = data.get(section, {})
    if not general.get('use_' + section):
        diff.append('general.use_' + section)
    for field, expected in sorted(fields.items()):
        if field == 'apikey' and not expected:
            continue  # key not discovered this run — nothing to compare against
        actual = current.get(field)
        if field == 'port':
            actual = int(actual) if str(actual).isdigit() else actual
        if actual != expected:
            diff.append(section + '.' + field)
print(' '.join(diff) if diff else 'MATCH')")

    if [[ -z "$conn_state" ]]; then
        fail "Bazarr: could not compare Sonarr/Radarr connection settings"
    elif [[ "$conn_state" == "MATCH" ]]; then
        skip "Bazarr: Sonarr/Radarr connections"
    else
        # Flat form keys — a nested JSON body is accepted and discarded.
        # See bazarr_settings_post in lib/configure-helpers.sh.
        #
        # Booleans must be lowercase "true"/"false": Bazarr's validator type-checks
        # the raw form value, so "True" is rejected with HTTP 406 ("must is_type_of
        # <class 'bool'>") and takes the whole POST down with it. Verified on the
        # NAS 2026-08-17 — "on", "1" and "0" are rejected the same way.
        local conn_keys=(
            "settings-general-use_sonarr=true"
            "settings-sonarr-ip=${sonarr_host}"
            "settings-sonarr-port=${sonarr_port}"
            "settings-sonarr-base_url="
            "settings-sonarr-ssl=false"
            "settings-general-use_radarr=true"
            "settings-radarr-ip=${radarr_host}"
            "settings-radarr-port=${radarr_port}"
            "settings-radarr-base_url="
            "settings-radarr-ssl=false"
        )
        [[ -n "$SONARR_API_KEY" ]] && conn_keys+=("settings-sonarr-apikey=${SONARR_API_KEY}")
        [[ -n "$RADARR_API_KEY" ]] && conn_keys+=("settings-radarr-apikey=${RADARR_API_KEY}")

        if bazarr_settings_post "$BASE" "$AUTH" "${conn_keys[@]}"; then
            ok "Bazarr: configured Sonarr/Radarr connections (${conn_state})"
        else
            fail "Bazarr: configure Sonarr/Radarr connections"
        fi
    fi

    # --- Subtitle sync (ffsubsync) ---
    #
    # Compares every field it writes, not just use_subsync: with only the enable
    # flag checked, a threshold edited by hand read as "already configured".
    local subsync_state
    subsync_state=$(json_extract "$settings" "
want = {
    'use_subsync': True,
    'use_subsync_threshold': True,
    'subsync_threshold': 90,
    'use_subsync_movie_threshold': True,
    'subsync_movie_threshold': 70,
}
current = data.get('subsync', {})
diff = [k for k, v in sorted(want.items()) if current.get(k) != v]
print(' '.join(diff) if diff else 'MATCH')")

    if [[ -z "$subsync_state" ]]; then
        fail "Bazarr: could not compare subtitle sync settings"
    elif [[ "$subsync_state" == "MATCH" ]]; then
        skip "Bazarr: subtitle sync"
    else
        if bazarr_settings_post "$BASE" "$AUTH" \
            "settings-subsync-use_subsync=true" \
            "settings-subsync-use_subsync_threshold=true" \
            "settings-subsync-subsync_threshold=90" \
            "settings-subsync-use_subsync_movie_threshold=true" \
            "settings-subsync-subsync_movie_threshold=70"; then
            ok "Bazarr: enabled subtitle sync, thresholds series 90 / movies 70 (${subsync_state})"
        else
            fail "Bazarr: enable subtitle sync"
        fi
    fi

    # --- Sub-Zero content modifications ---
    #
    # These do not go through "settings-general-subzero_mods" at all. That key
    # is unwritable: Bazarr stores subzero_mods as a comma-separated string
    # (Validator(..., is_type_of=str)) but also lists it in array_keys, so the
    # form parser hands the validator a list and every value is rejected 406,
    # "must is_type_of <class 'str'>". Repeated keys and a comma-separated
    # string both fail the same way — verified on the NAS 2026-08-17.
    #
    # Mods are toggled one at a time through a separate "subzero-<mod>" key
    # space instead (app/config.py, settings_keys[0] == 'subzero'), which adds
    # on a truthy value and removes on a falsy one. save_settings normalises
    # first — numeric strings to int, then literal "true"/"false" to bool — so
    # "true"/1 add, and "false"/0/empty remove. Any other non-empty string is
    # truthy and would add regardless of what it appears to mean.
    #
    # Only the missing mods are sent, because Bazarr appends with no membership
    # check: re-sending an already-enabled mod stores it twice (confirmed —
    # a second subzero-emoji=true produced [... 'emoji', 'emoji']).
    #
    # Mods beyond this set are left alone rather than stripped. Removing one a
    # user enabled by hand would put the live config permanently at odds with
    # the script, which is exactly the write-every-run loop this is meant to end.
    local subzero_missing
    subzero_missing=$(json_extract "$settings" "
want = ['remove_tags', 'emoji', 'OCR_fixes', 'common', 'fix_uppercase']
current = data.get('general', {}).get('subzero_mods', [])
missing = [m for m in want if m not in current]
print(' '.join(missing) if missing else 'MATCH')")

    if [[ -z "$subzero_missing" ]]; then
        fail "Bazarr: could not compare Sub-Zero content modifications"
    elif [[ "$subzero_missing" == "MATCH" ]]; then
        skip "Bazarr: Sub-Zero content modifications"
    else
        local subzero_keys=() mod
        for mod in $subzero_missing; do
            subzero_keys+=("subzero-${mod}=true")
        done
        if bazarr_settings_post "$BASE" "$AUTH" "${subzero_keys[@]}"; then
            ok "Bazarr: enabled Sub-Zero mods (${subzero_missing})"
        else
            fail "Bazarr: enable Sub-Zero mods"
        fi
    fi
}

# ============================================
# 5. Pi-hole
# ============================================

configure_pihole() {
    log "Configuring Pi-hole..."

    # Check current upstream DNS configuration
    local current_dns
    current_dns=$(docker exec pihole pihole-FTL --config dns.upstreams 2>/dev/null || true)

    if [[ "$current_dns" == *"172.20.0.6#5053"* ]]; then
        skip "Pi-hole: upstream DNS (already using dnscrypt-proxy)"
    else
        # Set dnscrypt-proxy as upstream DNS using FTL config
        if $DRY_RUN; then
            ok "Pi-hole: set upstream DNS to dnscrypt-proxy (172.20.0.6#5053)"
        elif docker exec pihole pihole-FTL --config dns.upstreams '["172.20.0.6#5053"]' >/dev/null 2>&1; then
            ok "Pi-hole: set upstream DNS to dnscrypt-proxy (172.20.0.6#5053)"
            # Restart container to apply — pihole restartdns fails with cap_drop: ALL
            docker restart pihole >/dev/null 2>&1
        else
            fail "Pi-hole: set upstream DNS"
        fi
    fi
}

# ============================================
# Run all
# ============================================

# --only <section> runs one of these and nothing else.
want_section() { [[ -z "$ONLY" || "$ONLY" == "$1" ]]; }

if want_section qbittorrent; then configure_qbittorrent; echo ""; fi
if want_section sabnzbd && $SABNZBD_RUNNING; then configure_sabnzbd; echo ""; fi
if want_section sonarr; then
    configure_arr_service "Sonarr" 8989 "$SONARR_API_KEY" "/data/media/tv" "tv" \
        "renameEpisodes" "$SONARR_METADATA_FIELDS" "$SONARR_NAMING_PAYLOAD"
    echo ""
fi
if want_section radarr; then
    configure_arr_service "Radarr" 7878 "$RADARR_API_KEY" "/data/media/movies" "movies" \
        "renameMovies" "$RADARR_METADATA_FIELDS" "$RADARR_NAMING_PAYLOAD"
    echo ""
fi
if want_section prowlarr; then configure_prowlarr; echo ""; fi
if want_section bazarr; then configure_bazarr; echo ""; fi
if want_section pihole; then configure_pihole; fi

# ============================================
# Summary
# ============================================

echo ""
echo "=========================================="
if $DRY_RUN; then
    echo "Summary (dry-run): ${WOULD} would change, ${SKIPPED} already configured, ${FAILED} could not be checked"
else
    echo "Summary: ${CONFIGURED} configured, ${SKIPPED} skipped, ${FAILED} failed"
fi
echo "=========================================="

if [[ $FAILED -gt 0 ]]; then
    echo ""
    echo "Some steps failed. Re-run to retry, or configure manually via web UI."
fi

echo ""
echo "Remaining manual steps:"
echo "  1. Jellyfin: initial wizard, libraries, hardware transcoding"
echo "  2. qBittorrent: change default password (Tools → Options → Web UI)"
echo "  3. Prowlarr: add indexers (torrent/Usenet)"
echo "  4. Seerr: initial setup + Jellyfin login"
if $SABNZBD_RUNNING; then
    echo "  5. SABnzbd: usenet provider credentials"
fi

# Cleanup
rm -f "$QBIT_COOKIE"
