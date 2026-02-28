#!/bin/bash
#
# Automated app configuration for arr-stack
#
# Configures qBittorrent, Sonarr, Radarr, Prowlarr, and Bazarr via their APIs.
# Replaces ~30 manual web UI steps with a single command.
#
# Usage:
#   ./scripts/configure-apps.sh [OPTIONS]
#
# Options:
#   --dry-run    Preview what would be configured without making changes
#
# Prerequisites:
#   - Docker available and containers running
#   - Run on the NAS (not your dev machine)
#
# What stays manual after this script:
#   - Jellyfin: initial wizard, libraries, hardware transcoding
#   - qBittorrent: change default password
#   - Prowlarr: add indexers (user-specific credentials)
#   - Seerr: initial Jellyfin login + service connections
#   - SABnzbd: usenet provider credentials + folder config
#   - Pi-hole: upstream DNS

# ============================================
# Globals
# ============================================

DRY_RUN=false
NAS_IP=""
QBIT_COOKIE="/tmp/qbit_configure_cookie.txt"

# Counters
CONFIGURED=0
SKIPPED=0
FAILED=0

# API keys (discovered at runtime)
SONARR_API_KEY=""
RADARR_API_KEY=""
PROWLARR_API_KEY=""
BAZARR_API_KEY=""
SABNZBD_API_KEY=""
QBIT_USERNAME="${QBIT_USERNAME:-admin}"
QBIT_PASSWORD="${QBIT_PASSWORD:-}"

# ============================================
# Helpers
# ============================================

log()   { echo "[configure] $1"; }
ok()    { echo "  ✓ $1"; CONFIGURED=$((CONFIGURED + 1)); }
skip()  { echo "  - $1 (already configured)"; SKIPPED=$((SKIPPED + 1)); }
fail()  { echo "  ✗ $1"; FAILED=$((FAILED + 1)); }
info()  { echo "  $1"; }
dry()   { echo "  [dry-run] Would: $1"; }

# Simple JSON value extractor — no jq dependency
# Usage: json_value "key" <<< "$json"
# Handles: "key": "value", "key": 123, "key": true/false/null
# For arrays/objects, use grep directly
json_value() {
    local key="$1"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/\"${key}\"[[:space:]]*:[[:space:]]*\"//" | sed 's/"$//'
}

# Extract numeric/boolean JSON value (unquoted)
json_value_raw() {
    local key="$1"
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*[0-9a-z]*" | head -1 | sed "s/\"${key}\"[[:space:]]*:[[:space:]]*//"
}

# HTTP helpers — return body to stdout, check status via file
# Usage: body=$(api_get "url" "header1" "header2" ...)
api_get() {
    local url="$1"; shift
    local args=(-s -w '\n%{http_code}' -o -)
    for h in "$@"; do args+=(-H "$h"); done
    local response
    response=$(curl "${args[@]}" "$url")
    local code
    code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')
    if [[ "$code" =~ ^2 ]]; then
        echo "$body"
        return 0
    else
        return 1
    fi
}

api_post() {
    local url="$1"; shift
    local content_type="$1"; shift
    local data="$1"; shift
    local args=(-s -w '\n%{http_code}' -o - -X POST -H "Content-Type: $content_type")
    for h in "$@"; do args+=(-H "$h"); done
    if [[ -n "$data" ]]; then args+=(--data "$data"); fi
    local response
    response=$(curl "${args[@]}" "$url")
    local code
    code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')
    if [[ "$code" =~ ^2 ]]; then
        echo "$body"
        return 0
    else
        echo "$body"
        return "$code"
    fi
}

api_put() {
    local url="$1"; shift
    local content_type="$1"; shift
    local data="$1"; shift
    local args=(-s -w '\n%{http_code}' -o - -X PUT -H "Content-Type: $content_type")
    for h in "$@"; do args+=(-H "$h"); done
    if [[ -n "$data" ]]; then args+=(--data "$data"); fi
    local response
    response=$(curl "${args[@]}" "$url")
    local code
    code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')
    if [[ "$code" =~ ^2 ]]; then
        echo "$body"
        return 0
    else
        echo "$body"
        return "$code"
    fi
}

# Wait for a service to respond (60s timeout)
# Accepts 2xx, 3xx, and 401 (auth required = service is up)
wait_for_service() {
    local name="$1" url="$2"
    local i=0
    while [[ $i -lt 60 ]]; do
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
        if [[ "$code" =~ ^[23] ]] || [[ "$code" == "401" ]]; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    fail "$name not responding after 60s at $url"
    return 1
}

# ============================================
# Parse arguments
# ============================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run]"
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
REQUIRED_CONTAINERS="gluetun qbittorrent sonarr radarr prowlarr bazarr"
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
BAZARR_API_KEY=$(docker exec bazarr grep '^\s*apikey:' /config/config/config.yaml 2>/dev/null | head -1 | sed 's/.*apikey:\s*//' | tr -d ' ' || true)
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

# qBittorrent password (env var preserved from globals, try docker logs as fallback)
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

    if $DRY_RUN; then
        dry "Authenticate to qBittorrent"
        dry "Create category 'tv' → /data/torrents/tv"
        dry "Create category 'movies' → /data/torrents/movies"
        dry "Set preferences: auto TMM, disable UPnP, encryption"
        return
    fi

    # Authenticate
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -c "$QBIT_COOKIE" \
        --data-urlencode "username=${QBIT_USERNAME}" \
        --data-urlencode "password=${QBIT_PASSWORD}" \
        "${QBIT_URL}/api/v2/auth/login")

    if [[ "$http_code" != "200" ]]; then
        fail "qBittorrent: authentication failed (HTTP $http_code)"
        return
    fi

    # Create categories (409 = already exists, that's fine)
    for cat_name in tv movies; do
        local save_path="/data/torrents/${cat_name}"
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

    # Set preferences
    local prefs='{"auto_tmm_enabled":true,"upnp":false,"utp_rate_limited":true,"limit_lan_peers":true,"encryption":1}'
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -b "$QBIT_COOKIE" \
        --data-urlencode "json=${prefs}" \
        "${QBIT_URL}/api/v2/app/setPreferences")

    if [[ "$http_code" == "200" ]]; then
        ok "qBittorrent: set preferences (auto TMM, UPnP off, encryption)"
    else
        fail "qBittorrent: set preferences (HTTP $http_code)"
    fi

    rm -f "$QBIT_COOKIE"
}

# ============================================
# 2. Sonarr
# ============================================

configure_sonarr() {
    log "Configuring Sonarr..."

    if [[ -z "$SONARR_API_KEY" ]]; then
        fail "Sonarr: no API key, skipping"
        return
    fi

    local BASE="http://${NAS_IP}:8989"
    local AUTH="X-Api-Key: ${SONARR_API_KEY}"

    if ! wait_for_service "Sonarr" "${BASE}/api/v3/health" ; then return; fi

    if $DRY_RUN; then
        dry "Add root folder /data/media/tv"
        dry "Add qBittorrent download client (category: tv)"
        if $SABNZBD_RUNNING; then dry "Add SABnzbd download client (category: tv)"; fi
        dry "Enable NFO metadata (Kodi/Emby)"
        dry "Set TRaSH naming scheme"
        dry "Add Reject ISO custom format"
        dry "Score Reject ISO at -10000 in quality profiles"
        if $SABNZBD_RUNNING; then dry "Add delay profile (Usenet 0, Torrent 30)"; fi
        return
    fi

    # Root folder
    local roots
    roots=$(api_get "${BASE}/api/v3/rootfolder" "$AUTH") || true
    if echo "$roots" | grep -q '"/data/media/tv"'; then
        skip "Sonarr: root folder /data/media/tv"
    else
        if api_post "${BASE}/api/v3/rootfolder" "application/json" '{"path":"/data/media/tv"}' "$AUTH" >/dev/null 2>&1; then
            ok "Sonarr: added root folder /data/media/tv"
        else
            fail "Sonarr: add root folder /data/media/tv"
        fi
    fi

    # Download client: qBittorrent
    local clients
    clients=$(api_get "${BASE}/api/v3/downloadclient" "$AUTH") || true
    if echo "$clients" | grep -qi 'qbittorrent'; then
        skip "Sonarr: qBittorrent download client"
    else
        local qbit_payload
        qbit_payload=$(cat <<QBIT_JSON
{
    "enable": true,
    "protocol": "torrent",
    "priority": 1,
    "name": "qBittorrent",
    "implementation": "QBittorrent",
    "configContract": "QBittorrentSettings",
    "fields": [
        {"name": "host", "value": "localhost"},
        {"name": "port", "value": 8085},
        {"name": "username", "value": "${QBIT_USERNAME}"},
        {"name": "password", "value": "${QBIT_PASSWORD}"},
        {"name": "tvCategory", "value": "tv"},
        {"name": "recentTvPriority", "value": 0},
        {"name": "olderTvPriority", "value": 0},
        {"name": "initialState", "value": 0},
        {"name": "sequentialOrder", "value": false},
        {"name": "firstAndLast", "value": false}
    ]
}
QBIT_JSON
)
        if api_post "${BASE}/api/v3/downloadclient" "application/json" "$qbit_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Sonarr: added qBittorrent download client"
        else
            fail "Sonarr: add qBittorrent download client"
        fi
    fi

    # Download client: SABnzbd (if running)
    if $SABNZBD_RUNNING && [[ -n "$SABNZBD_API_KEY" ]]; then
        if echo "$clients" | grep -qi 'sabnzbd'; then
            skip "Sonarr: SABnzbd download client"
        else
            local sab_payload
            sab_payload=$(cat <<SAB_JSON
{
    "enable": true,
    "protocol": "usenet",
    "priority": 1,
    "name": "SABnzbd",
    "implementation": "Sabnzbd",
    "configContract": "SabnzbdSettings",
    "fields": [
        {"name": "host", "value": "localhost"},
        {"name": "port", "value": 8080},
        {"name": "apiKey", "value": "${SABNZBD_API_KEY}"},
        {"name": "tvCategory", "value": "tv"},
        {"name": "recentTvPriority", "value": -100},
        {"name": "olderTvPriority", "value": -100}
    ]
}
SAB_JSON
)
            if api_post "${BASE}/api/v3/downloadclient" "application/json" "$sab_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Sonarr: added SABnzbd download client"
            else
                fail "Sonarr: add SABnzbd download client"
            fi
        fi
    fi

    # NFO Metadata
    local metadata
    metadata=$(api_get "${BASE}/api/v3/metadata" "$AUTH") || true
    # Find the Kodi/Emby metadata profile ID
    local meta_id
    meta_id=$(echo "$metadata" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
    if [[ -n "$meta_id" ]]; then
        local meta_enabled
        meta_enabled=$(echo "$metadata" | json_value_raw "enable")
        if [[ "$meta_enabled" == "true" ]]; then
            skip "Sonarr: NFO metadata"
        else
            local meta_payload="{\"enable\":true,\"name\":\"Kodi (XBMC) / Emby\",\"id\":${meta_id},\"fields\":[{\"name\":\"seriesMetadata\",\"value\":true},{\"name\":\"seriesMetadataEpisodeGuide\",\"value\":true},{\"name\":\"seriesMetadataUrl\",\"value\":false},{\"name\":\"episodeMetadata\",\"value\":true},{\"name\":\"seriesImages\",\"value\":false},{\"name\":\"seasonImages\",\"value\":false},{\"name\":\"episodeImages\",\"value\":false}],\"implementation\":\"XbmcMetadata\",\"configContract\":\"XbmcMetadataSettings\"}"
            if api_put "${BASE}/api/v3/metadata/${meta_id}" "application/json" "$meta_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Sonarr: enabled NFO metadata"
            else
                fail "Sonarr: enable NFO metadata"
            fi
        fi
    fi

    # Naming
    local naming
    naming=$(api_get "${BASE}/api/v3/config/naming" "$AUTH") || true
    local rename_enabled
    rename_enabled=$(echo "$naming" | json_value_raw "renameEpisodes")
    if [[ "$rename_enabled" == "true" ]]; then
        skip "Sonarr: TRaSH naming (already customised)"
    else
        local naming_payload
        naming_payload=$(cat <<'NAMING_JSON'
{
    "renameEpisodes": true,
    "replaceIllegalCharacters": true,
    "multiEpisodeStyle": 5,
    "standardEpisodeFormat": "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}",
    "dailyEpisodeFormat": "{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}",
    "animeEpisodeFormat": "{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo AudioCodec}{ MediaInfo AudioChannels}{MediaInfo AudioLanguages}]{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec][ Mediainfo VideoBitDepth]bit}{-Release Group}",
    "seasonFolderFormat": "Season {season:00}",
    "seriesFolderFormat": "{Series TitleYear} [tvdbid-{TvdbId}]"
}
NAMING_JSON
)
        if api_put "${BASE}/api/v3/config/naming" "application/json" "$naming_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Sonarr: set TRaSH naming scheme"
        else
            fail "Sonarr: set TRaSH naming scheme"
        fi
    fi

    # Custom Format: Reject ISO
    local formats
    formats=$(api_get "${BASE}/api/v3/customformat" "$AUTH") || true
    local iso_cf_id=""
    if echo "$formats" | grep -q '"Reject ISO"'; then
        skip "Sonarr: Reject ISO custom format"
        iso_cf_id=$(echo "$formats" | grep -o '"Reject ISO"[^}]*"id":[0-9]*' | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
        # Fallback: try other order
        if [[ -z "$iso_cf_id" ]]; then
            iso_cf_id=$(echo "$formats" | grep -B20 '"Reject ISO"' | grep -o '"id":[0-9]*' | tail -1 | grep -o '[0-9]*')
        fi
    else
        local cf_payload='{"name":"Reject ISO","includeCustomFormatWhenRenaming":false,"specifications":[{"name":"ISO","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"\\.iso$"}]}]}'
        local cf_result
        cf_result=$(api_post "${BASE}/api/v3/customformat" "application/json" "$cf_payload" "$AUTH" 2>&1) || true
        if echo "$cf_result" | grep -q '"id"'; then
            ok "Sonarr: added Reject ISO custom format"
            iso_cf_id=$(echo "$cf_result" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
        else
            fail "Sonarr: add Reject ISO custom format"
        fi
    fi

    # Score Reject ISO in quality profiles
    if [[ -n "$iso_cf_id" ]]; then
        local profiles
        profiles=$(api_get "${BASE}/api/v3/qualityprofile" "$AUTH") || true
        # Process each profile — look for profiles and add/update ISO scoring
        local profile_ids
        profile_ids=$(echo "$profiles" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
        for pid in $profile_ids; do
            local profile
            profile=$(api_get "${BASE}/api/v3/qualityprofile/${pid}" "$AUTH") || continue
            # Check if Reject ISO is already scored
            if echo "$profile" | grep -q "\"format\":${iso_cf_id}"; then
                local current_score
                current_score=$(echo "$profile" | grep -o "\"format\":${iso_cf_id},\"score\":[0-9-]*" | grep -o '"score":[0-9-]*' | grep -o '[0-9-]*$')
                if [[ "$current_score" == "-10000" ]]; then
                    continue  # Already scored correctly
                fi
            fi
            # Add or update the custom format score
            local updated_profile
            updated_profile=$(echo "$profile" | sed "s/\"formatItems\":\[/\"formatItems\":[{\"format\":${iso_cf_id},\"name\":\"Reject ISO\",\"score\":-10000},/")
            if api_put "${BASE}/api/v3/qualityprofile/${pid}" "application/json" "$updated_profile" "$AUTH" >/dev/null 2>&1; then
                ok "Sonarr: scored Reject ISO at -10000 in profile ${pid}"
            else
                fail "Sonarr: score Reject ISO in profile ${pid}"
            fi
        done
    fi

    # Delay profile (if SABnzbd running — prefer Usenet)
    if $SABNZBD_RUNNING; then
        local delays
        delays=$(api_get "${BASE}/api/v3/delayprofile" "$AUTH") || true
        # Check if any profile already prefers usenet with torrent delay
        if echo "$delays" | grep -q '"preferredProtocol".*"usenet"'; then
            skip "Sonarr: delay profile"
        else
            local delay_payload='{"enableUsenet":true,"enableTorrent":true,"preferredProtocol":"usenet","usenetDelay":0,"torrentDelay":30,"bypassIfHighestQuality":true,"order":2147483647,"tags":[]}'
            if api_post "${BASE}/api/v3/delayprofile" "application/json" "$delay_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Sonarr: added delay profile (Usenet 0, Torrent 30 min)"
            else
                fail "Sonarr: add delay profile"
            fi
        fi
    fi
}

# ============================================
# 3. Radarr
# ============================================

configure_radarr() {
    log "Configuring Radarr..."

    if [[ -z "$RADARR_API_KEY" ]]; then
        fail "Radarr: no API key, skipping"
        return
    fi

    local BASE="http://${NAS_IP}:7878"
    local AUTH="X-Api-Key: ${RADARR_API_KEY}"

    if ! wait_for_service "Radarr" "${BASE}/api/v3/health"; then return; fi

    if $DRY_RUN; then
        dry "Add root folder /data/media/movies"
        dry "Add qBittorrent download client (category: movies)"
        if $SABNZBD_RUNNING; then dry "Add SABnzbd download client (category: movies)"; fi
        dry "Enable NFO metadata (Kodi/Emby)"
        dry "Set TRaSH naming scheme"
        dry "Add Reject ISO custom format"
        dry "Score Reject ISO at -10000 in quality profiles"
        if $SABNZBD_RUNNING; then dry "Add delay profile (Usenet 0, Torrent 30)"; fi
        return
    fi

    # Root folder
    local roots
    roots=$(api_get "${BASE}/api/v3/rootfolder" "$AUTH") || true
    if echo "$roots" | grep -q '"/data/media/movies"'; then
        skip "Radarr: root folder /data/media/movies"
    else
        if api_post "${BASE}/api/v3/rootfolder" "application/json" '{"path":"/data/media/movies"}' "$AUTH" >/dev/null 2>&1; then
            ok "Radarr: added root folder /data/media/movies"
        else
            fail "Radarr: add root folder /data/media/movies"
        fi
    fi

    # Download client: qBittorrent
    local clients
    clients=$(api_get "${BASE}/api/v3/downloadclient" "$AUTH") || true
    if echo "$clients" | grep -qi 'qbittorrent'; then
        skip "Radarr: qBittorrent download client"
    else
        local qbit_payload
        qbit_payload=$(cat <<QBIT_JSON
{
    "enable": true,
    "protocol": "torrent",
    "priority": 1,
    "name": "qBittorrent",
    "implementation": "QBittorrent",
    "configContract": "QBittorrentSettings",
    "fields": [
        {"name": "host", "value": "localhost"},
        {"name": "port", "value": 8085},
        {"name": "username", "value": "${QBIT_USERNAME}"},
        {"name": "password", "value": "${QBIT_PASSWORD}"},
        {"name": "movieCategory", "value": "movies"},
        {"name": "recentMoviePriority", "value": 0},
        {"name": "olderMoviePriority", "value": 0},
        {"name": "initialState", "value": 0},
        {"name": "sequentialOrder", "value": false},
        {"name": "firstAndLast", "value": false}
    ]
}
QBIT_JSON
)
        if api_post "${BASE}/api/v3/downloadclient" "application/json" "$qbit_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Radarr: added qBittorrent download client"
        else
            fail "Radarr: add qBittorrent download client"
        fi
    fi

    # Download client: SABnzbd (if running)
    if $SABNZBD_RUNNING && [[ -n "$SABNZBD_API_KEY" ]]; then
        if echo "$clients" | grep -qi 'sabnzbd'; then
            skip "Radarr: SABnzbd download client"
        else
            local sab_payload
            sab_payload=$(cat <<SAB_JSON
{
    "enable": true,
    "protocol": "usenet",
    "priority": 1,
    "name": "SABnzbd",
    "implementation": "Sabnzbd",
    "configContract": "SabnzbdSettings",
    "fields": [
        {"name": "host", "value": "localhost"},
        {"name": "port", "value": 8080},
        {"name": "apiKey", "value": "${SABNZBD_API_KEY}"},
        {"name": "movieCategory", "value": "movies"},
        {"name": "recentMoviePriority", "value": -100},
        {"name": "olderMoviePriority", "value": -100}
    ]
}
SAB_JSON
)
            if api_post "${BASE}/api/v3/downloadclient" "application/json" "$sab_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Radarr: added SABnzbd download client"
            else
                fail "Radarr: add SABnzbd download client"
            fi
        fi
    fi

    # NFO Metadata
    local metadata
    metadata=$(api_get "${BASE}/api/v3/metadata" "$AUTH") || true
    local meta_id
    meta_id=$(echo "$metadata" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
    if [[ -n "$meta_id" ]]; then
        local meta_enabled
        meta_enabled=$(echo "$metadata" | json_value_raw "enable")
        if [[ "$meta_enabled" == "true" ]]; then
            skip "Radarr: NFO metadata"
        else
            local meta_payload="{\"enable\":true,\"name\":\"Kodi (XBMC) / Emby\",\"id\":${meta_id},\"fields\":[{\"name\":\"movieMetadata\",\"value\":true},{\"name\":\"movieMetadataURL\",\"value\":false},{\"name\":\"movieMetadataLanguage\",\"value\":1},{\"name\":\"movieImages\",\"value\":false},{\"name\":\"useMovieNfo\",\"value\":true}],\"implementation\":\"XbmcMetadata\",\"configContract\":\"XbmcMetadataSettings\"}"
            if api_put "${BASE}/api/v3/metadata/${meta_id}" "application/json" "$meta_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Radarr: enabled NFO metadata"
            else
                fail "Radarr: enable NFO metadata"
            fi
        fi
    fi

    # Naming
    local naming
    naming=$(api_get "${BASE}/api/v3/config/naming" "$AUTH") || true
    local rename_enabled
    rename_enabled=$(echo "$naming" | json_value_raw "renameMovies")
    if [[ "$rename_enabled" == "true" ]]; then
        skip "Radarr: TRaSH naming (already customised)"
    else
        local naming_payload
        naming_payload=$(cat <<'NAMING_JSON'
{
    "renameMovies": true,
    "replaceIllegalCharacters": true,
    "standardMovieFormat": "{Movie CleanTitle} {(Release Year)} {imdb-{ImdbId}} - {Edition Tags }{[Custom Formats]}{[Quality Full]}{[MediaInfo AudioCodec}{ MediaInfo AudioChannels]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo VideoCodec]}{-Release Group}",
    "movieFolderFormat": "{Movie CleanTitle} ({Release Year})"
}
NAMING_JSON
)
        if api_put "${BASE}/api/v3/config/naming" "application/json" "$naming_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Radarr: set TRaSH naming scheme"
        else
            fail "Radarr: set TRaSH naming scheme"
        fi
    fi

    # Custom Format: Reject ISO
    local formats
    formats=$(api_get "${BASE}/api/v3/customformat" "$AUTH") || true
    local iso_cf_id=""
    if echo "$formats" | grep -q '"Reject ISO"'; then
        skip "Radarr: Reject ISO custom format"
        iso_cf_id=$(echo "$formats" | grep -o '"Reject ISO"[^}]*"id":[0-9]*' | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
        if [[ -z "$iso_cf_id" ]]; then
            iso_cf_id=$(echo "$formats" | grep -B20 '"Reject ISO"' | grep -o '"id":[0-9]*' | tail -1 | grep -o '[0-9]*')
        fi
    else
        local cf_payload='{"name":"Reject ISO","includeCustomFormatWhenRenaming":false,"specifications":[{"name":"ISO","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"\\.iso$"}]}]}'
        local cf_result
        cf_result=$(api_post "${BASE}/api/v3/customformat" "application/json" "$cf_payload" "$AUTH" 2>&1) || true
        if echo "$cf_result" | grep -q '"id"'; then
            ok "Radarr: added Reject ISO custom format"
            iso_cf_id=$(echo "$cf_result" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
        else
            fail "Radarr: add Reject ISO custom format"
        fi
    fi

    # Score Reject ISO in quality profiles
    if [[ -n "$iso_cf_id" ]]; then
        local profiles
        profiles=$(api_get "${BASE}/api/v3/qualityprofile" "$AUTH") || true
        local profile_ids
        profile_ids=$(echo "$profiles" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
        for pid in $profile_ids; do
            local profile
            profile=$(api_get "${BASE}/api/v3/qualityprofile/${pid}" "$AUTH") || continue
            if echo "$profile" | grep -q "\"format\":${iso_cf_id}"; then
                local current_score
                current_score=$(echo "$profile" | grep -o "\"format\":${iso_cf_id},\"score\":[0-9-]*" | grep -o '"score":[0-9-]*' | grep -o '[0-9-]*$')
                if [[ "$current_score" == "-10000" ]]; then
                    continue
                fi
            fi
            local updated_profile
            updated_profile=$(echo "$profile" | sed "s/\"formatItems\":\[/\"formatItems\":[{\"format\":${iso_cf_id},\"name\":\"Reject ISO\",\"score\":-10000},/")
            if api_put "${BASE}/api/v3/qualityprofile/${pid}" "application/json" "$updated_profile" "$AUTH" >/dev/null 2>&1; then
                ok "Radarr: scored Reject ISO at -10000 in profile ${pid}"
            else
                fail "Radarr: score Reject ISO in profile ${pid}"
            fi
        done
    fi

    # Delay profile (if SABnzbd running)
    if $SABNZBD_RUNNING; then
        local delays
        delays=$(api_get "${BASE}/api/v3/delayprofile" "$AUTH") || true
        if echo "$delays" | grep -q '"preferredProtocol".*"usenet"'; then
            skip "Radarr: delay profile"
        else
            local delay_payload='{"enableUsenet":true,"enableTorrent":true,"preferredProtocol":"usenet","usenetDelay":0,"torrentDelay":30,"bypassIfHighestQuality":true,"order":2147483647,"tags":[]}'
            if api_post "${BASE}/api/v3/delayprofile" "application/json" "$delay_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Radarr: added delay profile (Usenet 0, Torrent 30 min)"
            else
                fail "Radarr: add delay profile"
            fi
        fi
    fi
}

# ============================================
# 4. Prowlarr
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

    if $DRY_RUN; then
        dry "Add FlareSolverr indexer proxy"
        dry "Add Sonarr application sync"
        dry "Add Radarr application sync"
        return
    fi

    # FlareSolverr proxy
    local proxies
    proxies=$(api_get "${BASE}/api/v1/indexerProxy" "$AUTH") || true
    if echo "$proxies" | grep -qi 'flaresolverr'; then
        skip "Prowlarr: FlareSolverr proxy"
    else
        local fs_payload='{"name":"FlareSolverr","implementation":"FlareSolverr","configContract":"FlareSolverrSettings","fields":[{"name":"host","value":"http://localhost:8191"},{"name":"requestTimeout","value":60}],"tags":[]}'
        if api_post "${BASE}/api/v1/indexerProxy" "application/json" "$fs_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Prowlarr: added FlareSolverr proxy"
        else
            fail "Prowlarr: add FlareSolverr proxy"
        fi
    fi

    # Application: Sonarr
    local apps
    apps=$(api_get "${BASE}/api/v1/applications" "$AUTH") || true
    if echo "$apps" | grep -qi 'sonarr'; then
        skip "Prowlarr: Sonarr application"
    else
        if [[ -n "$SONARR_API_KEY" ]]; then
            local sonarr_payload
            sonarr_payload=$(cat <<SONARR_APP
{
    "name": "Sonarr",
    "syncLevel": "fullSync",
    "implementation": "Sonarr",
    "configContract": "SonarrSettings",
    "fields": [
        {"name": "prowlarrUrl", "value": "http://localhost:9696"},
        {"name": "baseUrl", "value": "http://localhost:8989"},
        {"name": "apiKey", "value": "${SONARR_API_KEY}"},
        {"name": "syncCategories", "value": [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080]}
    ],
    "tags": []
}
SONARR_APP
)
            if api_post "${BASE}/api/v1/applications" "application/json" "$sonarr_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Prowlarr: added Sonarr application"
            else
                fail "Prowlarr: add Sonarr application"
            fi
        else
            fail "Prowlarr: add Sonarr (no Sonarr API key)"
        fi
    fi

    # Application: Radarr
    if echo "$apps" | grep -qi 'radarr'; then
        skip "Prowlarr: Radarr application"
    else
        if [[ -n "$RADARR_API_KEY" ]]; then
            local radarr_payload
            radarr_payload=$(cat <<RADARR_APP
{
    "name": "Radarr",
    "syncLevel": "fullSync",
    "implementation": "Radarr",
    "configContract": "RadarrSettings",
    "fields": [
        {"name": "prowlarrUrl", "value": "http://localhost:9696"},
        {"name": "baseUrl", "value": "http://localhost:7878"},
        {"name": "apiKey", "value": "${RADARR_API_KEY}"},
        {"name": "syncCategories", "value": [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080]}
    ],
    "tags": []
}
RADARR_APP
)
            if api_post "${BASE}/api/v1/applications" "application/json" "$radarr_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Prowlarr: added Radarr application"
            else
                fail "Prowlarr: add Radarr application"
            fi
        else
            fail "Prowlarr: add Radarr (no Radarr API key)"
        fi
    fi
}

# ============================================
# 5. Bazarr
# ============================================

configure_bazarr() {
    log "Configuring Bazarr..."

    if [[ -z "$BAZARR_API_KEY" ]]; then
        fail "Bazarr: no API key, skipping"
        return
    fi

    local BASE="http://${NAS_IP}:6767"
    local AUTH="X-API-KEY: ${BAZARR_API_KEY}"

    if ! wait_for_service "Bazarr" "${BASE}/api/system/status"; then return; fi

    if $DRY_RUN; then
        dry "Connect Bazarr to Sonarr (gluetun:8989)"
        dry "Connect Bazarr to Radarr (gluetun:7878)"
        dry "Enable subtitle sync (ffsubsync) with thresholds"
        dry "Enable Sub-Zero mods (remove tags, emoji, OCR fixes, common fixes, fix uppercase)"
        dry "Set default subtitle language to English"
        return
    fi

    # Get current settings
    local settings
    settings=$(api_get "${BASE}/api/system/settings" "$AUTH") || true

    if [[ -z "$settings" ]]; then
        fail "Bazarr: could not fetch current settings"
        return
    fi

    local needs_restart=false

    # --- Sonarr/Radarr connections ---
    local sonarr_connected=false radarr_connected=false
    # Check sonarr section specifically for gluetun + correct port
    local sonarr_section
    sonarr_section=$(echo "$settings" | python3 -c "import sys,json; d=json.load(sys.stdin); s=d.get('sonarr',{}); print(s.get('ip',''),s.get('port',''))" 2>/dev/null || echo "")
    local radarr_section
    radarr_section=$(echo "$settings" | python3 -c "import sys,json; d=json.load(sys.stdin); s=d.get('radarr',{}); print(s.get('ip',''),s.get('port',''))" 2>/dev/null || echo "")
    [[ "$sonarr_section" == "gluetun 8989" ]] && sonarr_connected=true
    [[ "$radarr_section" == "gluetun 7878" ]] && radarr_connected=true

    if $sonarr_connected && $radarr_connected; then
        skip "Bazarr: Sonarr/Radarr connections"
    else
        local conn_payload="{"
        if [[ -n "$SONARR_API_KEY" ]]; then
            conn_payload+="\"sonarr\": {\"ip\": \"gluetun\", \"port\": \"8989\", \"apikey\": \"${SONARR_API_KEY}\", \"base_url\": \"\"},"
        fi
        if [[ -n "$RADARR_API_KEY" ]]; then
            conn_payload+="\"radarr\": {\"ip\": \"gluetun\", \"port\": \"7878\", \"apikey\": \"${RADARR_API_KEY}\", \"base_url\": \"\"},"
        fi
        conn_payload="${conn_payload%,}}"
        if api_post "${BASE}/api/system/settings" "application/json" "$conn_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Bazarr: configured Sonarr/Radarr connections"
            needs_restart=true
        else
            fail "Bazarr: configure Sonarr/Radarr connections"
        fi
    fi

    # --- Subtitle sync (ffsubsync) ---
    local subsync_enabled
    subsync_enabled=$(echo "$settings" | grep -o '"use_subsync"[[:space:]]*:[[:space:]]*[a-z]*' | head -1 | grep -o '[a-z]*$')
    if [[ "$subsync_enabled" == "true" ]]; then
        skip "Bazarr: subtitle sync"
    else
        local subsync_payload='{"subsync": {"use_subsync": true, "use_subsync_threshold": true, "subsync_threshold": 90, "use_subsync_movie_threshold": true, "subsync_movie_threshold": 70}}'
        if api_post "${BASE}/api/system/settings" "application/json" "$subsync_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Bazarr: enabled subtitle sync (thresholds: series 90, movies 70)"
            needs_restart=true
        else
            fail "Bazarr: enable subtitle sync"
        fi
    fi

    # --- Sub-Zero content modifications ---
    # Remove Tags, Remove Emoji, OCR Fixes, Common Fixes, Fix Uppercase (Hearing Impaired OFF)
    local current_mods
    current_mods=$(echo "$settings" | grep -o '"subzero_mods"[[:space:]]*:[[:space:]]*\[[^]]*\]' | head -1)
    if echo "$current_mods" | grep -q 'remove_tags' && echo "$current_mods" | grep -q 'OCR_fixes'; then
        skip "Bazarr: Sub-Zero content modifications"
    else
        local subzero_payload='{"general": {"subzero_mods": ["remove_tags", "emoji", "OCR_fixes", "common", "fix_uppercase"]}}'
        if api_post "${BASE}/api/system/settings" "application/json" "$subzero_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Bazarr: enabled Sub-Zero mods (tags, emoji, OCR, common, uppercase)"
            needs_restart=true
        else
            fail "Bazarr: enable Sub-Zero mods"
        fi
    fi

    # --- Default subtitle language (English) ---
    local default_enabled
    default_enabled=$(echo "$settings" | grep -o '"serie_default_enabled"[[:space:]]*:[[:space:]]*[a-z]*' | head -1 | grep -o '[a-z]*$')
    if [[ "$default_enabled" == "true" ]]; then
        skip "Bazarr: default subtitle language"
    else
        local lang_payload='{"general": {"serie_default_enabled": true, "serie_default_profile": 1, "movie_default_enabled": true, "movie_default_profile": 1}}'
        if api_post "${BASE}/api/system/settings" "application/json" "$lang_payload" "$AUTH" >/dev/null 2>&1; then
            ok "Bazarr: set default subtitle language to English"
            needs_restart=true
        else
            fail "Bazarr: set default subtitle language"
        fi
    fi

    # Restart if any changes were made
    if $needs_restart; then
        info "Restarting Bazarr to apply changes..."
        docker restart bazarr >/dev/null 2>&1
    fi
}

# ============================================
# Run all
# ============================================

configure_qbittorrent
echo ""
configure_sonarr
echo ""
configure_radarr
echo ""
configure_prowlarr
echo ""
configure_bazarr

# ============================================
# Summary
# ============================================

echo ""
echo "=========================================="
echo "Summary: ${CONFIGURED} configured, ${SKIPPED} skipped, ${FAILED} failed"
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
    echo "  6. Pi-hole: upstream DNS"
else
    echo "  5. Pi-hole: upstream DNS"
fi

# Cleanup
rm -f "$QBIT_COOKIE"
