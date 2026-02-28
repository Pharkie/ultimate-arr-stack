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
#   --dry-run       Preview what would be configured without making changes
#   --verbose, -v   Print curl response bodies on failure (for debugging)
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
#   - Pi-hole: upstream DNS

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

# API keys (discovered at runtime)
SONARR_API_KEY=""
RADARR_API_KEY=""
PROWLARR_API_KEY=""
BAZARR_API_KEY=""
SABNZBD_API_KEY=""
QBIT_USERNAME="${QBIT_USERNAME:-admin}"
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
        --help|-h)
            head -27 "$0" | tail -24
            echo ""
            echo "This script is idempotent — safe to re-run at any time."
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--verbose|-v] [--help|-h]"
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

    # Authenticate using shared helper (see lib/configure-helpers.sh)
    local http_code
    if ! qbit_auth "$QBIT_URL" "$QBIT_USERNAME" "$QBIT_PASSWORD" "$QBIT_COOKIE"; then
        fail "qBittorrent: authentication failed (check QBIT_USERNAME/QBIT_PASSWORD)"
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

    # Set preferences (skip if already correct)
    local current_prefs
    current_prefs=$(curl -s -b "$QBIT_COOKIE" "${QBIT_URL}/api/v2/app/preferences" 2>/dev/null)

    if json_extract "$current_prefs" "
p = data
if not p.get('auto_tmm_enabled', False): sys.exit(1)
if p.get('upnp', True): sys.exit(1)
if not p.get('limit_utp_rate', False): sys.exit(1)
if not p.get('limit_lan_peers', False): sys.exit(1)
if p.get('encryption', 0) != 1: sys.exit(1)
"; then
        skip "qBittorrent: preferences"
    else
        local prefs='{"auto_tmm_enabled":true,"upnp":false,"limit_utp_rate":true,"limit_lan_peers":true,"encryption":1}'
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -b "$QBIT_COOKIE" \
            --data-urlencode "json=${prefs}" \
            "${QBIT_URL}/api/v2/app/setPreferences")

        if [[ "$http_code" == "200" ]]; then
            ok "qBittorrent: set preferences (auto TMM, UPnP off, encryption)"
        else
            fail "qBittorrent: set preferences (HTTP $http_code)"
        fi
    fi

    rm -f "$QBIT_COOKIE"
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

    if $DRY_RUN; then
        dry "Add FlareSolverr indexer proxy"
        dry "Add Sonarr application sync"
        dry "Add Radarr application sync"
        return
    fi

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

    # Applications: Sonarr and Radarr
    local apps
    apps=$(api_get "${BASE}/api/v1/applications" "$AUTH") || true

    local arr_name arr_port arr_categories
    for arr_name in Sonarr Radarr; do
        local key_var="${arr_name^^}_API_KEY"
        local arr_key="${!key_var}"
        if [[ "$arr_name" == "Sonarr" ]]; then
            arr_port=8989; arr_categories="[5000, 5010, 5020, 5030, 5040, 5045, 5050, 5060, 5070, 5080]"
        else
            arr_port=7878; arr_categories="[2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080]"
        fi

        local name_lower="${arr_name,,}"
        if json_extract "$apps" "sys.exit(0 if any(a.get('name','').lower() == '${name_lower}' for a in data) else 1)"; then
            skip "Prowlarr: ${arr_name} application"
        elif [[ -z "$arr_key" ]]; then
            fail "Prowlarr: add ${arr_name} (no ${arr_name} API key)"
        else
            local app_payload="{\"name\":\"${arr_name}\",\"syncLevel\":\"fullSync\",\"implementation\":\"${arr_name}\",\"configContract\":\"${arr_name}Settings\",\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://localhost:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://localhost:${arr_port}\"},{\"name\":\"apiKey\",\"value\":\"${arr_key}\"},{\"name\":\"syncCategories\",\"value\":${arr_categories}}],\"tags\":[]}"
            if api_post "${BASE}/api/v1/applications" "application/json" "$app_payload" "$AUTH" >/dev/null 2>&1; then
                ok "Prowlarr: added ${arr_name} application"
            else
                fail "Prowlarr: add ${arr_name} application"
            fi
        fi
    done
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

    # Bazarr is bound to localhost (127.0.0.1) — not accessible via NAS_IP
    local BASE="http://127.0.0.1:6767"
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
    local sonarr_section
    sonarr_section=$(json_extract "$settings" "s=data.get('sonarr',{}); print(s.get('ip',''),s.get('port',''))")
    local radarr_section
    radarr_section=$(json_extract "$settings" "s=data.get('radarr',{}); print(s.get('ip',''),s.get('port',''))")
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
    if json_extract "$settings" "sys.exit(0 if data.get('subsync', {}).get('use_subsync') else 1)"; then
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
    if json_extract "$settings" "
mods = data.get('general', {}).get('subzero_mods', [])
sys.exit(0 if 'remove_tags' in mods and 'OCR_fixes' in mods else 1)"; then
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
    if json_extract "$settings" "sys.exit(0 if data.get('general', {}).get('serie_default_enabled') else 1)"; then
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
configure_arr_service "Sonarr" 8989 "$SONARR_API_KEY" "/data/media/tv" "tv" \
    "renameEpisodes" "$SONARR_METADATA_FIELDS" "$SONARR_NAMING_PAYLOAD"
echo ""
configure_arr_service "Radarr" 7878 "$RADARR_API_KEY" "/data/media/movies" "movies" \
    "renameMovies" "$RADARR_METADATA_FIELDS" "$RADARR_NAMING_PAYLOAD"
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
