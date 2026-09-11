#!/usr/bin/env bats
# scripts/check-vpn.sh
#
# A cron leak detector, so the failure that matters is the one where it reports
# OK. Two of these tests exist because it did exactly that: the headline check
# compared Gluetun's exit IP -- a PUBLIC address from ifconfig.me -- against
# `hostname -I`, a private LAN address, and behind NAT those can never be equal.
# It could not fire.
#
# The other recurring risk here is drift from tests/e2e/vpn-security.spec.ts,
# which this script's header says it must stay in sync with. Two of these tests
# derive both service lists from the two files and compare them, so the sync is
# asserted rather than asked for in a comment.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    SCRIPT="$REPO_ROOT/scripts/check-vpn.sh"
    SPEC="$REPO_ROOT/tests/e2e/vpn-security.spec.ts"

    # One file per container: its contents are that container's egress IP, and
    # an absent file is a container that cannot be reached.
    IPS="$BATS_TEST_TMPDIR/ips"
    mkdir -p "$IPS"
    export IPS

    stub_docker '
[ "$1" = exec ] || { echo "unexpected docker argv: $*" >&2; exit 125; }
if [ -f "$IPS/$2" ]; then cat "$IPS/$2"; else exit 1; fi
'
    # The healthy world: Proton on one side, the household WAN on the other.
    ip gluetun     "185.107.56.9"
    ip sonarr      "81.20.30.40"
    ip qbittorrent "185.107.56.9"
    ip prowlarr    "185.107.56.9"
    ip sabnzbd     "185.107.56.9"
    ip flaresolverr "185.107.56.9"
}

ip()      { printf '%s\n' "$2" > "$IPS/$1"; }
unreachable() { rm -f "$IPS/$1"; }

# The egress command is a `sh -c` string handed to the container, and which of
# curl and wget runs inside it is decided by the shell in the container. A stub
# that answers `docker exec` with an IP off the fixture never executes that
# string, so `||` and `&&` between the two clients were indistinguishable to
# every test in this file. These run it for real, with a fake client directory
# on PATH and the answers coming from the same fixtures:
#
#   $IPS/<container>        what wget answers (absent = wget is not installed)
#   $IPS/curl-<container>   what curl answers (absent = curl is not installed)
with_real_egress_clients() {
    local bindir="$BATS_TEST_TMPDIR/egress-clients"
    mkdir -p "$bindir"
    cat > "$bindir/curl" <<'FAKE_CURL'
#!/bin/bash
[ -n "${CURL_IP:-}" ] || exit 127
printf '%s\n' "$CURL_IP"
FAKE_CURL
    cat > "$bindir/wget" <<'FAKE_WGET'
#!/bin/bash
printf '%s\n' "${WGET_IP:-}"
FAKE_WGET
    chmod +x "$bindir/curl" "$bindir/wget"
    stub_docker '
        [ "$1" = exec ] || { echo "unexpected docker argv: $*" >&2; exit 125; }
        CURL_IP="$(cat "$IPS/curl-$2" 2>/dev/null)"
        WGET_IP="$(cat "$IPS/$2" 2>/dev/null)"
        export CURL_IP WGET_IP
        PATH="'"$bindir"':$PATH" sh -c "$5"
    '
}

curl_ip() { printf '%s\n' "$2" > "$IPS/curl-$1"; }

# Every container the script asks for an egress IP: Gluetun, the WAN reference,
# and the tunneled list read out of the script rather than restated here.
all_containers() { { echo gluetun; echo sonarr; bash_tunneled; } | sort -u; }

# The service lists, read from the files that own them rather than restated
# here -- a copy in this file would drift exactly as the two production lists
# already did.
bash_tunneled() {
    sed -n 's/^TUNNELED_SERVICES=(\(.*\))$/\1/p' "$SCRIPT" | tr ' ' '\n' | sort
}
ts_list() {
    sed -n "s/^const $1 = \[\(.*\)\] as const;$/\1/p" "$SPEC" \
        | tr -d "' " | tr ',' '\n' | sort
}

@test "check-vpn: a healthy VPN exits 0 and names both IPs" {
    run "$SCRIPT"
    assert_success
    assert_output --partial "OK: VPN is active"
    assert_output --partial "WAN IP: 81.20.30.40"
    assert_output --partial "VPN IP: 185.107.56.9"
    assert_nothing_forbidden
}

@test "check-vpn: DEFECT - Gluetun egressing on the household WAN IP is a leak" {
    # The whole point of the script, and the case it could not detect: with the
    # tunnel down, Gluetun's egress becomes the household's public IP. The old
    # comparison was against the NAS's 192.168.x.x LAN address, which nothing
    # reported by ifconfig.me can ever equal.
    ip gluetun "81.20.30.40"
    ip qbittorrent "81.20.30.40"
    ip prowlarr "81.20.30.40"
    ip sabnzbd "81.20.30.40"
    ip flaresolverr "81.20.30.40"
    run "$SCRIPT"
    assert_failure
    assert_output --partial "LEAK DETECTED"
    assert_output --partial "matches the household WAN IP"
    refute_output --partial "OK: VPN is active"
}

@test "check-vpn: an unreachable Gluetun is an error, not a pass" {
    unreachable gluetun
    run "$SCRIPT"
    assert_failure
    assert_output --partial "Could not reach an IP-check service through Gluetun"
}

@test "check-vpn: an empty answer from Gluetun is an error, not a pass" {
    : > "$IPS/gluetun"
    run "$SCRIPT"
    assert_failure
    assert_output --partial "Empty response"
}

@test "check-vpn: the wget fallback still answers when curl is not installed" {
    # egress_ip's own comment records the case: Gluetun has no curl, only wget.
    # `||` is what makes wget a fallback rather than a second requirement. With
    # `&&` it runs only after curl has already succeeded, so Gluetun's egress
    # becomes unreadable and every run ends at "Could not reach an IP-check
    # service through Gluetun" -- while the bridge-only containers, which do
    # have curl, keep answering normally and make the breakage look partial.
    with_real_egress_clients
    run "$SCRIPT"
    assert_success
    assert_output --partial "VPN IP: 185.107.56.9"
    assert_output --partial "OK: qbittorrent egress IP matches Gluetun"
}

@test "check-vpn: a working curl is not followed by wget" {
    # The other half of the same `||`. With `&&` the fallback stops being a
    # fallback: wget runs after a curl that already answered, and egress_ip
    # returns both answers on two lines, so the reported VPN IP and every
    # comparison made below it are made against a two-line string. The second
    # answer showing up in the report is the only thing that says so.
    with_real_egress_clients
    local c
    while read -r c; do curl_ip "$c" "$(cat "$IPS/$c")"; done < <(all_containers)
    while read -r c; do ip "$c" "198.51.100.7"; done < <(all_containers)
    run "$SCRIPT"
    assert_success
    assert_output --partial "VPN IP: 185.107.56.9"
    refute_output --partial "198.51.100.7"
}

@test "check-vpn: a missing WAN reference SKIPS that comparison, loudly" {
    # The comparison genuinely cannot be made without a reference, and failing
    # the run would page someone whenever an unrelated container is down. What
    # it must not do is print OK for a check it never performed.
    unreachable sonarr
    run "$SCRIPT"
    assert_success
    assert_output --partial "SKIPPED: Gluetun-vs-WAN comparison"
    refute_output --partial "OK: VPN is active"
    # The rest of the run still happens: the per-service comparison is against
    # Gluetun, and does not need the WAN reference at all.
    assert_output --partial "OK: qbittorrent egress IP matches Gluetun"
}

@test "check-vpn: one leaking dependent fails the run and names it" {
    ip prowlarr "81.20.30.40"
    run "$SCRIPT"
    assert_failure
    assert_output --partial "LEAK DETECTED: prowlarr egress IP"
}

@test "check-vpn: a leak does not stop the remaining services being checked" {
    # `leaked=1` sets a flag and continues. If it ever became an early exit, the
    # first leak would mask every other one and a run would under-report -- and
    # the exit status, the only thing cron looks at, would be identical.
    ip qbittorrent "81.20.30.40"
    run "$SCRIPT"
    assert_failure
    assert_output --partial "LEAK DETECTED: qbittorrent"
    assert_output --partial "OK: flaresolverr egress IP matches Gluetun"
}

@test "check-vpn: PINNED - a dependent that is down warns but does not fail" {
    # Deliberate asymmetry: a container that is not running is not leaking, and
    # this runs every five minutes from cron. Pinned rather than fixed, so the
    # asymmetry stays a decision.
    unreachable sabnzbd
    run "$SCRIPT"
    assert_success
    assert_output --partial "WARN: sabnzbd"
}

@test "check-vpn: every service in TUNNELED_SERVICES is actually queried" {
    # Derived from the script's own array. A service added to the list but not
    # reached -- or a loop that stops early -- is otherwise invisible, because
    # the exit status is the same either way.
    run "$SCRIPT"
    assert_success
    local svc
    while read -r svc; do
        [ -n "$svc" ] || continue
        assert_stub_called docker "exec $svc sh -c"
    done < <(bash_tunneled)
}

@test "check-vpn: the tunneled list matches the e2e suite's" {
    # The script's header says the two implement the same comparison and must be
    # kept in sync. They had already diverged on the far more important half --
    # what to compare against -- so the sync is asserted here rather than asked
    # for in prose.
    local a b
    a=$(bash_tunneled)
    b=$(ts_list TUNNELED_SERVICES)
    [ -n "$b" ] || fail "could not parse TUNNELED_SERVICES from $SPEC"
    [ "$a" = "$b" ] || fail "scripts/check-vpn.sh and the e2e spec disagree:"$'\n'"--- script ---"$'\n'"$a"$'\n'"--- spec ---"$'\n'"$b"
}

@test "check-vpn: the WAN reference container is one the e2e spec calls bridge-only" {
    # The reference is only a WAN reference for as long as it stays off the VPN.
    # The e2e spec has a standing test that each BRIDGE_SERVICES entry must NOT
    # match Gluetun, so membership of that list is what makes this container a
    # valid reference -- and if someone re-tunnels it, this fails here first.
    local ref bridge
    ref=$(sed -n 's/^BRIDGE_REF="\${BRIDGE_REF:-\(.*\)}"$/\1/p' "$SCRIPT")
    [ -n "$ref" ] || fail "could not parse BRIDGE_REF from $SCRIPT"
    bridge=$(ts_list BRIDGE_SERVICES)
    [ -n "$bridge" ] || fail "could not parse BRIDGE_SERVICES from $SPEC"
    grep -qxF -- "$ref" <<<"$bridge" \
        || fail "BRIDGE_REF=$ref is not in the e2e spec's bridge-only list:"$'\n'"$bridge"
}

@test "check-vpn: the WAN reference is never one of the tunneled services" {
    # Comparing Gluetun against something that is itself behind Gluetun would
    # make the headline check compare the VPN to itself: always equal, always a
    # reported leak, or -- with the comparison the other way round -- never one.
    local ref
    ref=$(sed -n 's/^BRIDGE_REF="\${BRIDGE_REF:-\(.*\)}"$/\1/p' "$SCRIPT")
    if grep -qxF -- "$ref" <<<"$(bash_tunneled)"; then
        fail "BRIDGE_REF=$ref is itself in TUNNELED_SERVICES"
    fi
}
