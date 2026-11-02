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
