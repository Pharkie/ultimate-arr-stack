#!/bin/bash
#
# Shared helper functions for configure-apps.sh
#
# Sourced by the main script — not meant to be run directly.
# Requires python3 for JSON parsing.

# ============================================
# JSON parsing
# ============================================

# General-purpose JSON extraction via python3
#
# Usage:
#   json_extract "$json" "print(data.get('id',''))"            — extract a value
#   json_extract "$json" "sys.exit(0 if condition else 1)"     — boolean check
#   json_extract "$json" "print(json.dumps(modified))"         — transform JSON
json_extract() {
    local json="$1" expr="$2"
    echo "$json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
$expr
" 2>/dev/null
}

# ============================================
# Output helpers
# ============================================

log()   { echo "[configure] $1"; }
ok()    { echo "  ✓ $1"; CONFIGURED=$((CONFIGURED + 1)); }
skip()  { echo "  - $1 (already configured)"; SKIPPED=$((SKIPPED + 1)); }
fail()  { echo "  ✗ $1"; FAILED=$((FAILED + 1)); }
info()  { echo "  $1"; }
dry()   { echo "  [dry-run] Would: $1"; }

# ============================================
# HTTP helpers
# ============================================

# Usage: body=$(api_get "url" "header1" "header2" ...)
#        body=$(api_post "url" "application/json" '{"k":"v"}' "header1" ...)
_api_request() {
    local method="$1" url="$2"; shift 2
    local args=(-s -w '\n%{http_code}' -o -)
    if [[ "$method" != "GET" ]]; then
        local content_type="$1" data="$2"; shift 2
        args+=(-X "$method" -H "Content-Type: $content_type")
        if [[ -n "$data" ]]; then args+=(--data "$data"); fi
    fi
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
        [[ "$method" != "GET" ]] && echo "$body"
        if [[ "$method" == "GET" ]]; then return 1; else return "$code"; fi
    fi
}

api_get()  { _api_request GET  "$@"; }
api_post() { _api_request POST "$@"; }
api_put()  { _api_request PUT  "$@"; }

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
# Shared Sonarr/Radarr configuration
# ============================================

# Configure an *arr service (Sonarr or Radarr)
#
# Arguments:
#   $1 = name              — "Sonarr" or "Radarr"
#   $2 = port              — 8989 or 7878
#   $3 = api_key           — API key for the service
#   $4 = root_path         — /data/media/tv or /data/media/movies
#   $5 = category          — qBit category: "tv" or "movies"
#   $6 = naming_check      — field to check: "renameEpisodes" or "renameMovies"
#   $7 = metadata_fields   — JSON array of metadata field objects
#   $8 = naming_payload    — full JSON payload for naming config
#
# Requires globals: NAS_IP, DRY_RUN, QBIT_USERNAME, QBIT_PASSWORD,
#                   SABNZBD_RUNNING, SABNZBD_API_KEY
configure_arr_service() {
    local name="$1"
    local port="$2"
    local api_key="$3"
    local root_path="$4"
    local category="$5"
    local naming_check="$6"
    local metadata_fields="$7"
    local naming_payload="$8"

    log "Configuring ${name}..."

    if [[ -z "$api_key" ]]; then
        fail "${name}: no API key, skipping"
        return
    fi

    local BASE="http://${NAS_IP}:${port}"
    local AUTH="X-Api-Key: ${api_key}"

    if ! wait_for_service "$name" "${BASE}/api/v3/health"; then return; fi

    # Derive category field names from category
    local cat_field priority_recent priority_older
    if [[ "$category" == "tv" ]]; then
        cat_field="tvCategory"
        priority_recent="recentTvPriority"
        priority_older="olderTvPriority"
    else
        cat_field="movieCategory"
        priority_recent="recentMoviePriority"
        priority_older="olderMoviePriority"
    fi

    if $DRY_RUN; then
        dry "Add root folder ${root_path}"
        dry "Add qBittorrent download client (category: ${category})"
        if $SABNZBD_RUNNING; then dry "Add SABnzbd download client (category: ${category})"; fi
        dry "Enable NFO metadata (Kodi/Emby)"
        dry "Set TRaSH naming scheme"
        dry "Add Reject ISO custom format"
        dry "Score Reject ISO at -10000 in quality profiles"
        if $SABNZBD_RUNNING; then dry "Add delay profile (Usenet 0, Torrent 30)"; fi
        return
    fi

    # --- Root folder ---
    local roots
    roots=$(api_get "${BASE}/api/v3/rootfolder" "$AUTH") || true
    if json_extract "$roots" "sys.exit(0 if any(r.get('path') == '${root_path}' for r in data) else 1)"; then
        skip "${name}: root folder ${root_path}"
    else
        if api_post "${BASE}/api/v3/rootfolder" "application/json" "{\"path\":\"${root_path}\"}" "$AUTH" >/dev/null 2>&1; then
            ok "${name}: added root folder ${root_path}"
        else
            fail "${name}: add root folder ${root_path}"
        fi
    fi

    # --- Download client: qBittorrent ---
    local clients
    clients=$(api_get "${BASE}/api/v3/downloadclient" "$AUTH") || true
    if json_extract "$clients" "sys.exit(0 if any(c.get('name','').lower() == 'qbittorrent' for c in data) else 1)"; then
        skip "${name}: qBittorrent download client"
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
        {"name": "${cat_field}", "value": "${category}"},
        {"name": "${priority_recent}", "value": 0},
        {"name": "${priority_older}", "value": 0},
        {"name": "initialState", "value": 0},
        {"name": "sequentialOrder", "value": false},
        {"name": "firstAndLast", "value": false}
    ]
}
QBIT_JSON
)
        if api_post "${BASE}/api/v3/downloadclient" "application/json" "$qbit_payload" "$AUTH" >/dev/null 2>&1; then
            ok "${name}: added qBittorrent download client"
        else
            fail "${name}: add qBittorrent download client"
        fi
    fi

    # --- Download client: SABnzbd (if running) ---
    if $SABNZBD_RUNNING && [[ -n "$SABNZBD_API_KEY" ]]; then
        if json_extract "$clients" "sys.exit(0 if any(c.get('name','').lower() == 'sabnzbd' for c in data) else 1)"; then
            skip "${name}: SABnzbd download client"
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
        {"name": "${cat_field}", "value": "${category}"},
        {"name": "${priority_recent}", "value": -100},
        {"name": "${priority_older}", "value": -100}
    ]
}
SAB_JSON
)
            if api_post "${BASE}/api/v3/downloadclient" "application/json" "$sab_payload" "$AUTH" >/dev/null 2>&1; then
                ok "${name}: added SABnzbd download client"
            else
                fail "${name}: add SABnzbd download client"
            fi
        fi
    fi

    # --- NFO Metadata ---
    local metadata
    metadata=$(api_get "${BASE}/api/v3/metadata" "$AUTH") || true
    local meta_id
    meta_id=$(json_extract "$metadata" "
xbmc = [m for m in data if m.get('implementation') == 'XbmcMetadata']
print(xbmc[0]['id'] if xbmc else '')")
    if [[ -n "$meta_id" ]]; then
        local meta_enabled
        meta_enabled=$(json_extract "$metadata" "
xbmc = [m for m in data if m.get('implementation') == 'XbmcMetadata']
print(str(xbmc[0].get('enable', False)).lower() if xbmc else 'false')")
        if [[ "$meta_enabled" == "true" ]]; then
            skip "${name}: NFO metadata"
        else
            local meta_payload="{\"enable\":true,\"name\":\"Kodi (XBMC) / Emby\",\"id\":${meta_id},\"fields\":${metadata_fields},\"implementation\":\"XbmcMetadata\",\"configContract\":\"XbmcMetadataSettings\"}"
            if api_put "${BASE}/api/v3/metadata/${meta_id}" "application/json" "$meta_payload" "$AUTH" >/dev/null 2>&1; then
                ok "${name}: enabled NFO metadata"
            else
                fail "${name}: enable NFO metadata"
            fi
        fi
    fi

    # --- Naming ---
    local naming
    naming=$(api_get "${BASE}/api/v3/config/naming" "$AUTH") || true
    local rename_enabled
    rename_enabled=$(json_extract "$naming" "print(str(data.get('${naming_check}', False)).lower())")
    if [[ "$rename_enabled" == "true" ]]; then
        skip "${name}: TRaSH naming (already customised)"
    else
        if api_put "${BASE}/api/v3/config/naming" "application/json" "$naming_payload" "$AUTH" >/dev/null 2>&1; then
            ok "${name}: set TRaSH naming scheme"
        else
            fail "${name}: set TRaSH naming scheme"
        fi
    fi

    # --- Custom Format: Reject ISO ---
    local formats
    formats=$(api_get "${BASE}/api/v3/customformat" "$AUTH") || true
    local iso_cf_id=""
    if json_extract "$formats" "sys.exit(0 if any(c.get('name') == 'Reject ISO' for c in data) else 1)"; then
        skip "${name}: Reject ISO custom format"
        iso_cf_id=$(json_extract "$formats" "
cfs = [c['id'] for c in data if c.get('name') == 'Reject ISO']
print(cfs[0] if cfs else '')")
    else
        local cf_payload='{"name":"Reject ISO","includeCustomFormatWhenRenaming":false,"specifications":[{"name":"ISO","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"\\.iso$"}]}]}'
        local cf_result
        cf_result=$(api_post "${BASE}/api/v3/customformat" "application/json" "$cf_payload" "$AUTH") || true
        iso_cf_id=$(json_extract "$cf_result" "print(data.get('id', ''))")
        if [[ -n "$iso_cf_id" ]]; then
            ok "${name}: added Reject ISO custom format"
        else
            fail "${name}: add Reject ISO custom format"
        fi
    fi

    # --- Score Reject ISO in quality profiles ---
    if [[ -n "$iso_cf_id" ]]; then
        local profiles
        profiles=$(api_get "${BASE}/api/v3/qualityprofile" "$AUTH") || true
        local profile_ids
        profile_ids=$(json_extract "$profiles" "
for p in data:
    print(p['id'])")
        for pid in $profile_ids; do
            local profile
            profile=$(api_get "${BASE}/api/v3/qualityprofile/${pid}" "$AUTH") || continue
            # Skip if already scored correctly
            if json_extract "$profile" "
items = data.get('formatItems', [])
match = [i for i in items if i.get('format') == ${iso_cf_id}]
sys.exit(0 if match and match[0].get('score') == -10000 else 1)"; then
                continue
            fi
            # Add or update the custom format score
            local updated_profile
            updated_profile=$(json_extract "$profile" "
items = data.get('formatItems', [])
items = [i for i in items if i.get('format') != ${iso_cf_id}]
items.insert(0, {'format': ${iso_cf_id}, 'name': 'Reject ISO', 'score': -10000})
data['formatItems'] = items
print(json.dumps(data))")
            if api_put "${BASE}/api/v3/qualityprofile/${pid}" "application/json" "$updated_profile" "$AUTH" >/dev/null 2>&1; then
                ok "${name}: scored Reject ISO at -10000 in profile ${pid}"
            else
                fail "${name}: score Reject ISO in profile ${pid}"
            fi
        done
    fi

    # --- Delay profile (if SABnzbd running — prefer Usenet) ---
    if $SABNZBD_RUNNING; then
        local delays
        delays=$(api_get "${BASE}/api/v3/delayprofile" "$AUTH") || true
        if json_extract "$delays" "sys.exit(0 if any(d.get('preferredProtocol') == 'usenet' for d in data) else 1)"; then
            skip "${name}: delay profile"
        else
            local delay_payload='{"enableUsenet":true,"enableTorrent":true,"preferredProtocol":"usenet","usenetDelay":0,"torrentDelay":30,"bypassIfHighestQuality":true,"order":2147483647,"tags":[]}'
            if api_post "${BASE}/api/v3/delayprofile" "application/json" "$delay_payload" "$AUTH" >/dev/null 2>&1; then
                ok "${name}: added delay profile (Usenet 0, Torrent 30 min)"
            else
                fail "${name}: add delay profile"
            fi
        fi
    fi
}
