#!/usr/bin/env bats
# Unit tests for scripts/detect-credential-drift.sh, sourced with curl/docker
# stubbed - no live NAS/network access needed. Sourcing this script only
# defines functions; main() (the part that needs RADARR_API_KEY etc and
# makes real curl/docker calls) is guarded to run only when the script is
# executed directly, not sourced.
#
# Fixtures live in tests/fixtures/credential-drift/. Each corresponds to a
# real response shape captured against the live stack on 2026-08-17.

setup() {
    load helpers/setup
    FIXTURES="$REPO_ROOT/tests/fixtures/credential-drift"
}

# --- Bazarr log-scan pattern: regression for the two false-positive rounds
# hit live this session (bare `401` matched hex addresses, stack-trace line
# numbers, and UUID substrings; the `HTTP.{0,20}401` replacement then
# matched a stack trace too). Tests the exact BAZARR_LOG_PATTERN the script
# uses, not a duplicated copy. ---

@test "bazarr log pattern rejects known false-positive strings" {
    source "$REPO_ROOT/scripts/detect-credential-drift.sh"
    local line
    for line in \
        '0x401be10' \
        'at HttpClient.cs:line 401' \
        'session id 87401749234abc' \
        'connection reset by peer' \
        'GET /api/v3/movie returned 200'
    do
        run bash -c "echo '$line' | grep -iE '$BAZARR_LOG_PATTERN'"
        assert_failure
    done
}

@test "bazarr log pattern matches genuine auth-failure phrases" {
    source "$REPO_ROOT/scripts/detect-credential-drift.sh"
    local line
    for line in \
        'Unauthorized' \
        'unauthorized access attempt' \
        'Invalid credentials supplied' \
        'ApiKey is invalid for this request' \
        'apikey incorrect'
    do
        run bash -c "echo '$line' | grep -iE '$BAZARR_LOG_PATTERN'"
        assert_success
    done
}

# --- check_indexers: the live-test parser that replaced GET-based
# verification (which was structurally incapable of detecting drift, since
# Radarr/Sonarr mask secret fields in every GET response). Fixtures mirror
# the 3 real response shapes seen live: genuine 401, 429-only noise
# (indexer's own rate limit, not a stale credential), and clean. ---

@test "check_indexers flags a genuine 401 auth failure" {
    run bash -c "
        source '$REPO_ROOT/scripts/detect-credential-drift.sh'
        curl() { cat '$FIXTURES/indexer-testall-401.json'; }
        export -f curl
        check_indexers 'Radarr' 7878 'fake-key'
        echo \"\$findings\"
    "
    assert_output --partial "Radarr (live indexer test)"
    assert_output --partial "401"
}

@test "check_indexers ignores a pure 429 rate-limit response" {
    run bash -c "
        source '$REPO_ROOT/scripts/detect-credential-drift.sh'
        curl() { cat '$FIXTURES/indexer-testall-429-only.json'; }
        export -f curl
        check_indexers 'Sonarr' 8989 'fake-key'
        echo \"\$findings\"
    "
    assert_output ""
}

@test "check_indexers reports nothing for a clean response" {
    run bash -c "
        source '$REPO_ROOT/scripts/detect-credential-drift.sh'
        curl() { cat '$FIXTURES/indexer-testall-clean.json'; }
        export -f curl
        check_indexers 'Radarr' 7878 'fake-key'
        echo \"\$findings\"
    "
    assert_output ""
}

# --- Redaction: regression for the live Prowlarr key that leaked into a
# chat transcript this session via a testall error message embedding
# apikey=... in an indexer URL. That same finding text is what
# detect-credential-drift-alert.service POSTs to ntfy.sh, so this has to
# never contain a raw key. ---

@test "check_application redacts an embedded apikey from the upstream error body" {
    run bash -c "
        source '$REPO_ROOT/scripts/detect-credential-drift.sh'
        PROWLARR_API_KEY='test-key'
        curl() {
            local args=\"\$*\"
            if [[ \"\$args\" == *'/applications/test'* ]]; then
                printf '%s' \"\$(cat '$FIXTURES/application-test-error-with-embedded-key.json')|400\"
            else
                printf '%s' '{\"id\":1,\"name\":\"Sonarr\"}'
            fi
        }
        export -f curl
        check_application 1 'Sonarr'
        echo \"\$findings\"
    "
    assert_output --partial "REDACTED"
    refute_output --partial "abc123def456ghi789"
}
