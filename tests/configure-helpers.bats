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
    # shellcheck disable=SC1090
    source "$HELPERS"
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

@test "api_post: timeout (curl 28) returns 2" {
    stub_curl 28 ""
    run api_post "http://x/api/v3/rootfolder" "application/json" '{}' "X-Api-Key: k"
    [ "$status" -eq 2 ]
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

# ---- bazarr_settings_post --------------------------------------------------

@test "bazarr_settings_post: timeout returns 2 and says so, hedged" {
    stub_curl 28 ""
    run bazarr_settings_post "http://x" "X-API-KEY: k" "settings-general-use_sonarr=true"
    [ "$status" -eq 2 ]
    assert_output --partial "gave no answer within 60s"
    assert_output --partial "may have landed"
}

@test "bazarr_settings_post: uses BAZARR_SCAN_TIMEOUT when a call asks for it" {
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

@test "bazarr_settings_post: connection refused returns 1, not 2" {
    stub_curl 7 $'\n000'
    run bazarr_settings_post "http://x" "X-API-KEY: k" "settings-general-use_sonarr=true"
    [ "$status" -eq 1 ]
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

@test "sourcing the helpers refuses a non-numeric BAZARR_POST_TIMEOUT" {
    run bash -c "BAZARR_POST_TIMEOUT=90s source '$HELPERS'"
    assert_failure
    assert_output --partial "BAZARR_POST_TIMEOUT must be a positive integer"
}

@test "sourcing the helpers refuses API_TIMEOUT=0 (curl would treat it as no bound)" {
    run bash -c "API_TIMEOUT=0 source '$HELPERS'"
    assert_failure
    assert_output --partial "API_TIMEOUT must be a positive integer"
}

# ---- --help ---------------------------------------------------------------

@test "configure-apps.sh --help prints the whole header, including what stays manual" {
    run bash "$REPO_ROOT/scripts/configure-apps.sh" --help
    assert_success
    assert_output --partial "What stays manual after this script"
    assert_output --partial "SABnzbd: usenet provider credentials"
    assert_output --partial "--only <section>"
    refute_output --partial "SCRIPT_DIR="
}

@test "configure-apps.sh --only rejects an unknown section" {
    run bash "$REPO_ROOT/scripts/configure-apps.sh" --only jellyfin
    assert_failure
    assert_output --partial "Unknown section"
}
