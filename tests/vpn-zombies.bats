#!/usr/bin/env bats
# Unit tests for scripts/detect-vpn-zombies.sh.
#
# That script is the stack's guard against the nastiest Gluetun failure mode:
# a *recreate* mints a new container ID, and dependents pinned to the old one
# keep running as zombies — healthy on their own localhost, unreachable from
# everything else. Until now the script had no tests at all, so nothing proved
# it could actually report a zombie rather than just exit 0 on a healthy day.
# A guard nobody has watched fail is not yet a guard.
#
# `docker` is stubbed throughout, so these run anywhere — no NAS, no network,
# no live stack. The live counterpart is tests/e2e/resilience.spec.ts, which
# asks the real containers the same question.
#
# Adapted from work in leonardoazeredo/ultimate-arr-stack (tests/vpn-zombies.bats),
# rewritten against this repo's script, which differs in array name, output
# strings, and its stranded/skipped split.

setup() {
    load helpers/setup
    ZOMBIE_SCRIPT="$REPO_ROOT/scripts/detect-vpn-zombies.sh"
    STUB="$BATS_TEST_TMPDIR/docker-stub.bash"
    write_docker_stub
}

# A `docker` stub covering the only two calls the script makes:
#   docker inspect --format '{{.Id}}' <name>
#   docker inspect --format '{{.HostConfig.NetworkMode}}' <name>
#
# Lookups come from two newline-separated `name=value` tables, STUB_IDS and
# STUB_NETMODE, set per test. A name absent from its table makes inspect fail,
# which is how the real docker behaves for a container that does not exist; the
# value `EMPTY` makes it succeed while printing nothing.
# Deliberately no associative arrays: macOS ships bash 3.2.
write_docker_stub() {
    cat > "$STUB" <<'STUB'
docker() {
    local fmt="" name=""
    shift  # `inspect`
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) fmt="$2"; shift 2 ;;
            *)        name="$1"; shift ;;
        esac
    done

    local table
    case "$fmt" in
        '{{.Id}}')                     table="$STUB_IDS" ;;
        '{{.HostConfig.NetworkMode}}') table="$STUB_NETMODE" ;;
        *) return 1 ;;
    esac

    local key value
    while IFS='=' read -r key value; do
        [[ "$key" == "$name" ]] || continue
        case "$value" in
            # Docker succeeding with an empty answer is a distinct failure from
            # docker erroring, and the script handles them separately.
            EMPTY) printf '\n'; return 0 ;;
            '')    return 1 ;;
            *)     printf '%s\n' "$value"; return 0 ;;
        esac
    done <<< "$table"
    return 1
}
STUB
}

run_detector() {
    run bash -c "source '$STUB'; source '$ZOMBIE_SCRIPT'"
}

@test "reports OK when every tunneled dependent shares Gluetun's live namespace" {
    export STUB_IDS='gluetun=live-ns'
    export STUB_NETMODE='qbittorrent=container:live-ns
sabnzbd=container:live-ns
prowlarr=container:live-ns
flaresolverr=container:live-ns'

    run_detector
    assert_success
    assert_output --partial "OK: every tunneled dependent is inside Gluetun's current namespace"
}

@test "flags a dependent pinned to a destroyed container, and names only that one" {
    # The post-recreate case: sabnzbd still references the container ID Gluetun
    # had before, which no longer exists.
    export STUB_IDS='gluetun=live-ns'
    export STUB_NETMODE='qbittorrent=container:live-ns
sabnzbd=container:dead-ns
prowlarr=container:live-ns
flaresolverr=container:live-ns'

    run_detector
    assert_failure
    assert_output --partial "STRANDED"
    assert_output --partial "sabnzbd (joined to a destroyed container)"
    assert_output --partial "Fix: docker restart sabnzbd"
    # The healthy three must not be swept in with it — a detector that blames
    # everything is as useless as one that blames nothing.
    refute_output --partial "qbittorrent"
}

@test "distinguishes a dependent pinned to a different *live* container" {
    # Same breakage, different shape: the old Gluetun is gone but its ID was
    # reused, or the dependent was pointed at some other container entirely.
    # The two read very differently when you are working out what happened.
    export STUB_IDS='gluetun=live-ns
other-ns=other-ns'
    export STUB_NETMODE='qbittorrent=container:live-ns
sabnzbd=container:live-ns
prowlarr=container:other-ns
flaresolverr=container:live-ns'

    run_detector
    assert_failure
    assert_output --partial "prowlarr (joined to a different live container)"
    refute_output --partial "destroyed container"
}

@test "treats an absent or stopped dependent as not-checked, not as a zombie" {
    # No namespace binding to judge means no evidence of breakage. Calling it a
    # zombie would be a false positive that trains people to ignore the output.
    export STUB_IDS='gluetun=live-ns'
    export STUB_NETMODE='qbittorrent=container:live-ns
sabnzbd=container:live-ns
prowlarr=container:live-ns'

    run_detector
    assert_success
    assert_output --partial "Not checked"
    assert_output --partial "flaresolverr"
}

@test "treats a dependent that is not namespace-joined as not-checked" {
    export STUB_IDS='gluetun=live-ns'
    export STUB_NETMODE='qbittorrent=container:live-ns
sabnzbd=bridge
prowlarr=container:live-ns
flaresolverr=container:live-ns'

    run_detector
    assert_success
    assert_output --partial "Not checked"
    assert_output --partial "sabnzbd"
}

@test "fails loudly when Gluetun itself cannot be inspected" {
    # The one case where returning 0 would be actively dangerous: no Gluetun to
    # compare against means the check produced no evidence at all.
    export STUB_IDS=''
    export STUB_NETMODE=''

    run_detector
    assert_failure
    assert_output --partial "cannot inspect gluetun"
}

@test "fails loudly when Gluetun reports an empty container ID" {
    # Distinct from the case above: docker answers, but with nothing. Without
    # its own check the script would compare every dependent against "" and
    # declare the whole stack stranded.
    export STUB_IDS='gluetun=EMPTY'
    export STUB_NETMODE=''

    run_detector
    assert_failure
    assert_output --partial "empty container ID"
}

@test "TUNNELED covers every service compose puts inside Gluetun's namespace" {
    # The gap this file exists to close is not a logic bug — it is a service
    # added to compose with network_mode: "service:gluetun" and never added to
    # the script's hardcoded list, so it silently escapes detection forever.
    # Derive the truth from compose and assert the list keeps up.
    local declared
    declared=$(grep -oE 'TUNNELED=\([^)]*\)' "$ZOMBIE_SCRIPT")
    [[ -n "$declared" ]]

    local tunneled
    tunneled=$(for f in $(get_compose_files); do
        awk '
            /^  [a-zA-Z0-9_.-]+:[[:space:]]*$/ { svc=$0; sub(/:[[:space:]]*$/, "", svc); sub(/^  /, "", svc) }
            /^[[:space:]]*network_mode:[[:space:]]*"service:gluetun"[[:space:]]*$/ { print svc }
        ' "$f"
    done)

    # Guard the guard: if the awk stops matching, every assertion below passes
    # vacuously and this test becomes decoration.
    [[ -n "$tunneled" ]]

    local svc
    while IFS= read -r svc; do
        [[ -n "$svc" ]] || continue
        echo "checking '$svc' is listed in TUNNELED" >&2
        [[ "$declared" == *"$svc"* ]]
    done <<< "$tunneled"
}

@test "helpers.ts TUNNELED_SERVICES agrees with the script's TUNNELED" {
    # Two hardcoded copies of the same topology, in two languages. They drifting
    # apart would mean the e2e suite and the shell detector disagree about what
    # is even supposed to be on the VPN.
    local helpers="$REPO_ROOT/tests/e2e/helpers.ts"
    [[ -f "$helpers" ]]

    local from_ts
    from_ts=$(grep -oE "TUNNELED_SERVICES = \[[^]]*\]" "$helpers" \
        | grep -oE "'[a-z0-9_-]+'" | tr -d "'" | sort | tr '\n' ' ')

    local from_sh
    from_sh=$(grep -oE 'TUNNELED=\([^)]*\)' "$ZOMBIE_SCRIPT" \
        | sed -E 's/TUNNELED=\(//; s/\)//' | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')

    [[ -n "$from_ts" ]]
    [[ -n "$from_sh" ]]
    assert_equal "$from_ts" "$from_sh"
}
