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

# No `set -e`, deliberately. This script's whole shape is "attempt every step,
# count what failed, report at the end" - a dozen `fail` calls exist precisely
# so one unreachable service does not abandon the other five. `set -u` and
# pipefail are on because neither of them changes that: they catch a misspelt
# variable and a silently-swallowed pipeline failure, which are bugs in the
# script rather than conditions it is designed to survive.
set -uo pipefail

# ============================================
# Source helpers
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/configure-helpers.sh
source "${SCRIPT_DIR}/lib/configure-helpers.sh"

# ============================================
# Globals
# ============================================

DRY_RUN=false
VERBOSE=false
NAS_IP=""
QBIT_COOKIE=""

# Overridable only so tests/configure-apps.bats can point at a fixture. Nothing
# in production sets it; the default is the repo's own .env, resolved from this
# script's location rather than from the caller's working directory. It used to
# be the bare relative path `.env`, so running the script from anywhere but the
# repo root silently skipped the password lookup and fell through to scraping
# docker logs.
CONFIGURE_ENV_FILE="${CONFIGURE_ENV_FILE:-${REPO_ROOT}/.env}"

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
SABNZBD_RUNNING=false
QBIT_USERNAME="${QBIT_USERNAME:-admin}"
QBIT_PASSWORD="${QBIT_PASSWORD:-}"

# ============================================
# Usage
# ============================================

# Print this file's own leading comment block.
#
# Derived, not a line range. This was `head -27 "$0" | tail -24`, which had
# already gone stale: the block runs to line 29, so --help silently dropped its
# last two lines. A hardcoded range is wrong the moment anyone edits the
# header, and nothing tells you.
print_usage() {
    local self="${1:-${BASH_SOURCE[0]}}"
    # awk and not a sed range: the block ends at a BLANK line, and `/^[^#]/`
    # does not match one - a bracket expression needs a character to reject, and
    # an empty line has none. A sed range would run straight past the blank into
    # the next comment block.
    awk 'NR == 1 { next } /^#/ { sub(/^#( |$)/, ""); print; next } { exit }' "$self"
}

# Read one KEY= value out of an env file.
#
# Keeps everything after the FIRST `=`, so a value containing one survives, and
# strips a single layer of surrounding quotes - which `cut -d= -f2-` does not,
# so a quoted password used to be handed to qBittorrent with the quotes still
# attached and simply failed to authenticate.
env_value() {
    local key="$1" file="$2" line
    [[ -f "$file" ]] || return 1
    line=$(grep -m1 "^${key}=" "$file") || return 1
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    line="${line%\'}"; line="${line#\'}"
    printf '%s\n' "$line"
}

# ============================================
# Arguments
# ============================================

parse_args() {
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
                print_usage "${BASH_SOURCE[0]}"
                echo ""
                echo "This script is idempotent - safe to re-run at any time."
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Usage: $0 [--dry-run] [--verbose|-v] [--help|-h]"
                return 1
                ;;
        esac
    done
    return 0
}

# ============================================
# Prerequisites
# ============================================

REQUIRED_CONTAINERS="gluetun qbittorrent sonarr radarr prowlarr bazarr"

check_prerequisites() {
    if ! command -v docker &>/dev/null; then
        echo "ERROR: docker not found. Run this on the NAS."
        return 1
    fi

    NAS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$NAS_IP" ]]; then
        echo "ERROR: Could not detect NAS IP"
        return 1
    fi
    log "NAS IP: $NAS_IP"

    if [[ "$DRY_RUN" == true ]]; then
        log "DRY RUN - no changes will be made"
    fi
    echo ""

    # Capture docker ps's output once before grepping it, rather than piping
    # straight into grep -q: under `set -o pipefail`, grep -q exits the
    # instant it matches, and if that match lands on anything but the LAST
    # line, docker ps can still be mid-write when the pipe closes underneath
    # it, giving docker ps a SIGPIPE-caused non-zero exit that pipefail
    # reports as the whole check failing even though grep found its match.
    # See scripts/queue-cleanup.sh's get_api_key() for the original diagnosis.
    local running
    running=$(docker ps --format '{{.Names}}')

    local c missing=""
    for c in $REQUIRED_CONTAINERS; do
        if ! grep -qx "$c" <<< "$running"; then
            missing="$missing $c"
        fi
    done
    if [[ -n "$missing" ]]; then
        echo "ERROR: Required containers not running:$missing"
        echo "Start the stack first: docker compose -f docker-compose.arr-stack.yml up -d"
        return 1
    fi

    # Gluetun must be healthy - qBittorrent and the *arr services share its
    # network namespace, so if the VPN isn't up they won't respond on any port.
    # Checking here turns a 4-minute mysterious hang into a clear error.
    local health
    health=$(docker inspect -f '{{.State.Health.Status}}' gluetun 2>/dev/null || echo unknown)
    if [[ "$health" != "healthy" ]]; then
        echo "ERROR: Gluetun is '$health' (need 'healthy')."
        echo "       qBit and the *arr services share Gluetun's network - they can't respond until the VPN is up."
        echo "       Wait for it to connect, then re-run. Diagnose: docker logs gluetun --tail 50"
        return 1
    fi

    # SABnzbd is optional. Reuses $running captured above -- same pipefail
    # hazard as the required-containers check, same fix.
    if grep -qx "sabnzbd" <<< "$running"; then
        SABNZBD_RUNNING=true
    fi
    return 0
}

# ============================================
# Discover API keys
# ============================================

# The *arr services all keep theirs in the same place and the same shape.
arr_api_key() {
    # `sed -n 's|...|...|p'`, not `grep -oP '(?<=<ApiKey>)[^<]+'`. GNU grep's -P
    # is not available on macOS or any other BSD grep, where it exits 2 with
    # "invalid option" -- and the pipeline's status is discarded here, so every
    # lookup came back empty and the operator was told the service had no API
    # key to give. A lookbehind is the one thing sed cannot express, and it is
    # not needed: capture the element's text instead, which is what the
    # lookbehind was there to skip past.
    docker exec "$1" cat /config/config.xml 2>/dev/null \
        | sed -n 's|.*<ApiKey>\([^<]*\).*|\1|p' || true
}

discover_api_keys() {
    log "Discovering API keys..."

    local svc var
    for svc in sonarr radarr prowlarr; do
        var="${svc^^}_API_KEY"
        printf -v "$var" '%s' "$(arr_api_key "$svc")"
        if [[ -z "${!var}" ]]; then
            fail "Could not discover ${svc^} API key"
        else
            info "${svc^} API key: ${!var:0:8}..."
        fi
    done

    # Bazarr - apikey is on the same line as the key: "  apikey: abc123"
    BAZARR_API_KEY=$(docker exec bazarr grep '^\s*apikey:' /config/config/config.yaml 2>/dev/null \
        | head -1 | sed 's/.*apikey:\s*//' | tr -d ' ' || true)
    if [[ -z "$BAZARR_API_KEY" ]]; then
        fail "Could not discover Bazarr API key"
    else
        info "Bazarr API key: ${BAZARR_API_KEY:0:8}..."
    fi

    # SABnzbd (optional)
    if [[ "$SABNZBD_RUNNING" == true ]]; then
        SABNZBD_API_KEY=$(docker exec sabnzbd grep '^api_key' /config/sabnzbd.ini 2>/dev/null \
            | head -1 | sed 's/^api_key = //' | tr -d ' ' || true)
        if [[ -n "$SABNZBD_API_KEY" ]]; then
            info "SABnzbd API key: ${SABNZBD_API_KEY:0:8}..."
        fi
    fi

    # qBittorrent password: env var -> .env file -> docker logs temp password
    if [[ -z "$QBIT_PASSWORD" ]]; then
        QBIT_PASSWORD=$(env_value QBIT_PASSWORD "$CONFIGURE_ENV_FILE") || QBIT_PASSWORD=""
    fi
    if [[ -z "$QBIT_PASSWORD" ]]; then
        # Same portability reason as arr_api_key above: `grep -oP ... \K` is
        # GNU-only, so on a BSD grep host this scrape found nothing and the
        # script told the operator to set a password that was sitting in the
        # logs. `[^ ]*` after the last colon-space is what `\K\S+` selected.
        QBIT_PASSWORD=$(docker logs qbittorrent 2>&1 \
            | sed -n 's|.*temporary password is provided.*: \([^ ]*\).*|\1|p' | tail -1 || true)
    fi
    if [[ -z "$QBIT_PASSWORD" ]]; then
        echo ""
        echo "WARNING: Could not find qBittorrent password."
        echo "         Set QBIT_PASSWORD env var if you've changed the default, e.g.:"
        echo "         QBIT_PASSWORD=mypassword ./scripts/configure-apps.sh"
        echo ""
    fi

    echo ""
}

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

    if [[ "$DRY_RUN" == true ]]; then
        dry "Authenticate to qBittorrent"
        dry "Create category 'tv' → /data/torrents/tv"
        dry "Create category 'movies' → /data/torrents/movies"
        dry "Set preferences: auto TMM, disable UPnP, encryption, stall timeout, concurrent limits"
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
if not p.get('max_inactive_seeding_time_enabled', False): sys.exit(1)
if p.get('max_inactive_seeding_time', -1) != 30: sys.exit(1)
if p.get('max_ratio_act', -1) != 0: sys.exit(1)
if p.get('max_active_downloads', -1) != 5: sys.exit(1)
if p.get('max_active_torrents', -1) != 10: sys.exit(1)
if p.get('max_active_uploads', -1) != 5: sys.exit(1)
"; then
        skip "qBittorrent: preferences"
    else
        local prefs='{"auto_tmm_enabled":true,"upnp":false,"limit_utp_rate":true,"limit_lan_peers":true,"encryption":1,"max_inactive_seeding_time_enabled":true,"max_inactive_seeding_time":30,"max_ratio_act":0,"max_active_downloads":5,"max_active_torrents":10,"max_active_uploads":5}'
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            -b "$QBIT_COOKIE" \
            --data-urlencode "json=${prefs}" \
            "${QBIT_URL}/api/v2/app/setPreferences")

        if [[ "$http_code" == "200" ]]; then
            ok "qBittorrent: set preferences (auto TMM, UPnP off, encryption, stall timeout, concurrent limits)"
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

    if [[ "$DRY_RUN" == true ]]; then
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

    local BASE="http://${NAS_IP}:6767"
    local AUTH="X-API-KEY: ${BAZARR_API_KEY}"

    if ! wait_for_service "Bazarr" "${BASE}/api/system/status"; then return; fi

    if [[ "$DRY_RUN" == true ]]; then
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

    if [[ "$sonarr_connected" == true && "$radarr_connected" == true ]]; then
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
    if [[ "$needs_restart" == true ]]; then
        info "Restarting Bazarr to apply changes..."
        docker restart bazarr >/dev/null 2>&1
    fi
}

# ============================================
# 5. Pi-hole
# ============================================

configure_pihole() {
    log "Configuring Pi-hole..."

    if [[ "$DRY_RUN" == true ]]; then
        dry "Set Pi-hole upstream DNS to dnscrypt-proxy (172.20.0.6#5053)"
        return
    fi

    # Check current upstream DNS configuration
    local current_dns
    current_dns=$(docker exec pihole pihole-FTL --config dns.upstreams 2>/dev/null || true)

    if [[ "$current_dns" == *"172.20.0.6#5053"* ]]; then
        skip "Pi-hole: upstream DNS (already using dnscrypt-proxy)"
    else
        # Set dnscrypt-proxy as upstream DNS using FTL config
        if docker exec pihole pihole-FTL --config dns.upstreams '["172.20.0.6#5053"]' >/dev/null 2>&1; then
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

run_all() {
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
    echo ""
    configure_pihole
}

# ============================================
# Summary
# ============================================

# Returns non-zero when anything failed, so `FAILED` is not merely decorative.
# It used to be printed and then discarded: the script exited 0 whether it had
# configured everything or nothing, which makes it unusable from anything that
# checks a status - including the deploy pipeline that is the obvious caller.
print_summary() {
    echo ""
    echo "=========================================="
    echo "Summary: ${CONFIGURED} configured, ${SKIPPED} skipped, ${FAILED} failed"
    echo "=========================================="

    if (( FAILED > 0 )); then
        echo ""
        echo "Some steps failed. Re-run to retry, or configure manually via web UI."
    fi

    echo ""
    echo "Remaining manual steps:"
    echo "  1. Jellyfin: initial wizard, libraries, hardware transcoding"
    echo "  2. qBittorrent: change default password (Tools -> Options -> Web UI)"
    echo "  3. Prowlarr: add indexers (torrent/Usenet)"
    echo "  4. Seerr: initial setup + Jellyfin login"
    if [[ "$SABNZBD_RUNNING" == true ]]; then
        echo "  5. SABnzbd: usenet provider credentials"
    fi

    (( FAILED == 0 ))
}

main() {
    parse_args "$@" || return 1

    echo "=== Arr-Stack App Configuration ==="
    echo ""

    check_prerequisites || return 1

    # A private, unpredictable path. This was the fixed /tmp/qbit_configure_cookie.txt:
    # a world-writable directory, one session cookie, no trap - so two concurrent
    # runs clobbered each other's session and any early return left the cookie on
    # disk. The trap is what makes "we always clean up" true rather than intended.
    QBIT_COOKIE=$(mktemp -t qbit_configure_cookie.XXXXXX)
    trap '[[ -n "$QBIT_COOKIE" ]] && rm -f "$QBIT_COOKIE"' EXIT

    discover_api_keys
    run_all
    print_summary
}

# Sourced by tests/configure-apps.bats; executed on the NAS.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
