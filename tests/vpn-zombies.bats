#!/usr/bin/env bats
# Unit tests for scripts/detect-vpn-zombies.sh, with docker stubbed so no
# live NAS/network access is needed. The script is a flat top-level script
# (no functions to source selectively), so each test stubs `docker` then
# sources the whole thing inside a `bash -c` subshell and asserts on its
# stdout/exit code.
#
# Regression coverage for the fix that added vpn-socks5 to DEPENDENTS
# (previously missing, a real pre-existing gap in Gluetun-recreate zombie
# detection found while auditing this script for NAS/VLAN10 migration
# readiness) — confirms the detection logic actually catches vpn-socks5
# going stale, not just that the script runs without crashing on it.

setup() {
    load helpers/setup
}

stub_docker() {
    # $1 = current gluetun ID, $2 = space-separated list of "name:mode" pairs
    # for docker inspect --format '{{.HostConfig.NetworkMode}}' <name>.
    cat <<EOF
docker() {
    if [[ "\$*" == *"--format {{.Id}} gluetun"* ]]; then
        echo "$1"
        return 0
    fi
    local name="\${*: -1}"
    case "\$name" in
$2
        *) return 1 ;;
    esac
}
export -f docker
EOF
}

@test "detect-vpn-zombies reports clean when every dependent shares gluetun's current netns" {
    run bash -c "
        $(stub_docker current-id '
            qbittorrent) echo "container:current-id" ;;
            sabnzbd) echo "container:current-id" ;;
            prowlarr) echo "container:current-id" ;;
            flaresolverr) echo "container:current-id" ;;
            vpn-socks5) echo "container:current-id" ;;
            magnetio-addon) echo "container:current-id" ;;
        ')
        source '$REPO_ROOT/scripts/detect-vpn-zombies.sh'
    "
    assert_success
    assert_output --partial "OK: all VPN-tunneled dependents share Gluetun's current netns"
}

@test "detect-vpn-zombies flags vpn-socks5 specifically when it's bound to a stale gluetun ID" {
    run bash -c "
        $(stub_docker current-id '
            qbittorrent) echo "container:current-id" ;;
            sabnzbd) echo "container:current-id" ;;
            prowlarr) echo "container:current-id" ;;
            flaresolverr) echo "container:current-id" ;;
            vpn-socks5) echo "container:stale-id" ;;
            magnetio-addon) echo "container:current-id" ;;
        ')
        source '$REPO_ROOT/scripts/detect-vpn-zombies.sh'
    "
    assert_failure
    assert_output --partial "ZOMBIE CONTAINERS"
    assert_output --partial "vpn-socks5"
    assert_output --partial "docker restart"
    refute_output --partial "qbittorrent"
}

@test "detect-vpn-zombies DEPENDENTS covers every service tunneled through gluetun" {
    # Regression guard for the vpn-socks5 gap this whole file exists to fix:
    # find every service declaring network_mode: "service:gluetun" or
    # "container:gluetun" across all compose files, and assert each one's
    # service name is actually present in the script's hardcoded DEPENDENTS
    # array — so a future service added the same way doesn't silently go
    # undetected the way vpn-socks5 did.
    local dependents
    dependents=$(grep -oE 'DEPENDENTS=\([^)]*\)' "$REPO_ROOT/scripts/detect-vpn-zombies.sh")

    local tunneled
    tunneled=$(for f in $(get_compose_files); do
        awk '
            /^  [a-zA-Z0-9_.-]+:[[:space:]]*$/ { svc=$0; sub(/:[[:space:]]*$/, "", svc); sub(/^  /, "", svc) }
            /^[[:space:]]*network_mode:[[:space:]]*"(service|container):gluetun"/ { print svc }
        ' "$f"
    done)

    [[ -n "$tunneled" ]]
    while IFS= read -r svc; do
        [[ -n "$svc" ]] || continue
        echo "checking $svc is in DEPENDENTS" >&2
        [[ "$dependents" == *"$svc"* ]]
    done <<< "$tunneled"
}

@test "detect-vpn-zombies skips a dependent docker inspect can't find rather than crashing" {
    run bash -c "
        $(stub_docker current-id '
            qbittorrent) echo "container:current-id" ;;
            sabnzbd) return 1 ;;
            prowlarr) echo "container:current-id" ;;
            flaresolverr) echo "container:current-id" ;;
            vpn-socks5) echo "container:current-id" ;;
            magnetio-addon) echo "container:current-id" ;;
        ')
        source '$REPO_ROOT/scripts/detect-vpn-zombies.sh'
    "
    assert_success
    assert_output --partial "OK: all VPN-tunneled dependents share Gluetun's current netns"
}
