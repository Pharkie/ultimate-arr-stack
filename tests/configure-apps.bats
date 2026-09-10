#!/usr/bin/env bats
# Tests for scripts/configure-apps.sh that need no NAS: its command line, and
# the structural guarantees the Bazarr section makes that no unit test of the
# helpers or the language plan can see.

setup() {
    load helpers/setup
    SCRIPT="$REPO_ROOT/scripts/configure-apps.sh"
}

@test "--help prints the whole header, including what stays manual" {
    run bash "$SCRIPT" --help
    assert_success
    assert_output --partial "What stays manual after this script"
    assert_output --partial "SABnzbd: usenet provider credentials"
    assert_output --partial "--only <section>"
    assert_output --partial "SUBTITLE_LANGUAGES"
    refute_output --partial "SCRIPT_DIR="
}

@test "--only rejects an unknown section" {
    run bash "$SCRIPT" --only jellyfin
    assert_failure
    assert_output --partial "Unknown section"
}

# Bazarr gives a series or movie its language profile when it first inserts
# the row, and connecting Sonarr/Radarr starts that sync immediately — so the
# profile and default steps must come before the connections step. Nothing
# else enforces the order: the plan is pure, the helpers are stubbed, and the
# e2e test sees only the settled state. This reads the section's source.
@test "configure_bazarr sets the profile and its defaults before connecting Sonarr/Radarr" {
    local profile_line default_line connect_line
    profile_line=$(grep -n 'languages-profiles=${plan_profiles}' "$SCRIPT" | head -1 | cut -d: -f1)
    default_line=$(grep -n 'settings-general-serie_default_profile=${profile_id}' "$SCRIPT" | head -1 | cut -d: -f1)
    connect_line=$(grep -n '"settings-sonarr-ip=${sonarr_host}"' "$SCRIPT" | head -1 | cut -d: -f1)
    [ -n "$profile_line" ] && [ -n "$default_line" ] && [ -n "$connect_line" ]
    [ "$profile_line" -lt "$default_line" ]
    [ "$default_line" -lt "$connect_line" ]
}

@test "the Bazarr section never restarts the container" {
    run grep -n 'docker restart "\$BAZARR_CONTAINER"' "$SCRIPT"
    assert_failure
}

@test "every curl in the script is bounded" {
    # Each curl invocation must carry a transfer bound: --max-time or -m.
    run bash -c "grep -n 'curl ' '$SCRIPT' | grep -v '^[0-9]*:#' | grep -vE -- '--max-time|-m [0-9]'"
    assert_output ''
}
