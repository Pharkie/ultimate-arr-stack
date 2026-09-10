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
# In a dry run, ok() is reached only after the same state check a real run
# performs, and the write it would have followed was suppressed at the choke
# points (_api_request, bazarr_settings_post, and the few raw curl/docker
# sites in configure-apps.sh). So "Would:" here means "checked, and missing" —
# not "listed unconditionally", which is what the old early-return blocks did.
ok() {
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "  [dry-run] Would: $1"; WOULD=$((WOULD + 1))
    else
        echo "  ✓ $1"; CONFIGURED=$((CONFIGURED + 1))
    fi
}
skip()  { echo "  - $1 (already configured)"; SKIPPED=$((SKIPPED + 1)); }
fail()  { echo "  ✗ $1"; FAILED=$((FAILED + 1)); }
info()  { echo "  $1"; }
verbose() { [[ "${VERBOSE:-false}" == "true" ]] && echo "  [verbose] $1" >&2; return 0; }

# ============================================
# HTTP helpers
# ============================================

# Every request is bounded. API_TIMEOUT (default 60 s) caps the whole
# transfer, --connect-timeout 5 caps the handshake, and a single call can
# raise its own cap with API_MAX_TIME=<s> in front of it — the Bazarr
# languages POST does, because Bazarr rescans the whole library inside that
# request. Before this, one hung handler held the script open forever
# (Bazarr's Sonarr/Radarr SignalR restart, 2026-09-10), and the same class
# exists for every *arr write that runs a connection test before answering.
API_TIMEOUT="${API_TIMEOUT:-60}"
BAZARR_POST_TIMEOUT="${BAZARR_POST_TIMEOUT:-60}"
BAZARR_SCAN_TIMEOUT="${BAZARR_SCAN_TIMEOUT:-600}"
for _t in API_TIMEOUT BAZARR_POST_TIMEOUT BAZARR_SCAN_TIMEOUT; do
    if ! [[ "${!_t}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: $_t must be a positive integer number of seconds, got '${!_t}'" >&2
        exit 1
    fi
done
unset _t

# Run curl once and expose the result. Sets HTTP_RC (curl's own exit code),
# HTTP_CODE and HTTP_BODY. Returns 0 only when an HTTP exchange completed;
# transport failures — refused, DNS, reset, timeout — return 1 with HTTP_RC
# set, and HTTP_CODE is never trusted on that path. That distinction is the
# whole point: curl still emits "000" for its -w write-out when the connection
# failed, and code that parsed the write-out alone treated "000" as an answer.
#
# Usage: _curl_capture "$url" [curl args...]
_curl_capture() {
    local url="$1"; shift
    local max_time="${API_MAX_TIME:-$API_TIMEOUT}"
    local response
    HTTP_RC=0; HTTP_CODE=""; HTTP_BODY=""
    response=$(curl -s --connect-timeout 5 --max-time "$max_time" -w '\n%{http_code}' -o - "$@" "$url") || HTTP_RC=$?
    if [[ $HTTP_RC -ne 0 ]]; then
        if [[ $HTTP_RC -eq 28 ]]; then
            verbose "$url → no response within ${max_time}s (curl exit 28)"
        else
            verbose "$url → curl exit ${HTTP_RC}, no HTTP exchange"
        fi
        return 1
    fi
    HTTP_CODE=$(echo "$response" | tail -1)
    HTTP_BODY=$(echo "$response" | sed '$d')
    return 0
}

# Usage: body=$(api_get "url" "header1" "header2" ...)
#        body=$(api_post "url" "application/json" '{"k":"v"}' "header1" ...)
#
# Returns 0 on a 2xx, 2 when the request timed out, 1 on anything else —
# never the HTTP status itself. The previous version ended with
# `return "$code"`, and bash reads "000" as 0: every write that failed at the
# transport layer reported ✓ and counted as configured.
_api_request() {
    local method="$1" url="$2"; shift 2
    local args=()
    if [[ "$method" != "GET" ]]; then
        local content_type="$1" data="$2"; shift 2
        args+=(-X "$method" -H "Content-Type: $content_type")
        if [[ -n "$data" ]]; then args+=(--data "$data"); fi
    fi
    local h
    for h in "$@"; do args+=(-H "$h"); done
    # Dry run: reads go through so state checks are real; writes are reported
    # as done without being sent.
    if [[ "${DRY_RUN:-false}" == "true" && "$method" != "GET" ]]; then return 0; fi
    if ! _curl_capture "$url" "${args[@]}"; then
        if [[ $HTTP_RC -eq 28 ]]; then return 2; fi
        return 1
    fi
    if [[ "$HTTP_CODE" =~ ^2 ]]; then
        echo "$HTTP_BODY"
        return 0
    fi
    [[ "$method" != "GET" ]] && echo "$HTTP_BODY"
    verbose "$method $url → HTTP $HTTP_CODE"
    verbose "Response: $HTTP_BODY"
    return 1
}

api_get()  { _api_request GET  "$@"; }
api_post() { _api_request POST "$@"; }
api_put()  { _api_request PUT  "$@"; }

# Wait for a service to respond (default 180s wall-clock timeout, override with WAIT_TIMEOUT)
# 180s covers first-boot *arr DB migrations on slower NAS hardware.
# Accepts 2xx, 3xx, and 401 (auth required = service is up)
# Per-curl --max-time prevents one hung connection from eating the entire budget.
wait_for_service() {
    local name="$1" url="$2"
    local timeout=${WAIT_TIMEOUT:-180}
    local start=$SECONDS
    local deadline=$((SECONDS + timeout))
    local last_heartbeat=$SECONDS
    local code=""
    while (( SECONDS < deadline )); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 --connect-timeout 2 "$url" 2>/dev/null)
        if [[ "$code" =~ ^[23] ]] || [[ "$code" == "401" ]]; then
            return 0
        fi
        if (( SECONDS - last_heartbeat >= 10 )); then
            info "Still waiting for $name ($((SECONDS - start))s/${timeout}s, last HTTP: ${code:-none})..."
            last_heartbeat=$SECONDS
        fi
        sleep 1
    done
    fail "$name not responding after ${timeout}s at $url (last HTTP code: ${code:-none})"
    return 1
}

# ============================================
# qBittorrent auth
# ============================================

# Authenticate to qBittorrent and write session cookie to file.
# Returns 0 on success, 1 on failure.
#
# Usage:
#   qbit_auth "$QBIT_URL" "$QBIT_USERNAME" "$QBIT_PASSWORD" "$COOKIE_FILE"
#
# Note: pause-resume.sh (runs inside Alpine container via /bin/sh) cannot
# source this helper. See that script for its own inline auth implementation.
qbit_auth() {
    local url="$1" username="$2" password="$3" cookie_file="$4"
    local response http_code body
    response=$(curl -s -m 20 -w '\n%{http_code}' \
        -c "$cookie_file" \
        --data-urlencode "username=${username}" \
        --data-urlencode "password=${password}" \
        "${url}/api/v2/auth/login")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | head -1)

    # qBittorrent answers /auth/login three different ways:
    #   200 "Ok."    credentials accepted, session cookie issued
    #   200 "Fails." credentials rejected
    #   204          WebUI\AuthSubnetWhitelist covers the calling IP, so login
    #                was skipped entirely and no cookie was issued
    #
    # The 204 case is why this used to fail on the NAS: the whitelist covers
    # 10.10.0.0/24, so a perfectly good username and password came back 204
    # with an empty body and the old check — which demanded 200 and "Ok." —
    # reported an authentication failure.
    #
    # Do not read 204 as "credentials are correct". It isn't: a deliberately
    # wrong password returns 204 just the same, because nothing is checked.
    case "$http_code" in
        200) [[ "$body" == "Ok." ]] || return 1 ;;
        204) ;;
        *)   return 1 ;;
    esac

    # So confirm the API is genuinely usable rather than trusting the status
    # code. This is the part that can actually fail — on a 204 the cookie jar
    # is empty, and if the whitelist did not in fact authorise us this call
    # comes back 403 and we report failure instead of sailing on.
    local verify_code
    verify_code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' \
        -b "$cookie_file" "${url}/api/v2/app/version")
    [[ "$verify_code" == "200" ]]
}

# ============================================
# Bazarr settings
# ============================================

# POST settings to Bazarr's /api/system/settings.
#
# Bazarr only accepts flat form keys ("settings-<section>-<field>"). A nested
# JSON body is answered with HTTP 204 and then silently discarded, so a step
# written that way reports success, writes nothing, and runs again — with a
# container restart — on every single run.
#
# Verified on the NAS 2026-08-17:
#   {"sonarr": {"http_timeout": 61}}          → 204, value unchanged (60)
#   settings-sonarr-http_timeout=120          → 204, value changed to 120
#   settings-sonarr-http_timeout=61           → 406, "must is_in [60, 120, ...]"
# The 406 is the tell: flat keys reach Bazarr's validator, a JSON blob never does.
#
# Usage:
#   bazarr_settings_post "$BASE" "$AUTH" "settings-sonarr-ip=sonarr" "settings-sonarr-port=8989"
#
# Returns 0 on a 2xx, 2 if Bazarr gave no answer within BAZARR_POST_TIMEOUT
# seconds (default 60; API_MAX_TIME=<s> in front of one call overrides it),
# 1 on any other failure. On a timeout it prints the diagnosis itself, so
# callers keep the plain `if bazarr_settings_post …; then ok … else fail …`
# shape and every call site gets the same explanation.
#
# The timeout is there because Bazarr can hold a settings POST open forever.
# save_settings() in app/config.py applies each key in memory, writes
# config.yaml, and then — still inside the request — calls
# sonarr_signalr_client.restart() when use_sonarr or the Sonarr
# ip/port/base_url/ssl/apikey changed (radarr_signalr_client likewise). The
# client's start() is `while not started: try connection.start() except
# ConnectionError: sleep(5)` with no attempt limit, so when Bazarr cannot
# reach Sonarr or Radarr the handler never returns. Seen on the NAS 2026-09-10
# against a throwaway bazarr:1.6.0 with no Sonarr on its network. Because the
# write happens before the restart, a timed-out POST has usually landed and
# the next run compares the live settings and skips — but "usually": the same
# exit fires if the connect itself stalls, when nothing was sent.
#
# Bazarr does NOT restart its process on a settings POST (read from v1.6.0:
# the only restarts on that path are the two SignalR clients). Everything
# this script writes is live as soon as the POST returns, so there is no
# container bounce after the Bazarr section.
bazarr_settings_post() {
    local BASE="$1" AUTH="$2"; shift 2
    local args=(-X POST -H "$AUTH") kv
    for kv in "$@"; do args+=(--data-urlencode "$kv"); done

    # Dry run: never sent. A leaked POST would write config.yaml for real.
    if [[ "${DRY_RUN:-false}" == "true" ]]; then return 0; fi

    local max_time="${API_MAX_TIME:-$BAZARR_POST_TIMEOUT}"
    if ! API_MAX_TIME="$max_time" _curl_capture "${BASE}/api/system/settings" "${args[@]}"; then
        if [[ $HTTP_RC -eq 28 ]]; then
            info "  Bazarr gave no answer within ${max_time}s. The write may have landed — re-run to check."
            info "  If Bazarr cannot reach Sonarr/Radarr its settings handler blocks forever restarting its SignalR client (BAZARR_POST_TIMEOUT to adjust)."
            return 2
        fi
        return 1
    fi
    if [[ "$HTTP_CODE" =~ ^2 ]]; then return 0; fi
    verbose "POST ${BASE}/api/system/settings → HTTP $HTTP_CODE"
    verbose "Response: $HTTP_BODY"
    # A 406 names the field Bazarr's validator rejected — the one diagnostic
    # that has solved every wire-format problem here, so it is not gated on -v.
    if [[ "$HTTP_CODE" == "406" ]]; then info "  Bazarr rejected the settings (406): ${HTTP_BODY:0:200}"; fi
    return 1
}

# ============================================
# Custom formats
# ============================================

# Ensure a custom format exists and is scored in every quality profile.
#
# Usage:
#   ensure_custom_format "$BASE" "$AUTH" "Sonarr" "Reject ISO" -10000 "$specs_json"
#
# Idempotent on both halves: the format is created only when absent, and a
# quality profile is only PUT when its score for that format is missing or
# wrong. Existing specifications are left alone — if you change a regex here,
# update it in the running service too, or repo and live silently diverge.
ensure_custom_format() {
    local BASE="$1" AUTH="$2" name="$3" cf_name="$4" cf_score="$5" cf_specs="$6"

    local formats cf_id
    formats=$(api_get "${BASE}/api/v3/customformat" "$AUTH") || true
    cf_id=$(json_extract "$formats" "
ids = [c['id'] for c in data if c.get('name') == '''${cf_name}''']
print(ids[0] if ids else '')")

    if [[ -n "$cf_id" ]]; then
        skip "${name}: ${cf_name} custom format"
    else
        local cf_payload cf_result
        cf_payload="{\"name\":\"${cf_name}\",\"includeCustomFormatWhenRenaming\":false,\"specifications\":${cf_specs}}"
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            # No id comes back from a write that was never sent. -1 matches no
            # profile's formatItems, so the loop below reports every profile as
            # needing the score — which is exactly what a real run would do.
            cf_id=-1
        else
            cf_result=$(api_post "${BASE}/api/v3/customformat" "application/json" "$cf_payload" "$AUTH") || true
            cf_id=$(json_extract "$cf_result" "print(data.get('id', ''))")
        fi
        if [[ -n "$cf_id" ]]; then
            ok "${name}: added ${cf_name} custom format"
        else
            fail "${name}: add ${cf_name} custom format"
            return
        fi
    fi

    local profiles profile_ids
    profiles=$(api_get "${BASE}/api/v3/qualityprofile" "$AUTH") || true
    profile_ids=$(json_extract "$profiles" "
for p in data:
    print(p['id'])")

    local pid profile updated_profile
    for pid in $profile_ids; do
        profile=$(api_get "${BASE}/api/v3/qualityprofile/${pid}" "$AUTH") || continue
        # Skip if already scored correctly
        if json_extract "$profile" "
items = data.get('formatItems', [])
match = [i for i in items if i.get('format') == ${cf_id}]
sys.exit(0 if match and match[0].get('score') == ${cf_score} else 1)"; then
            continue
        fi
        updated_profile=$(json_extract "$profile" "
items = [i for i in data.get('formatItems', []) if i.get('format') != ${cf_id}]
items.insert(0, {'format': ${cf_id}, 'name': '''${cf_name}''', 'score': ${cf_score}})
data['formatItems'] = items
print(json.dumps(data))")
        if api_put "${BASE}/api/v3/qualityprofile/${pid}" "application/json" "$updated_profile" "$AUTH" >/dev/null 2>&1; then
            ok "${name}: scored ${cf_name} at ${cf_score} in profile ${pid}"
        else
            fail "${name}: score ${cf_name} in profile ${pid}"
        fi
    done
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
    # Sonarr/Radarr sit on the bridge; the clients listen inside gluetun's
    # namespace, so they are reached by gluetun's name, never `localhost`
    # (docs/MIGRATION-arr-off-vpn.md). Prowlarr, which shares that namespace,
    # is the one that uses localhost — see configure_prowlarr.
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
        {"name": "host", "value": "gluetun"},
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
        {"name": "host", "value": "gluetun"},
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
    ensure_custom_format "$BASE" "$AUTH" "$name" "Reject ISO" -10000 \
        '[{"name":"ISO","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"\\.iso$"}]}]'

    # --- Custom Formats: Dolby Vision profile handling ---
    #
    # Profile 5 encodes its base layer as IPT-PQ-C2, which is meaningless
    # unless a player applies the Dolby Vision RPU. Players that don't (the
    # Jellyfin Android TV client among them) render it with a green/magenta
    # cast — sharp picture, badly wrong colour. Profile 8.1 carries a standard
    # HDR10 base layer, so it degrades cleanly on any HDR10 display.
    #
    # Release titles are the only signal available here: *arr custom formats
    # cannot inspect the Dolby Vision configuration record. "DV" with no HDR
    # token means Profile 5; "DV" plus an HDR token means 8.1. Disc sources are
    # excluded from the penalty because UHD Blu-ray Dolby Vision is Profile 7,
    # whose base layer is HDR10-compatible — penalising those would trade good
    # remuxes for worse WEB rips.
    #
    # With minFormatScore at 0 the -1000 is a functional reject, not just a
    # preference: Profile 5 releases are refused and the next-best release is
    # taken instead.
    local dv_token='{"name":"Dolby Vision","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"\\b(dv|dovi|dolby[ .\\-_]?vision)\\b"}]}'
    local hdr_yes='{"name":"HDR10 base layer","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"\\bhdr|\\bhlg\\b|\\bpq\\b"}]}'
    local hdr_no='{"name":"No HDR10 fallback","implementation":"ReleaseTitleSpecification","negate":true,"required":true,"fields":[{"name":"value","value":"\\bhdr|\\bhlg\\b|\\bpq\\b"}]}'
    local disc_no='{"name":"Not a disc source","implementation":"ReleaseTitleSpecification","negate":true,"required":true,"fields":[{"name":"value","value":"\\b(blu-?ray|remux|bdrip|bdremux)\\b"}]}'

    ensure_custom_format "$BASE" "$AUTH" "$name" "DV (Profile 5)" -1000 \
        "[${dv_token},${hdr_no},${disc_no}]"
    ensure_custom_format "$BASE" "$AUTH" "$name" "DV HDR10 (Profile 8.1)" 500 \
        "[${dv_token},${hdr_yes}]"

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
