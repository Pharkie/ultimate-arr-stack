#!/usr/bin/env bats
# Unit tests for the HTTP layer in scripts/lib/configure-helpers.sh.
#
# Every write configure-apps.sh makes goes through _api_request or
# bazarr_settings_post, and until now neither had a test — which is how
# `return "$code"` shipped: bash reads curl's "000" as exit 0, so a refused
# connection printed ✓. These stub `curl` as a shell function (it wins over
# the binary) and check the exit codes and the words a user would see.
# No NAS, no network.

setup() {
    load helpers/setup
    HELPERS="$REPO_ROOT/scripts/lib/configure-helpers.sh"
    CALLS="$BATS_TEST_TMPDIR/curl-calls"
    : > "$CALLS"
    # Counters the output helpers increment.
    CONFIGURED=0; SKIPPED=0; FAILED=0; WOULD=0
    unset DRY_RUN VERBOSE API_MAX_TIME
    # The helpers and bats-support both define fail(). Sourced last, the
    # helpers' one (print ✗, count, return 0) used to win for the assertions
    # too, so no assert_* or refute_* in this file could ever fail. Keep both
    # and pick by caller: anything under bats-assert (which fails from inner
    # helpers such as __assert_stream) gets bats-support's, the code under
    # test gets its own.
    eval "$(declare -f fail | sed '1s/^fail /bats_support_fail /')"
    # shellcheck disable=SC1090
    source "$HELPERS"
    eval "$(declare -f fail | sed '1s/^fail /helpers_fail /')"
    fail() {
        local caller
        for caller in "${FUNCNAME[@]:1}"; do
            case "$caller" in
                assert_*|refute_*|__assert_*|__refute_*) bats_support_fail "$@"; return ;;
            esac
        done
        helpers_fail "$@"
    }
}

# curl stub: STUB_RC is the exit code, STUB_OUT what curl writes to stdout
# (body then the -w write-out line). Records each call so a test can assert
# that nothing was sent.
stub_curl() {
    STUB_RC="$1"; STUB_OUT="$2"
    curl() {
        echo "$*" >> "$CALLS"
        printf '%s' "$STUB_OUT"
        return "$STUB_RC"
    }
}

# ---- _api_request ----------------------------------------------------------

@test "api_post: connection refused (curl 7, write-out 000) is a failure, not a ✓" {
    stub_curl 7 $'\n000'
    run api_post "http://x/api/v3/rootfolder" "application/json" '{"path":"/x"}' "X-Api-Key: k"
    assert_failure
    [ "$status" -eq 1 ]
}

@test "api_post: timeout (curl 28) is a failure, and HTTP_RC records why" {
    stub_curl 28 ""
    run api_post "http://x/api/v3/rootfolder" "application/json" '{}' "X-Api-Key: k"
    [ "$status" -eq 1 ]
    api_post "http://x/api/v3/rootfolder" "application/json" '{}' "X-Api-Key: k" >/dev/null || true
    [ "$HTTP_RC" -eq 28 ]
}

@test "api_post: 2xx returns 0 and echoes the body" {
    stub_curl 0 $'{"id":1}\n201'
    run api_post "http://x/api/v3/rootfolder" "application/json" '{}' "X-Api-Key: k"
    assert_success
    assert_output '{"id":1}'
}

@test "api_post: 4xx returns 1 (never the HTTP code) and echoes the body" {
    stub_curl 0 $'{"error":"bad"}\n400'
    run api_post "http://x/api/v3/rootfolder" "application/json" '{}' "X-Api-Key: k"
    [ "$status" -eq 1 ]
    assert_output '{"error":"bad"}'
}

@test "api_get: 401 returns 1 with no body" {
    stub_curl 0 $'<html>login</html>\n401'
    run api_get "http://x/api/v3/system/status" "X-Api-Key: k"
    [ "$status" -eq 1 ]
    assert_output ''
}

@test "api_post: dry run sends nothing and returns 0" {
    stub_curl 7 $'\n000'
    DRY_RUN=true
    run api_post "http://x/api/v3/rootfolder" "application/json" '{}' "X-Api-Key: k"
    assert_success
    [ ! -s "$CALLS" ]
}

@test "api_get: dry run still reads" {
    stub_curl 0 $'[]\n200'
    DRY_RUN=true
    run api_get "http://x/api/v3/rootfolder" "X-Api-Key: k"
    assert_success
    [ -s "$CALLS" ]
}

@test "_curl_capture: every request carries --connect-timeout and --max-time" {
    stub_curl 0 $'\n200'
    api_get "http://x/" "H: v" >/dev/null
    grep -q -- '--connect-timeout 5' "$CALLS"
    grep -q -- '--max-time 60' "$CALLS"
}

@test "_curl_capture: API_MAX_TIME in front of one call raises its bound only" {
    stub_curl 0 $'\n200'
    API_MAX_TIME=600 api_get "http://x/" "H: v" >/dev/null
    grep -q -- '--max-time 600' "$CALLS"
    : > "$CALLS"
    api_get "http://x/" "H: v" >/dev/null
    grep -q -- '--max-time 60' "$CALLS"
}

@test "_curl_capture: an invalid API_MAX_TIME is refused before curl runs (0 would mean no limit)" {
    stub_curl 0 $'\n200'
    run env API_MAX_TIME=0 bash -c "source '$HELPERS'; api_get http://x/ 'H: v'"
    assert_failure
    assert_output --partial "API_MAX_TIME must be a positive integer"
    run env API_MAX_TIME=90s bash -c "source '$HELPERS'; api_get http://x/ 'H: v'"
    assert_failure
}

# ---- bazarr_settings_post --------------------------------------------------

@test "bazarr_settings_post: timeout fails and says so, hedged, naming the bound that applied" {
    stub_curl 28 ""
    run bazarr_settings_post "http://x" "X-API-KEY: k" "settings-general-use_sonarr=true"
    assert_failure
    assert_output --partial "gave no answer within 60s"
    assert_output --partial "may have landed"
    assert_output --partial "API_TIMEOUT raises the bound"
}

@test "bazarr_settings_post: the language-profile write's timeout names BAZARR_SCAN_TIMEOUT, not the general knob" {
    stub_curl 28 ""
    run env API_MAX_TIME=600 bash -c "source '$HELPERS'; $(declare -f curl); STUB_RC=28 STUB_OUT=''; CALLS=/dev/null; bazarr_settings_post http://x 'X-API-KEY: k' languages-enabled=en"
    assert_failure
    assert_output --partial "gave no answer within 600s"
    assert_output --partial "BAZARR_SCAN_TIMEOUT raises the bound"
    refute_output --partial "API_TIMEOUT raises"
}

@test "bazarr_settings_post: uses the raised bound when a call asks for it" {
    stub_curl 0 $'\n204'
    API_MAX_TIME=600 bazarr_settings_post "http://x" "X-API-KEY: k" "languages-enabled=en" >/dev/null
    grep -q -- '--max-time 600' "$CALLS"
}

@test "bazarr_settings_post: 406 returns 1 and shows the validator's message without -v" {
    stub_curl 0 $'must is_type_of <class \'bool\'>\n406'
    run bazarr_settings_post "http://x" "X-API-KEY: k" "settings-sonarr-ssl=True"
    [ "$status" -eq 1 ]
    assert_output --partial "406"
    assert_output --partial "is_type_of"
}

@test "bazarr_settings_post: connection refused fails without the timeout advice" {
    stub_curl 7 $'\n000'
    run bazarr_settings_post "http://x" "X-API-KEY: k" "settings-general-use_sonarr=true"
    [ "$status" -eq 1 ]
    refute_output --partial "gave no answer"
}

@test "bazarr_settings_post: 2xx returns 0" {
    stub_curl 0 $'\n204'
    run bazarr_settings_post "http://x" "X-API-KEY: k" "settings-general-use_sonarr=true"
    assert_success
}

@test "bazarr_settings_post: dry run sends nothing" {
    stub_curl 0 $'\n204'
    DRY_RUN=true
    run bazarr_settings_post "http://x" "X-API-KEY: k" "settings-general-use_sonarr=true"
    assert_success
    [ ! -s "$CALLS" ]
}

# ---- ensure_bazarr_ha_notifier ---------------------------------------------

HA_HOOK="http://192.0.2.20:8123/api/webhook/arr-stack-notify-test"
HA_JSON="json://192.0.2.20:8123/api/webhook/arr-stack-notify-test?:type=level&:version=&:attachments="

# Bazarr settings with one other notifier and a JSON one with this url
# ("null" for none) and enabled flag.
bazarr_notifiers() {
    python3 -c '
import json, sys
url = None if sys.argv[1] == "null" else sys.argv[1]
print(json.dumps({"notifications": {"providers": [
    {"name": "Discord", "enabled": False, "url": None},
    {"name": "JSON", "enabled": sys.argv[2] == "true", "url": url}]}}))' "$1" "$2"
}

# Each settings POST's arguments recorded one per line; the read-back
# serves READBACK.
stub_notifier_write() {
    READBACK="$1"
    bazarr_settings_post() { shift 2; printf '%s\n' "$@" >> "$CALLS"; }
    api_get() { printf '%s' "$READBACK"; }
}

@test "bazarr_ha_notifier_url: the webhook becomes a JSON notifier that sends title, message and level" {
    run bazarr_ha_notifier_url "$HA_HOOK"
    assert_success
    assert_output "$HA_JSON"
    run bazarr_ha_notifier_url "https://ha.example.invalid/api/webhook/abc"
    assert_output "jsons://ha.example.invalid/api/webhook/abc?:type=level&:version=&:attachments="
}

@test "bazarr_ha_notifier_url: refuses anything that isn't a webhook URL" {
    local bad
    for bad in "" "192.0.2.20:8123/api/webhook/x" "http://192.0.2.20:8123/api/webhook/" \
        "http://192.0.2.20:8123/api/services/x" "http://192.0.2.20:8123/api/webhook/x?y=1"; do
        run bazarr_ha_notifier_url "$bad"
        assert_failure
        assert_output ""
    done
}

@test "ensure_bazarr_ha_notifier: replaces a stale .lan webhook, and reads it back" {
    stub_notifier_write "$(bazarr_notifiers "$HA_JSON" true)"
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" \
        "$(bazarr_notifiers "json://homeassistant.lan:8123/api/webhook/old" true)" "$HA_HOOK"
    assert_success
    assert_output "  ✓ Bazarr: pointed notifications at Home Assistant at 192.0.2.20:8123 (url)"
    [ "$(wc -l < "$CALLS")" -eq 1 ]
    run python3 -c '
import json, sys
key, _, row = open(sys.argv[1]).read().strip().partition("=")
row = json.loads(row)
print(key, row["name"], row["enabled"] is True, row["url"] == sys.argv[2])' "$CALLS" "$HA_JSON"
    assert_output "notifications-providers JSON True True"
}

@test "ensure_bazarr_ha_notifier: a fresh Bazarr's notifier (off, no URL) is switched on" {
    stub_notifier_write "$(bazarr_notifiers "$HA_JSON" true)"
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" "$(bazarr_notifiers null false)" "$HA_HOOK"
    assert_output "  ✓ Bazarr: pointed notifications at Home Assistant at 192.0.2.20:8123 (enabled url)"
}

@test "ensure_bazarr_ha_notifier: already pointing at the webhook is one skip and no write" {
    stub_notifier_write ""
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" "$(bazarr_notifiers "$HA_JSON" true)" "$HA_HOOK"
    assert_output "  - Bazarr: notifications to Home Assistant at 192.0.2.20:8123 (already configured)"
    [ ! -s "$CALLS" ]
}

@test "ensure_bazarr_ha_notifier: switched off by hand stays off" {
    stub_notifier_write ""
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" "$(bazarr_notifiers "$HA_JSON" false)" "$HA_HOOK"
    assert_output --partial "switched off in Bazarr — left off"
    [ ! -s "$CALLS" ]
}

@test "ensure_bazarr_ha_notifier: a JSON notifier pointed somewhere else is left alone" {
    stub_notifier_write ""
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" \
        "$(bazarr_notifiers "json://my-own-thing.example.invalid/hook" true)" "$HA_HOOK"
    assert_output --partial "left alone"
    refute_output --partial "✓"
    [ ! -s "$CALLS" ]
}

@test "ensure_bazarr_ha_notifier: a write that reads back unchanged is a ✗, not a ✓" {
    local old
    old=$(bazarr_notifiers "json://homeassistant.lan:8123/api/webhook/old" true)
    stub_notifier_write "$old"
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" "$old" "$HA_HOOK"
    assert_output "  ✗ Bazarr: notifications — the write was accepted but the notifier reads back as 'url'"
}

@test "ensure_bazarr_ha_notifier: a refused write is a ✗, not a ✓" {
    stub_notifier_write "$(bazarr_notifiers "$HA_JSON" true)"
    bazarr_settings_post() { return 1; }
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" "$(bazarr_notifiers null false)" "$HA_HOOK"
    assert_output "  ✗ Bazarr: point notifications at Home Assistant"
}

@test "ensure_bazarr_ha_notifier: dry run says what it would change and sends nothing" {
    stub_curl 0 $'\n204'
    api_get() { echo "read-back" >> "$CALLS"; }
    DRY_RUN=true
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" "$(bazarr_notifiers null false)" "$HA_HOOK"
    assert_output "  [dry-run] Would: Bazarr: point notifications at Home Assistant at 192.0.2.20:8123 (enabled url)"
    [ ! -s "$CALLS" ]
}

@test "ensure_bazarr_ha_notifier: no JSON notifier, a bad webhook or unreadable settings are a ✗ and nothing is written" {
    stub_notifier_write ""
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" '{"notifications": {"providers": []}}' "$HA_HOOK"
    assert_output "  ✗ Bazarr: notifications — this Bazarr has no JSON notifier"
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" "$(bazarr_notifiers null false)" "http://homeassistant.lan:8123/"
    assert_output --partial "HA_WEBHOOK_URL is not an http(s)://"
    run ensure_bazarr_ha_notifier "http://x" "X-API-KEY: k" '{}' "$HA_HOOK"
    assert_output "  ✗ Bazarr: could not compare notification settings"
    [ ! -s "$CALLS" ]
}

# ---- timeout knobs ---------------------------------------------------------

@test "sourcing the helpers refuses a timeout knob that is not a positive integer" {
    local bad
    for bad in 'API_TIMEOUT=0' 'API_TIMEOUT=90s' 'BAZARR_SCAN_TIMEOUT=abc'; do
        run bash -c "$bad source '$HELPERS'"
        assert_failure
        assert_output --partial "must be a positive integer"
    done
}

# ---- ensure_cutoff_format_score --------------------------------------------

# Profiles served by a stubbed api_get, one JSON file per id, and every PUT
# recorded as "<url> <body>" so a test can read back exactly what was sent.
stub_profiles() {
    PROFILES="$BATS_TEST_TMPDIR/profiles"
    mkdir -p "$PROFILES"
    local spec id score
    for spec in "$@"; do
        id=${spec%%:*}; score=${spec#*:}
        printf '{"id":%s,"name":"p%s","cutoffFormatScore":%s,"formatItems":[]}' "$id" "$id" "$score" > "$PROFILES/$id"
    done
    api_get() {
        case "$1" in
            */qualityprofile) python3 -c 'import json,os,sys; d=sys.argv[1]; print(json.dumps([json.load(open(os.path.join(d,f))) for f in sorted(os.listdir(d))]))' "$PROFILES" ;;
            */qualityprofile/*) cat "$PROFILES/${1##*/}" ;;
        esac
    }
    api_put() { echo "$1 $3" >> "$CALLS"; }
}

@test "ensure_cutoff_format_score: raises a profile below the score and sends the rest of it unchanged" {
    stub_profiles 1:0
    run ensure_cutoff_format_score "http://x" "X-Api-Key: k" "Sonarr" 500
    assert_success
    assert_output --partial "profile 1 upgrades until custom format score 500"
    [ "$(wc -l < "$CALLS")" -eq 1 ]
    run python3 -c 'import json,sys; url,body=open(sys.argv[1]).read().split(" ",1); d=json.loads(body); print(url, d["cutoffFormatScore"], d["name"], d["formatItems"])' "$CALLS"
    assert_output "http://x/api/v3/qualityprofile/1 500 p1 []"
}

@test "ensure_cutoff_format_score: never lowers a profile set higher on purpose" {
    stub_profiles 1:0 2:10000 3:500
    run ensure_cutoff_format_score "http://x" "X-Api-Key: k" "Radarr" 500
    assert_success
    [ "$(wc -l < "$CALLS")" -eq 1 ]
    run cut -d' ' -f1 "$CALLS"
    assert_output "http://x/api/v3/qualityprofile/1"
}

@test "ensure_cutoff_format_score: every profile already there is one skip and no write" {
    stub_profiles 1:500 2:10000
    run ensure_cutoff_format_score "http://x" "X-Api-Key: k" "Sonarr" 500
    assert_success
    assert_output "  - Sonarr: upgrade until custom format score 500 (already configured)"
    [ ! -s "$CALLS" ]
}

@test "ensure_cutoff_format_score: a refused write is a ✗, not a ✓" {
    stub_profiles 1:0
    api_put() { return 1; }
    run ensure_cutoff_format_score "http://x" "X-Api-Key: k" "Sonarr" 500
    assert_output --partial "✗ Sonarr: raise profile 1's upgrade-until custom format score to 500"
    refute_output --partial "✓"
}

# ---- ensure_propers_not_preferred ------------------------------------------

# Media management settings served by a stubbed api_get, and every PUT
# recorded as "<url> <body>".
stub_mediamanagement() {
    MM="$1"
    api_get() { case "$1" in */config/mediamanagement) printf '%s' "$MM" ;; esac; }
    api_put() { echo "$1 $3" >> "$CALLS"; }
}

@test "ensure_propers_not_preferred: switches Prefer and Upgrade to Do not Prefer and sends the rest unchanged" {
    stub_mediamanagement '{"id":1,"downloadPropersAndRepacks":"preferAndUpgrade","recycleBin":"/r"}'
    run ensure_propers_not_preferred "http://x" "X-Api-Key: k" "Sonarr"
    assert_success
    assert_output "  ✓ Sonarr: propers and repacks ranked by score (Do not Prefer)"
    [ "$(wc -l < "$CALLS")" -eq 1 ]
    run python3 -c 'import json,sys; url,body=open(sys.argv[1]).read().split(" ",1); d=json.loads(body); print(url, d["downloadPropersAndRepacks"], d["id"], d["recycleBin"])' "$CALLS"
    assert_output "http://x/api/v3/config/mediamanagement doNotPrefer 1 /r"
}

@test "ensure_propers_not_preferred: replaces Do not Upgrade too, which still ranks a PROPER first at grab time" {
    stub_mediamanagement '{"id":1,"downloadPropersAndRepacks":"doNotUpgrade"}'
    run ensure_propers_not_preferred "http://x" "X-Api-Key: k" "Radarr"
    assert_success
    [ "$(wc -l < "$CALLS")" -eq 1 ]
}

@test "ensure_propers_not_preferred: already Do not Prefer is one skip and no write" {
    stub_mediamanagement '{"id":1,"downloadPropersAndRepacks":"doNotPrefer"}'
    run ensure_propers_not_preferred "http://x" "X-Api-Key: k" "Sonarr"
    assert_success
    assert_output "  - Sonarr: propers and repacks ranked by score (Do not Prefer) (already configured)"
    [ ! -s "$CALLS" ]
}

@test "ensure_propers_not_preferred: settings it can't read are a ✗ and nothing is written" {
    stub_mediamanagement ''
    run ensure_propers_not_preferred "http://x" "X-Api-Key: k" "Sonarr"
    assert_output "  ✗ Sonarr: read media management settings"
    [ ! -s "$CALLS" ]
}

@test "ensure_propers_not_preferred: a refused write is a ✗, not a ✓" {
    stub_mediamanagement '{"id":1,"downloadPropersAndRepacks":"preferAndUpgrade"}'
    api_put() { return 1; }
    run ensure_propers_not_preferred "http://x" "X-Api-Key: k" "Sonarr"
    assert_output "  ✗ Sonarr: set propers and repacks to Do not Prefer"
    refute_output --partial "✓"
}

@test "configure_arr_service scores the repack formats below Dolby Vision 8.1, then stops preferring propers" {
    # With a repack at or above 8.1, "Do not Prefer" would bring back the
    # PROPER-over-Dolby-Vision grab it is there to stop. Switching the mode
    # before the repacks are scored would leave a window with no preference.
    wait_for_service() { return 0; }
    api_get() { echo '[]'; }
    api_post() { echo '{}'; }
    api_put() { return 0; }
    ensure_cutoff_format_score() { :; }
    ensure_custom_format() { printf '%s\t%s\t%s\n' "$4" "$5" "$6" >> "$CALLS"; }
    ensure_propers_not_preferred() { printf 'PROPERS\t\t\n' >> "$CALLS"; }
    NAS_IP=x SABNZBD_RUNNING=false
    run configure_arr_service Sonarr 8989 k /data/media/tv tv renameEpisodes "" "{}"
    run python3 -c '
import sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])]
names = [r[0] for r in rows]
scores = {r[0]: int(r[1]) for r in rows if r[1]}
dv81 = scores["DV HDR10 (Profile 8.1)"]
below = all(s < dv81 for n, s in scores.items() if n != "DV HDR10 (Profile 8.1)")
after = names.index("PROPERS") > max(names.index(n) for n in ("Repack/Proper", "Repack2", "Repack3"))
print(scores["Repack/Proper"], scores["Repack2"], scores["Repack3"], below, after)
' "$CALLS"
    assert_output "5 6 7 True True"
}

@test "Repack formats: each revision matches exactly one of Repack/Proper, Repack2 and Repack3" {
    # Two matching at once would add their scores, and none matching would
    # leave a PROPER at 0 with "Do not Prefer" set, never replacing its own
    # release. Every condition is Required, so a format matches when each
    # condition does (Negate flips one), case-insensitively, as in Sonarr.
    wait_for_service() { return 0; }
    api_get() { echo '[]'; }
    api_post() { echo '{}'; }
    api_put() { return 0; }
    ensure_cutoff_format_score() { :; }
    ensure_propers_not_preferred() { :; }
    ensure_custom_format() { printf '%s\t%s\n' "$4" "$6" >> "$CALLS"; }
    NAS_IP=x SABNZBD_RUNNING=false
    run configure_arr_service Sonarr 8989 k /data/media/tv tv renameEpisodes "" "{}"
    run python3 -c '
import json, re, sys
formats = {}
for line in open(sys.argv[1]):
    name, specs = line.rstrip("\n").split("\t")
    if name.startswith("Repack"):
        formats[name] = json.loads(specs)
def matches(specs, title):
    return all(bool(re.search(s["fields"][0]["value"], title, re.I)) != s["negate"] for s in specs)
for tag in ["PROPER", "REPACK", "RERIP", "REPACK2", "REAL.PROPER", "PROPER3", "REAL.REAL.REPACK", ""]:
    title = "Show.S01E01." + (tag + "." if tag else "") + "1080p.WEB.h264-GRP"
    print(tag or "none", [n for n, specs in formats.items() if matches(specs, title)])
' "$CALLS"
    assert_output "PROPER ['Repack/Proper']
REPACK ['Repack/Proper']
RERIP ['Repack/Proper']
REPACK2 ['Repack2']
REAL.PROPER ['Repack2']
PROPER3 ['Repack3']
REAL.REAL.REPACK ['Repack3']
none []"
}

@test "configure_arr_service upgrades until the Dolby Vision 8.1 score, whatever that score is" {
    # The cutoff must track the 8.1 score: set below it, an 8.1 release never
    # replaces a file at 0; set above it, a future positive format would let
    # files upgrade with no end point.
    run grep -E 'ensure_custom_format .*"DV HDR10 \(Profile 8\.1\)" "\$dv81_score"' "$HELPERS"
    assert_success
    run grep -E 'ensure_cutoff_format_score "\$BASE" "\$AUTH" "\$name" "\$dv81_score"' "$HELPERS"
    assert_success
}

# ---- HDR10+ (no DV) --------------------------------------------------------

# Sonarr and Radarr match a release-title condition case-insensitively against
# the release title or the file name. The constructs the regex uses (\b, a
# lookbehind, alternation) behave the same in .NET and in Python's re.
hdr10plus_title() {
    python3 -c 'import re, sys; print("match" if re.search(sys.argv[1], sys.argv[2], re.I) else "no match")' "$HDR10PLUS_TITLE_RE" "$1"
}

@test "HDR10+ (no DV): matches a title that names HDR10+, or HDR from a service that streams HDR10+" {
    local t
    for t in \
        "Show.S01E01.2160p.WEB-DL.HDR10+.H265-GRP" \
        "Show.S01E01.2160p.WEB-DL.DDP5.1.HDR10P.H.265-GRP" \
        "Film.2025.UHD.BluRay.2160p.DDP.5.1.HDR10Plus.x265-GRP" \
        "Show.S01E01.2160p.AMZN.WEB-DL.DDP5.1.HDR.H.265-NTb" \
        "Show.S01E01.2160p.REPACK.HDR.AMZN.WEBRip.DDP5.1.x265-GRP" \
        "Show S01E02 2026 2160p ATVP WEB-DL DDP5 1 Atmos HDR H 265-GRP" \
        "Show.S04E04.2160p.PMTP.WEB-DL.DDP5.1.HDR.HEVC-NTb"; do
        run hdr10plus_title "$t"
        assert_output "match"
    done
}

@test "HDR10+ (no DV): leaves Netflix, scene, explicit HDR10 and SDR titles alone" {
    local t
    for t in \
        "Show.S01E01.2160p.NF.WEB-DL.DDP5.1.HDR.HEVC-NTb" \
        "show.s01e01.hdr.2160p.web.h265-cakes" \
        "Show.S01E01.2160p.AMZN.WEB-DL.DDP5.1.HDR10.H.265-GRP" \
        "Show.S01E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-GRP"; do
        run hdr10plus_title "$t"
        assert_output "no match"
    done
}

@test "HDR10+ (no DV): a file's own [HDR10Plus] name never matches, so a file never scores below its release" {
    # If it did, a scene "HDR" file would drop to -1000 once renamed, and
    # every other release of the episode would look like an upgrade.
    local t
    for t in \
        "Show (2026) - S01E01 - Pilot [WEBDL-2160p][EAC3 5.1][HDR10Plus][h265]-cakes.mkv" \
        "Show (2026) - S01E01 - Pilot [AMZN][WEBDL-2160p][EAC3 5.1][HDR10Plus][h265]-GRP.mkv" \
        "Film (2025) - [AMZN][WEBDL-2160p][EAC3 5.1][HDR10][h265]-GRP.mkv"; do
        run hdr10plus_title "$t"
        assert_output "no match"
    done
}

@test "configure_arr_service sends the HDR10+ regex intact, with Dolby Vision negated, at -1000" {
    # Run the whole function against stubs and catch what it asks for.
    wait_for_service() { return 0; }
    api_get() { echo '[]'; }
    api_post() { echo '{}'; }
    api_put() { return 0; }
    ensure_cutoff_format_score() { :; }
    ensure_custom_format() { printf '%s\t%s\t%s\n' "$4" "$5" "$6" >> "$CALLS"; }
    NAS_IP=x SABNZBD_RUNNING=false
    run configure_arr_service Sonarr 8989 k /data/media/tv tv renameEpisodes "" "{}"
    run python3 -c '
import json, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])]
name, score, specs = [r for r in rows if r[0] == "HDR10+ (no DV)"][0]
specs = json.loads(specs)
hdr, dv = specs
print(score, hdr["fields"][0]["value"] == sys.argv[2], hdr["required"], hdr["negate"], dv["required"], dv["negate"], dv["fields"][0]["value"])
' "$CALLS" "$HDR10PLUS_TITLE_RE"
    assert_output '-1000 True True False True True \b(dv|dovi|dolby[ .\-_]?vision)\b'
}

# ---- Foreign dub first (Radarr) ---------------------------------------------

foreign_dub_title() {
    python3 -c 'import re, sys; print("match" if re.search(sys.argv[1], sys.argv[2], re.I) else "no match")' "$FOREIGN_DUB_TITLE_RE" "$1"
}

@test "Foreign dub first: matches a release that names its dub before English, or is marked DUAL" {
    # Real titles from one library, each with the dub as the default track.
    local t
    for t in \
        "X2.2003.4K.HDR.2160p.BDRemux.Ita.Eng.x265-NAHOM" \
        "Dune.Parte.Due.2024.iTA-ENG.Bluray.2160p.HEVC.HDR.x265-CYBER" \
        "Spider-Man.Brand.New.Day.2026.2160p.WEB-DL.x265-TurkSeeD [TR-EN]" \
        "The.Mongoose.2026.2160p.AMZN.WEB-DL.DUAL.DDP5.1.DoVi.HDR.H.265-TURG" \
        "X-Men.2.2003.DL.Esp.Eng.DTS.1080p.BDrip-RadeonHD" \
        "[02] X2 (2003) BDRip 1080p H.265 [UKR_ENG] [Hurtom]"; do
        run foreign_dub_title "$t"
        assert_output "match"
    done
}

@test "Foreign dub first: leaves English-first releases, remuxes with extra dubs and a film called Dual alone" {
    local t
    for t in \
        "X-Men.2000.Eng.Fre.Ger.Ita.Spa.Cze.Pol.Jpn.2160p.BluRay.Remux.HDR.HEVC.DTS-HD.MA-SGF" \
        "X-Men.2.2003.1080p.BDRemux.DTSHi-Res.x264.Eng.Rus" \
        "X2.2003.UHD.BluRay.2160p.DTS-HD.MA.5.1.HEVC.REMUX-FraMeSToR" \
        "Final.Destination.Bloodlines.2025.2160p.UHD.BluRay.REMUX.DV.P7.HDR.MULTi-BTM" \
        "Dual.2022.1080p.BluRay.x264-GRP" \
        "Transformers.2007.2160p.UHD.BluRay.x265-GRP"; do
        run foreign_dub_title "$t"
        assert_output "no match"
    done
}

@test "Foreign dub first: a file's own name never matches, so a file scores what its release did" {
    local t
    for t in \
        "X2 (2003) - [Remux-2160p][AC3 2.0][HDR10][x265]-NAHOM.mkv" \
        "Dune Part Two (2024) - [Bluray-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-CYBER.mkv"; do
        run foreign_dub_title "$t"
        assert_output "no match"
    done
}

@test "configure_arr_service scores Foreign dub first at -1000 in Radarr, and not at all in Sonarr" {
    wait_for_service() { return 0; }
    api_get() { echo '[]'; }
    api_post() { echo '{}'; }
    api_put() { return 0; }
    ensure_cutoff_format_score() { :; }
    ensure_propers_not_preferred() { :; }
    ensure_custom_format() { printf '%s\t%s\t%s\t%s\n' "$3" "$4" "$5" "$6" >> "$CALLS"; }
    NAS_IP=x SABNZBD_RUNNING=false
    run configure_arr_service Sonarr 8989 k /data/media/tv tv renameEpisodes "" "{}"
    run configure_arr_service Radarr 7878 k /data/media/movies movies renameMovies "" "{}"
    run python3 -c '
import json, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])]
hits = [r for r in rows if r[1] == "Foreign dub first"]
print([r[0] for r in hits])
svc, name, score, specs = hits[0]
spec = json.loads(specs)[0]
print(score, spec["fields"][0]["value"] == sys.argv[2], spec["required"], spec["negate"])
' "$CALLS" "$FOREIGN_DUB_TITLE_RE"
    assert_output "['Radarr']
-1000 True True False"
}

# ---- Dolby Vision 8.1 score: not for Profile 7 remuxes ----------------------

remux_p7_title() {
    python3 -c 'import re, sys; print("match" if re.search(sys.argv[1], sys.argv[2], re.I) else "no match")' "$REMUX_P7_TITLE_RE" "$1"
}

@test "Profile 7 remux: matches remux titles, which keep the disc's Profile 7" {
    # Real titles from one library, every one Profile 7 by its file's
    # Dolby Vision configuration record.
    local t
    for t in \
        "Coraline.2009.2160p.UHD.BluRay.DV.REMUX.HDR10.HEVC.TrueHD.7.1.Atmos-UnKn0wn" \
        "Final.Destination.Bloodlines.2025.2160p.UHD.BluRay.REMUX.DV.P7.HDR.MULTi-BTM" \
        "Pressure.2026.2160p.UHD.Blu-ray.Remux.HEVC.DoVi.HDR10.TrueHD.Atmos.7.1-SPHD" \
        "The.Lighthouse.2019.4K.HDR.DV.2160p.BDRemux.Ita.Eng.x265-NAHOM" \
        "Stranger.Things.S03E05.BluRay.2160p.DTS-HD.MA.5.1.DV.HDR10.REMUX-Seedpool [AsRequested]" \
        "Film 2020 2160p UHD BluRay REMUX DV HDR10 TrueHD-GRP"; do
        run remux_p7_title "$t"
        assert_output "match"
    done
}

@test "Profile 7 remux: leaves converted remuxes, encodes and WEB releases alone" {
    local t
    for t in \
        "Up.2009.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.HYBRID.REMUX-FraMeSToR" \
        "Pirates.Of.The.Caribbean.On.Stranger.Tides.2011.2160p.REMUX.For.LGTVs.Dolby.Vision.HDR.ENG.RUS" \
        "Film.2024.2160p.UHD.BluRay.REMUX.DV.P8.HDR10.TrueHD-GRP" \
        "Hoppers.2026.UHD.BluRay.2160p.DDP.Atmos.5.1.DV.HDR.x265-hallowed" \
        "Predator.Badlands.2025.2160p.UHD.BDRip.HEVC.10bit.DV.HDR.TrueHD.7.1.Atmos-MUSHR00M" \
        "Stranger.Things.S05E08.Chapter.Eight.The.Rightside.Up.2160p.NF.WEB-DL.DDP5.1.DV.HDR.H.265-NTb"; do
        run remux_p7_title "$t"
        assert_output "no match"
    done
}

@test "Profile 7 remux: a file's own [Remux] name never matches, so a converted remux keeps its score once renamed" {
    # A condition matches the release title or the file name. If the name
    # matched, a HYBRID remux would drop to 0 on import, and every other 8.1
    # release of the film would look like an upgrade.
    local t
    for t in \
        "Up (2009) - [Remux-2160p][TrueHD Atmos 7.1][DV HDR10][HEVC]-FraMeSToR.mkv" \
        "Stranger Things (2016) - S03E05 - Chapter Five [Bluray-2160p Remux][DTS-HD MA 5.1][DV HDR10][HEVC].mkv"; do
        run remux_p7_title "$t"
        assert_output "no match"
    done
}

# ---- DTS 6.1 ----------------------------------------------------------------

dts61_title() {
    python3 -c 'import re, sys; print("match" if re.search(sys.argv[1], sys.argv[2], re.I) else "no match")' "$DTS_61_TITLE_RE" "$1"
}

@test "DTS 6.1: matches DTS-HD MA 6.1, DTS 6.1 and DTS-ES titles" {
    # The first is the remux that stopped at 0 ms; the rest are what the
    # same film's search turned up.
    local t
    for t in \
        "X-Men.The.Last.Stand.2006.UHD.BluRay.2160p.DTS-HD.MA.6.1.HEVC.REMUX-FraMeSToR" \
        "X-Men.The.Last.Stand.2006.2160p.BluRay.x265.10bit.SDR.DTS-HD.MA.6.1-SWTYBLZ" \
        "X-Men The Last Stand 2006 2160p UHD BDRip HEVC 10bit HDR DTS-HD.MA.6.1 MUSHR00M" \
        "X-Men The Last Stand 2006 1080p BluRay DTS-ES x264-RARBG" \
        "X.Men.The.Last.Stand.2006.BluRay.1080p.DTS-ES.x264-PRoDJi" \
        "Film.2001.1080p.BluRay.DTS.6.1.x264-GRP"; do
        run dts61_title "$t"
        assert_output "match"
    done
}

@test "DTS 6.1: leaves DTS 5.1 and 7.1, DTS:X and other codecs' 6.1 alone" {
    local t
    for t in \
        "X-Men-The.Last.Stand.2006.UHD.BluRay.HDR10.2160p.Dts-HD.Ma5.1.H265-d3g" \
        "Lincoln.2012.1080p.BluRay.DTS-HD.MA.7.1.x264-GRP" \
        "Film.2020.2160p.UHD.BluRay.DTS-X.7.1.HEVC.REMUX-FraMeSToR" \
        "X-Men.The.Last.Stand.2006.2160p.BDRip.HDR10.10bit.x265.AAC.6.1-PredikaT"; do
        run dts61_title "$t"
        assert_output "no match"
    done
}

@test "DTS 6.1: a file's own [DTS-HD MA 6.1] name never matches, so a file scores what its release did" {
    local t
    for t in \
        "X-Men The Last Stand (2006) - [Remux-2160p][DTS-HD MA 6.1][HDR10][HEVC]-FraMeSToR.mkv" \
        "Film (2004) - [Bluray-1080p][DTS-ES 6.1][x264]-GRP.mkv"; do
        run dts61_title "$t"
        assert_output "no match"
    done
}

@test "configure_arr_service scores DTS 6.1 at -1000 in both apps, and keeps Profile 7 remuxes out of the 8.1 score" {
    wait_for_service() { return 0; }
    api_get() { echo '[]'; }
    api_post() { echo '{}'; }
    api_put() { return 0; }
    ensure_cutoff_format_score() { :; }
    ensure_propers_not_preferred() { :; }
    ensure_custom_format() { printf '%s\t%s\t%s\t%s\n' "$3" "$4" "$5" "$6" >> "$CALLS"; }
    NAS_IP=x SABNZBD_RUNNING=false
    run configure_arr_service Sonarr 8989 k /data/media/tv tv renameEpisodes "" "{}"
    run configure_arr_service Radarr 7878 k /data/media/movies movies renameMovies "" "{}"
    run python3 -c '
import json, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])]
dts = [r for r in rows if r[1] == "DTS 6.1"]
print([r[0] for r in dts])
spec = json.loads(dts[0][3])[0]
print(dts[0][2], spec["fields"][0]["value"] == sys.argv[2], spec["required"], spec["negate"])
dv81 = [r for r in rows if r[1] == "DV HDR10 (Profile 8.1)"][0]
remux = json.loads(dv81[3])[2]
print(dv81[2], remux["fields"][0]["value"] == sys.argv[3], remux["required"], remux["negate"])
' "$CALLS" "$DTS_61_TITLE_RE" "$REMUX_P7_TITLE_RE"
    assert_output "['Sonarr', 'Radarr']
-1000 True True False
500 True True True"
}

# ---- ensure_custom_format: conditions follow the repo -----------------------

# A Sonarr with one custom format (id 7) whose conditions are $LIVE_SPECS, and
# one quality profile already scoring it at 500. api_put records what it sends.
stub_one_format() {
    LIVE_SPECS="$1"
    api_get() {
        case "$1" in
            */api/v3/customformat) printf '[{"id": 7, "name": "DV HDR10 (Profile 8.1)", "includeCustomFormatWhenRenaming": false, "specifications": %s}]' "$LIVE_SPECS" ;;
            */api/v3/qualityprofile) echo '[{"id": 1}]' ;;
            */api/v3/qualityprofile/1) echo '{"id": 1, "formatItems": [{"format": 7, "name": "DV HDR10 (Profile 8.1)", "score": 500}]}' ;;
        esac
    }
    api_post() { echo '{}'; }
    api_put() { printf 'PUT %s %s\n' "$1" "$3" >> "$CALLS"; }
}

# Conditions as the API returns them: fields as a list with extra keys,
# implementationName and the like added.
api_spec() {
    printf '{"name": "%s", "implementation": "ReleaseTitleSpecification", "implementationName": "Release Title", "negate": %s, "required": true, "fields": [{"order": 0, "name": "value", "label": "Regular Expression", "value": "%s", "type": "textbox", "advanced": false}]}' "$1" "$2" "$3"
}
repo_spec() {
    printf '{"name": "%s", "implementation": "ReleaseTitleSpecification", "negate": %s, "required": true, "fields": [{"name": "value", "value": "%s"}]}' "$1" "$2" "$3"
}

@test "ensure_custom_format: conditions that differ from the repo's are replaced, and the rest of the format kept" {
    stub_one_format "[$(api_spec "Dolby Vision" false 'dv'),$(api_spec "HDR10 base layer" false 'hdr')]"
    run ensure_custom_format http://x k Sonarr "DV HDR10 (Profile 8.1)" 500 \
        "[$(repo_spec "Dolby Vision" false 'dv'),$(repo_spec "HDR10 base layer" false 'hdr'),$(repo_spec "Not a Profile 7 remux" true 'remux')]"
    assert_output --partial "✓ Sonarr: updated DV HDR10 (Profile 8.1) custom format's conditions"
    run grep -c '^PUT http://x/api/v3/customformat/7 ' "$CALLS"
    assert_output "1"
    run python3 -c '
import json, sys
line = open(sys.argv[1]).readline()
body = json.loads(line.split(" ", 2)[2])
print(body["id"], body["name"], body["includeCustomFormatWhenRenaming"], [s["name"] for s in body["specifications"]])
' "$CALLS"
    assert_output "7 DV HDR10 (Profile 8.1) False ['Dolby Vision', 'HDR10 base layer', 'Not a Profile 7 remux']"
}

@test "ensure_custom_format: the same conditions in another order, with the API's extra fields, are a skip and no write" {
    stub_one_format "[$(api_spec "HDR10 base layer" false 'hdr'),$(api_spec "Dolby Vision" false 'dv')]"
    run ensure_custom_format http://x k Sonarr "DV HDR10 (Profile 8.1)" 500 \
        "[$(repo_spec "Dolby Vision" false 'dv'),$(repo_spec "HDR10 base layer" false 'hdr')]"
    assert_output --partial "- Sonarr: DV HDR10 (Profile 8.1) custom format (already configured)"
    [ ! -s "$CALLS" ]
}

@test "ensure_custom_format: a negate flipped by hand is put back" {
    stub_one_format "[$(api_spec "Not a Profile 7 remux" false 'remux')]"
    run ensure_custom_format http://x k Sonarr "DV HDR10 (Profile 8.1)" 500 \
        "[$(repo_spec "Not a Profile 7 remux" true 'remux')]"
    assert_output --partial "updated DV HDR10 (Profile 8.1) custom format's conditions"
}

@test "ensure_custom_format: a refused condition update is a ✗, not a ✓" {
    stub_one_format "[$(api_spec "Dolby Vision" false 'dv')]"
    api_put() { return 1; }
    run ensure_custom_format http://x k Sonarr "DV HDR10 (Profile 8.1)" 500 \
        "[$(repo_spec "Dolby Vision" false 'dovi')]"
    assert_output --partial "✗ Sonarr: update DV HDR10 (Profile 8.1) custom format's conditions"
    refute_output --partial "✓"
}
