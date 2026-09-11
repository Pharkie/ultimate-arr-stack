#!/usr/bin/env bats
# Live network segmentation tests — VLAN20 (personal) -> VLAN10 (services).
#
# Why this file exists: every other bats file here checks compose TEXT. Nothing
# checked the actual network, which is exactly how an unrestricted VLAN20->VLAN10
# forward survived unnoticed until a manual audit found it. These assert the
# router's allow-list as it actually behaves, from a host sitting on VLAN20.
#
# Vantage point: must run from a host with an address on VLAN20 (pi1). Anywhere
# else — CI runners, the NAS itself, a laptop on another VLAN — every test skips
# rather than failing, the same gate pattern tests/e2e/helpers.ts uses for Docker.
#
# The allow-list mirrors the router rules `vlan20-to-nas-svcs`,
# `vlan20-to-pihole-dns`, `vlan20-to-traefik` and `vlan20-to-nas-timemachine`.
# If you change a rule, change this file in the same commit — a silent
# divergence here is worse than no test.
#
# NOT asserted, deliberately: the router's own :22 is reachable from this host.
# That is `Allow-pi1-router-mgmt`, an INPUT rule with no `dest`, so it matches
# any router interface including the VLAN10 one. It is a deliberate pinhole, not
# a forwarding hole, and asserting it blocked would encode a false expectation.

setup() {
    load helpers/setup
}

NAS_VLAN10_IP="${NAS_VLAN10_IP:-192.168.110.246}"
TRAEFIK_VLAN10_IP="${TRAEFIK_VLAN10_IP:-192.168.110.250}"

# Ports VLAN20 is meant to reach. 53 is here because `vlan20-to-pihole-dns`
# grants it; it is asserted over BOTH transports, since that rule is `tcpudp`
# and a TCP-only probe would pass while UDP resolution — the transport DNS
# actually uses — was broken. 445 is `vlan20-to-nas-timemachine`: the Mac's
# Time Machine destination is an SMB share on the NAS, and the Mac is on VLAN20
# while the NAS is on VLAN10, so backups cross this boundary.
SEG_ALLOWED_NAS="${SEG_ALLOWED_NAS:-22 53 445 5055 8096}"
SEG_ALLOWED_TRAEFIK="${SEG_ALLOWED_TRAEFIK:-80 443}"

# A name Pi-hole is authoritative for, used to prove UDP/53 end to end rather
# than just proving a socket accepts a TCP handshake.
SEG_DNS_NAME="${SEG_DNS_NAME:-sonarr.lan}"

tcp_open() {
    timeout "${3:-4}" bash -c "cat </dev/null >/dev/tcp/$1/$2" 2>/dev/null
}

on_vlan20() {
    ip -4 -o addr show 2>/dev/null | grep -qE 'inet 192\.168\.120\.'
}

require_vlan20() {
    on_vlan20 || skip "not on VLAN20 (no 192.168.120.0/24 address) - nothing to assert from here"
}

# Ask the NAS what it is listening on. pi1->NAS:22 is itself part of the
# allow-list, so this works from the intended vantage point and nowhere else.
# stderr is captured rather than discarded: a wrong/missing `arr-stack-nas` SSH
# alias and a genuinely unreachable NAS both end in a skip, and without the
# error text the skip reason cannot tell an operator which one happened.
NAS_SSH_HOST="${NAS_SSH_HOST:-arr-stack-nas}"
NAS_SSH_ERR=""
nas_ssh() {
    local out rc
    out=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$NAS_SSH_HOST" "$@" 2>&1)
    rc=$?
    if (( rc != 0 )); then
        NAS_SSH_ERR="$out"
        return "$rc"
    fi
    printf '%s\n' "$out"
}

# Ports genuinely bound on the NAS's VLAN10-facing side: wildcard binds plus
# anything bound to the VLAN10 address itself. Loopback- and tailnet-only binds
# are excluded on purpose — they are unreachable from ANY VLAN, so asserting
# them blocked proves nothing about the firewall and would pad the check with
# assertions that cannot fail.
nas_reachable_ports() {
    nas_ssh "ss -H -ltn 2>/dev/null | awk '{print \$4}'" \
        | grep -E "^(0\.0\.0\.0|\[::\]|\*|${NAS_VLAN10_IP//./\\.}):[0-9]+$" \
        | sed 's/.*://' | sort -un
}

@test "segmentation: this host is on VLAN20 (vantage point for the rest of this file)" {
    require_vlan20
    run bash -c "ip -4 -o addr show | grep -oE 'inet 192\.168\.120\.[0-9]+' | head -1"
    assert_success
    [[ -n "$output" ]] || fail "expected a VLAN20 address"
}

@test "segmentation: VLAN20 can reach the NAS on its allow-listed ports" {
    require_vlan20
    local unreachable=""
    for p in $SEG_ALLOWED_NAS; do
        tcp_open "$NAS_VLAN10_IP" "$p" || unreachable+="  $NAS_VLAN10_IP:$p"$'\n'
    done
    [[ -z "$unreachable" ]] || fail "allow-listed NAS ports NOT reachable from VLAN20:"$'\n'"$unreachable"
}

@test "segmentation: VLAN20 can resolve DNS over UDP against the NAS" {
    require_vlan20
    command -v dig >/dev/null || skip "dig not installed - cannot test UDP/53 (TCP/53 is still covered above)"

    # dig defaults to UDP. +notcp keeps it from silently retrying over TCP,
    # which would let a UDP-blocked path pass on the transport already asserted.
    run dig +short +notcp +timeout=3 +tries=1 "@$NAS_VLAN10_IP" "$SEG_DNS_NAME" A
    assert_success
    [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]] \
        || fail "UDP/53 to $NAS_VLAN10_IP did not resolve $SEG_DNS_NAME to an address, got: ${output:-<empty>}"
}

@test "segmentation: VLAN20 can reach Traefik on its allow-listed ports" {
    require_vlan20
    local unreachable=""
    for p in $SEG_ALLOWED_TRAEFIK; do
        tcp_open "$TRAEFIK_VLAN10_IP" "$p" || unreachable+="  $TRAEFIK_VLAN10_IP:$p"$'\n'
    done
    [[ -z "$unreachable" ]] || fail "allow-listed Traefik ports NOT reachable from VLAN20:"$'\n'"$unreachable"
}

@test "segmentation: VLAN20 is blocked from every NAS port outside the allow-list" {
    require_vlan20

    # Vacuity guard, structural rather than by hand. Asserting "port closed from
    # here" is meaningless unless the port is open THERE, so the denied set is
    # DERIVED from what the NAS is actually listening on right now, minus the
    # allow-list. That also removes the drift trap of a hardcoded list: a new
    # service on a new port is covered the moment it starts listening, with
    # nobody having to remember to add it here.
    local listening
    listening=$(nas_reachable_ports) \
        || skip "cannot reach the NAS via '$NAS_SSH_HOST' to enumerate listening ports - assertion would be vacuous: ${NAS_SSH_ERR:-no error text}"
    [[ -n "$listening" ]] \
        || skip "the NAS reported no listening ports (is 'ss' present there?) - assertion would be vacuous"

    local checked=0 leaked=""
    for p in $listening; do
        # shellcheck disable=SC2076  # literal match on a space-padded list is intended
        [[ " $SEG_ALLOWED_NAS " == *" $p "* ]] && continue
        checked=$((checked + 1))
        if tcp_open "$NAS_VLAN10_IP" "$p"; then
            leaked+="  $NAS_VLAN10_IP:$p is LIVE and REACHABLE from VLAN20"$'\n'
        fi
    done

    [[ -z "$leaked" ]] || fail "VLAN20 -> VLAN10 segmentation hole:"$'\n'"$leaked"
    [[ "$checked" -gt 0 ]] \
        || fail "the NAS is listening on nothing outside the allow-list, so this test proved nothing. Listening: $(echo $listening)"
}

# NOT tested, and why: there is no non-vacuous denied-port assertion to make
# against Traefik. Probed from the NAS itself (i.e. from inside VLAN10, where
# the firewall is not in the way), 192.168.110.250 accepts 80 and 443 and
# nothing else - 8080, 8082 and 9090 are all closed there. Asserting any of
# them blocked from VLAN20 would be a test that cannot fail, which is the exact
# defect this file exists to avoid. If Traefik ever publishes another port,
# mirror the derived-denied-set approach used for the NAS above.
