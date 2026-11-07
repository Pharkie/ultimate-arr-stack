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
# language-profile write does (BAZARR_SCAN_TIMEOUT, default 600 s), because
# Bazarr rescans the whole library inside that request. Before this, one
# hung handler held the script open forever (Bazarr's Sonarr/Radarr SignalR
# restart, 2026-09-10), and the same class exists for every *arr write that
# runs a connection test before answering.
API_TIMEOUT="${API_TIMEOUT:-60}"
BAZARR_SCAN_TIMEOUT="${BAZARR_SCAN_TIMEOUT:-600}"
for _t in API_TIMEOUT BAZARR_SCAN_TIMEOUT; do
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
    # API_MAX_TIME is read straight from the environment, so it gets the same
    # check the knobs get at load: "0" would tell curl "no limit".
    if ! [[ "$max_time" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: API_MAX_TIME must be a positive integer number of seconds, got '${max_time}'" >&2
        HTTP_RC=2
        return 1
    fi
    response=$(curl -s --connect-timeout 5 --max-time "$max_time" -w '\n%{http_code}' -o - "$@" "$url") || HTTP_RC=$?
    if [[ $HTTP_RC -ne 0 ]]; then
        if [[ $HTTP_RC -eq 28 ]]; then
            verbose "$url → no response within ${max_time}s (curl exit 28)"
        else
            verbose "$url → curl exit ${HTTP_RC}, no HTTP exchange"
        fi
        return 1
    fi
    # The write-out is the last line; everything before it is the body.
    HTTP_CODE=${response##*$'\n'}
    HTTP_BODY=${response%$'\n'*}
    return 0
}

# Usage: body=$(api_get "url" "header1" "header2" ...)
#        body=$(api_post "url" "application/json" '{"k":"v"}' "header1" ...)
#
# Returns 0 on a 2xx and 1 on anything else — never the HTTP status itself.
# The previous version ended with `return "$code"`, and bash reads "000" as
# 0: every write that failed at the transport layer reported ✓ and counted
# as configured. A timeout is a failure like any other here; HTTP_RC says
# which (28) for anyone who needs to know.
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
    if ! _curl_capture "$url" "${args[@]}"; then return 1; fi
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
# Returns 0 on a 2xx, 1 on any failure. On a timeout it prints the diagnosis
# itself — naming the bound that applied — so callers keep the plain
# `if bazarr_settings_post …; then ok … else fail …` shape and every call
# site gets the same explanation. The bound is API_TIMEOUT, or API_MAX_TIME
# when a call sets it (the language-profile write sets BAZARR_SCAN_TIMEOUT).
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

    local max_time="${API_MAX_TIME:-$API_TIMEOUT}"
    if ! _curl_capture "${BASE}/api/system/settings" "${args[@]}"; then
        if [[ $HTTP_RC -eq 28 ]]; then
            info "  Bazarr gave no answer within ${max_time}s. The write may have landed — re-run to check."
            if [[ "${API_MAX_TIME:-}" == "$BAZARR_SCAN_TIMEOUT" && "$max_time" == "$BAZARR_SCAN_TIMEOUT" ]]; then
                info "  This write makes Bazarr rescan the whole library before answering; BAZARR_SCAN_TIMEOUT raises the bound."
            else
                info "  If Bazarr cannot reach Sonarr/Radarr its handler blocks forever restarting its SignalR client; API_TIMEOUT raises the bound."
            fi
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

# The apprise URL for Bazarr's JSON notifier that posts to a Home Assistant
# webhook (HA_WEBHOOK_URL, http[s]://<host>:<port>/api/webhook/<id>) with the
# body every sender uses: {"title", "message", "level"}, as application/json.
#
# The ":" arguments are apprise's payload remaps. ":type=level" renames the
# message type (Bazarr always sends "info") to `level`; an empty value drops
# the key, so `version` and `attachments` go. Checked against the apprise
# 1.11.0 bundled in Bazarr 1.6.2, 2026-11-07: the payload came out as exactly
# {"title", "message", "level": "info"}.
#
# Prints the URL; returns 1 for anything that isn't a webhook URL.
bazarr_ha_notifier_url() {
    local url="$1" scheme rest
    case "$url" in
        http://*)  scheme=json;  rest="${url#http://}" ;;
        https://*) scheme=jsons; rest="${url#https://}" ;;
        *) return 1 ;;
    esac
    [[ "$rest" =~ ^[^/?#]+/api/webhook/[^/?#]+$ ]] || return 1
    echo "${scheme}://${rest}?:type=level&:version=&:attachments="
}

# Where Bazarr's JSON notifier stands against the URL it should have. Prints
#   MATCH        enabled, with exactly this URL
#   OFF          this URL, but switched off (by hand: the script never does)
#   FOREIGN      a URL that isn't a Home Assistant webhook
#   NO_JSON      no JSON notifier in this Bazarr at all
#   <fields>     what differs: "enabled", "url" or both
# and nothing when the settings don't parse.
bazarr_notifier_state() {
    local settings="$1" want="$2"
    json_extract "$settings" "
want = '''${want}'''
rows = [p for p in data['notifications']['providers'] if p.get('name') == 'JSON']
if not rows:
    print('NO_JSON'); sys.exit()
url, enabled = rows[0].get('url') or '', rows[0].get('enabled') is True
if url and '/api/webhook/' not in url:
    print('FOREIGN')
elif url == want:
    print('MATCH' if enabled else 'OFF')
else:
    print(' '.join(([] if enabled else ['enabled']) + ['url']))"
}

# Point Bazarr's notifications at the stack's Home Assistant webhook.
#
# Usage:
#   ensure_bazarr_ha_notifier "$BASE" "$AUTH" "$settings" "$HA_WEBHOOK_URL"
#
# The script owns Bazarr's JSON notifier while it points at a Home Assistant
# webhook, so a stale one is replaced: on one install it was
# json://homeassistant.lan:8123/…, which from inside a container is Traefik's
# macvlan (docs/REFERENCE.md), and every notification was refused. A JSON
# notifier pointed anywhere else is someone's own, and one switched off by
# hand stays off; both are left alone rather than fought on every run.
#
# Bazarr's settings POST updates the notifier row by name and answers 204
# whether or not a row matched, so the result is read back, not trusted.
ensure_bazarr_ha_notifier() {
    local BASE="$1" AUTH="$2" settings="$3" webhook="$4"

    local want host state
    if ! want=$(bazarr_ha_notifier_url "$webhook"); then
        fail "Bazarr: notifications — HA_WEBHOOK_URL is not an http(s)://<host>:<port>/api/webhook/<id> URL"
        return
    fi
    host="${want#*://}"; host="${host%%/*}"

    state=$(bazarr_notifier_state "$settings" "$want")
    case "$state" in
        MATCH)   skip "Bazarr: notifications to Home Assistant at ${host}"; return ;;
        OFF)     info "Bazarr: notifications to Home Assistant are switched off in Bazarr — left off"; return ;;
        FOREIGN) info "Bazarr: notifications — its JSON notifier points somewhere other than a Home Assistant webhook — left alone"; return ;;
        NO_JSON) fail "Bazarr: notifications — this Bazarr has no JSON notifier"; return ;;
        "")      fail "Bazarr: could not compare notification settings"; return ;;
    esac

    local row
    row=$(python3 -c 'import json, sys; print(json.dumps({"name": "JSON", "enabled": True, "url": sys.argv[1]}))' "$want")
    if ! bazarr_settings_post "$BASE" "$AUTH" "notifications-providers=${row}"; then
        fail "Bazarr: point notifications at Home Assistant"
        return
    fi
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        ok "Bazarr: point notifications at Home Assistant at ${host} (${state})"
        return
    fi

    local after
    after=$(bazarr_notifier_state "$(api_get "${BASE}/api/system/settings" "$AUTH" || true)" "$want")
    if [[ "$after" == "MATCH" ]]; then
        ok "Bazarr: pointed notifications at Home Assistant at ${host} (${state})"
    else
        fail "Bazarr: notifications — the write was accepted but the notifier reads back as '${after:-unreadable}'"
    fi
}

# ============================================
# Custom formats
# ============================================

# Release titles that mean HDR10+: an explicit tag, or a bare "HDR" from a
# service that streams HDR10+ (Amazon, Apple TV+, Paramount+). The (?<!\[)
# keeps the file's own name out of it. Sonarr and Radarr name a file
# "[HDR10Plus]" from its mediainfo, and a custom format matches the file name
# as well as the release title. If the name matched, a scene "HDR" file would
# score below the release it came from once imported, every other release
# would then look like an upgrade, and each would be downloaded in turn.
HDR10PLUS_TITLE_RE='(?<!\[)\bhdr10(\+|p\b|[ .\-_]?plus\b)|\b(amzn|atvp|pmtp)\b.*\bhdr\b|\bhdr\b.*\b(amzn|atvp|pmtp)\b'

# Release titles that put a dub ahead of English: the dub is named first
# ("iTA-ENG", "Ita.Eng", "[TR-EN]") or the release is marked DUAL. Groups
# name the tracks in their order, so an English-first release ("Eng.Rus",
# "Eng.Fre.Ger...") is left alone. The (?<!^) keeps a film called "Dual"
# from matching its own title. A file's own name carries no language, so a
# file scores what its release did.
FOREIGN_DUB_TITLE_RE='\b(ita|tr|tur|spa|esp|fre|fra|ger|rus|ukr|hin|pol|por)[ .\-_]+eng?\b|(?<!^)\bdual\b'

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

# Raise every quality profile's "Upgrade Until Custom Format Score" to at
# least the given score.
#
# Usage:
#   ensure_cutoff_format_score "$BASE" "$AUTH" "Sonarr" 500
#
# Only ever raises. A profile already set higher (configarr's until_score,
# say) is left alone, so this never fights a deliberate choice.
ensure_cutoff_format_score() {
    local BASE="$1" AUTH="$2" name="$3" cutoff="$4"

    local profiles profile_ids
    profiles=$(api_get "${BASE}/api/v3/qualityprofile" "$AUTH") || true
    profile_ids=$(json_extract "$profiles" "
for p in data:
    print(p['id'])")

    local pid profile updated_profile raised=0
    for pid in $profile_ids; do
        profile=$(api_get "${BASE}/api/v3/qualityprofile/${pid}" "$AUTH") || continue
        if json_extract "$profile" "sys.exit(0 if data.get('cutoffFormatScore', 0) >= ${cutoff} else 1)"; then
            continue
        fi
        raised=1
        updated_profile=$(json_extract "$profile" "
data['cutoffFormatScore'] = ${cutoff}
print(json.dumps(data))")
        if api_put "${BASE}/api/v3/qualityprofile/${pid}" "application/json" "$updated_profile" "$AUTH" >/dev/null 2>&1; then
            ok "${name}: profile ${pid} upgrades until custom format score ${cutoff}"
        else
            fail "${name}: raise profile ${pid}'s upgrade-until custom format score to ${cutoff}"
        fi
    done
    if [[ $raised -eq 0 ]]; then
        skip "${name}: upgrade until custom format score ${cutoff}"
    fi
}

# Set Settings → Media Management → "Propers and Repacks" to "Do not Prefer".
#
# Usage:
#   ensure_propers_not_preferred "$BASE" "$AUTH" "Sonarr"
#
# Any other mode compares a release's revision before its custom format score,
# so a PROPER outranks every score. The Repack/Proper formats scored in
# configure_arr_service rank repacks instead. Any other value is replaced,
# because no other mode lets those scores decide.
ensure_propers_not_preferred() {
    local BASE="$1" AUTH="$2" name="$3"

    local mm updated
    mm=$(api_get "${BASE}/api/v3/config/mediamanagement" "$AUTH") || true
    if ! json_extract "$mm" "sys.exit(0 if 'downloadPropersAndRepacks' in data else 1)"; then
        fail "${name}: read media management settings"
        return
    fi
    if json_extract "$mm" "sys.exit(0 if data['downloadPropersAndRepacks'] == 'doNotPrefer' else 1)"; then
        skip "${name}: propers and repacks ranked by score (Do not Prefer)"
        return
    fi
    updated=$(json_extract "$mm" "
data['downloadPropersAndRepacks'] = 'doNotPrefer'
print(json.dumps(data))")
    if api_put "${BASE}/api/v3/config/mediamanagement" "application/json" "$updated" "$AUTH" >/dev/null 2>&1; then
        ok "${name}: propers and repacks ranked by score (Do not Prefer)"
    else
        fail "${name}: set propers and repacks to Do not Prefer"
    fi
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

    local dv81_score=500
    ensure_custom_format "$BASE" "$AUTH" "$name" "DV (Profile 5)" -1000 \
        "[${dv_token},${hdr_no},${disc_no}]"
    ensure_custom_format "$BASE" "$AUTH" "$name" "DV HDR10 (Profile 8.1)" "$dv81_score" \
        "[${dv_token},${hdr_yes}]"

    # --- Custom Format: HDR10+ with no Dolby Vision ---
    #
    # HDR10+ sits on an HDR10 base layer, yet a display with HDR10 and no
    # HDR10+ doesn't get direct play: Jellyfin transcodes it, and on a Fire
    # TV Cube driving an LG BX that froze within seconds. With Dolby Vision
    # alongside, the player takes the DV and plays it.
    #
    # Titles rarely say so. Of 68 HDR10+-only files in one library, 2 titles
    # said HDR10+ and 66 said "HDR", so the streaming service is the second
    # signal: Amazon's "HDR" was HDR10+ 36 times in 37, Apple TV+'s and
    # Paramount+'s every time, Netflix's never. Scene titles name no service
    # and split 27 HDR10+ to 25 HDR10, so they are left alone, because
    # refusing them would refuse good HDR10 too. The Dolby Vision upgrade
    # below is the way out for those. Against that library this refuses 40 of
    # the 68 and one HDR10 file (an Amazon WEBRip re-encode), and nothing else.
    local dv_no='{"name":"No Dolby Vision","implementation":"ReleaseTitleSpecification","negate":true,"required":true,"fields":[{"name":"value","value":"\\b(dv|dovi|dolby[ .\\-_]?vision)\\b"}]}'
    local hdr10p_yes="{\"name\":\"HDR10+\",\"implementation\":\"ReleaseTitleSpecification\",\"negate\":false,\"required\":true,\"fields\":[{\"name\":\"value\",\"value\":\"${HDR10PLUS_TITLE_RE//\\/\\\\}\"}]}"
    ensure_custom_format "$BASE" "$AUTH" "$name" "HDR10+ (no DV)" -1000 \
        "[${hdr10p_yes},${dv_no}]"

    # --- Custom Format: foreign dub ahead of the English track (Radarr) ---
    #
    # Italian and Turkish groups (CYBER, NAHOM, TURG) re-release English
    # films with their own dub as the first and default audio track, their
    # forced subtitles on by default and, at times, English subtitles OCR'd
    # badly from the disc. A player starts the film in Italian. Against one
    # library of 192 films the title regex matched 25, every one of them with
    # a non-English default track, and no English-first release.
    #
    # Quality is ranked before score, so without this a dual-audio "BDRemux"
    # beats every English encode, and ties with a proper English remux at
    # score 0. With minFormatScore at 0 the -1000 refuses it outright.
    #
    # It goes by title, not by Radarr's Language condition. That condition
    # reads a file's languages from its mediainfo, which takes in the extra
    # dubs on ordinary English remuxes too (46 of the 192 films), so every
    # remux would score -1000 against an English-only release and be
    # upgraded again and again. Sonarr is left out: foreign-language shows
    # lead with their original track, which is the one wanted.
    if [[ "$name" == "Radarr" ]]; then
        local dub_first="{\"name\":\"Dub named before English, or DUAL\",\"implementation\":\"ReleaseTitleSpecification\",\"negate\":false,\"required\":true,\"fields\":[{\"name\":\"value\",\"value\":\"${FOREIGN_DUB_TITLE_RE//\\/\\\\}\"}]}"
        ensure_custom_format "$BASE" "$AUTH" "$name" "Foreign dub first" -1000 \
            "[${dub_first}]"
    fi

    # --- Keep upgrading until a file scores as Dolby Vision 8.1 ---
    #
    # The score above only ranks releases at grab time. Profiles are created
    # with an "Upgrade Until Custom Format Score" of 0, so a file that meets
    # the quality cutoff at score 0 is finished: when a Profile 8.1 release
    # turns up later, nothing replaces it. That stranded HDR10+-only 4K WEB
    # files, which a display with HDR10 but no HDR10+ can't direct-play.
    # Jellyfin transcodes or remuxes them instead, and on a Fire TV playback
    # froze within seconds, while the same episode as DV + HDR10+
    # direct-played.
    #
    # The format above refuses the releases whose titles give them away. The
    # rest say only "HDR", and their HDR10+ metadata shows up in the file's
    # own mediainfo only after import. For those, upgrading on the Dolby
    # Vision score is the lever that works.
    #
    # It can't loop. An upgrade must raise the score, and the only formats
    # scored above 0 are 8.1 and the repack formats below, which score less
    # than 8.1 does. So a file climbs at most a few steps, and an 8.1 file sits
    # at the cutoff and stays there. A file scores at least what its release
    # did (the formats match the stored release title as well as the file
    # name), so importing never drops it back below a release it came from.
    ensure_cutoff_format_score "$BASE" "$AUTH" "$name" "$dv81_score"

    # --- Propers and repacks: ranked by score, below Dolby Vision 8.1 ---
    #
    # The default "Prefer and Upgrade" compares a release's revision before
    # any custom format score. For an episode of an Apple TV+ show Sonarr
    # grabbed a scene PROPER titled only "HDR" (score 0: a scene title names
    # no service, so the HDR10+ format above can't judge it) over seven Dolby
    # Vision 8.1 releases at 500. Had it imported, no 8.1 release could
    # replace it: a lower revision is refused before scores are compared, so
    # the cutoff above never gets a say. "Do not Prefer" with the repacks
    # scored is the TRaSH set-up: a repack beats its own release and loses to
    # 8.1. Score the formats first, so repacks are never left with no
    # preference at all.
    ensure_custom_format "$BASE" "$AUTH" "$name" "Repack/Proper" 5 \
        '[{"name":"Repack/Proper/Rerip","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"\\b(Repack|Proper|Rerip)\\b"}]},{"name":"Not Higher Version Repack/Proper","implementation":"ReleaseTitleSpecification","negate":true,"required":true,"fields":[{"name":"value","value":"\\b((repack|proper)[23])\\b|\\bREAL\\.(REAL\\.)?(PROPER|REPACK)\\b"}]}]'
    ensure_custom_format "$BASE" "$AUTH" "$name" "Repack2" 6 \
        '[{"name":"Repack/Proper 2 or REAL.PROPER/REPACK","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"\\b((repack|proper)2)\\b|\\b(REAL\\.(PROPER|REPACK))\\b"}]},{"name":"Not Repack/Proper 3","implementation":"ReleaseTitleSpecification","negate":true,"required":true,"fields":[{"name":"value","value":"\\b((repack|proper)3)\\b|\\bREAL\\.(REAL\\.)(PROPER|REPACK)\\b"}]}]'
    ensure_custom_format "$BASE" "$AUTH" "$name" "Repack3" 7 \
        '[{"name":"Repack/Proper 3 or REAL.REAL.PROPER/REPACK","implementation":"ReleaseTitleSpecification","negate":false,"required":true,"fields":[{"name":"value","value":"\\b((repack|proper)3)\\b|\\b(REAL\\.REAL\\.(PROPER|REPACK))\\b"}]}]'
    ensure_propers_not_preferred "$BASE" "$AUTH" "$name"

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
