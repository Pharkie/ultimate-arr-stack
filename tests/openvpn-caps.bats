#!/usr/bin/env bats
# Does Gluetun's OpenVPN path actually work with the capabilities this repo
# grants it?
#
# WHY THIS EXISTS
#
# `.env.example` documents OPENVPN_USER / OPENVPN_PASSWORD, so the stack
# advertises an OpenVPN path — and until 1.10.1 that path had never been
# exercised by anything. It was broken twice in a row, both times found by a
# user rather than by us:
#
#   1.10.0  `cap_drop: ALL` removed CHOWN, so gluetun could not chown
#           /etc/openvpn/target.ovpn and died before dialling out.
#   1.10.1  it also removed SETUID, so OpenVPN died on
#           `setuid('nonrootuser') failed` — but only AFTER the tunnel
#           established, which is why fixing the first bug did not reveal
#           the second.
#
# That second one matters for how this test is built. The 1.10.0 fix was
# "verified" against dummy credentials, where OpenVPN exits at AUTH_FAILED —
# and setuid happens after authentication, so the check could not have observed
# the failure it claimed to rule out. A test that does not carry a tunnel all
# the way up proves nothing about anything that happens after the handshake.
#
# Provider credentials were never the obstacle. A second container running
# OpenVPN in static-key mode is a real peer: no PKI, no account, no secrets in
# the repo. The client runs from the gluetun image itself, so the binary, libc
# and capability behaviour are the ones that ship.
#
# The capability list is READ FROM docker-compose.arr-stack.yml rather than
# written out here. A test carrying its own copy of the thing it validates
# agrees with itself forever; this one fails when the compose file changes.

setup() {
    load helpers/setup

    COMPOSE="$REPO_ROOT/docker-compose.arr-stack.yml"
    NET="ovpn-caps-test-$$"
    SERVER="ovpn-caps-server-$$"

    command -v docker &>/dev/null || skip "docker is not available"
    docker info &>/dev/null || skip "no running docker daemon"
    # macOS has no /dev/net/tun on the host but its Linux VM does, so probe by
    # running a container rather than testing the host path.
    docker run --rm --device /dev/net/tun:/dev/net/tun alpine true &>/dev/null \
        || skip "/dev/net/tun is not available to containers"

    IMAGE="$(awk '/^  gluetun:/,/^    container_name:/' "$COMPOSE" \
             | awk -F'image: *' '/image:/{print $2; exit}')"
    [[ -n "$IMAGE" ]]

    # Every bare `- CAPNAME` between cap_add: and devices: in the gluetun block.
    # Comment lines are skipped by the pattern, which is why the heavily
    # commented cap_add block in the compose file parses cleanly.
    CAPS="$(awk '/^  gluetun:/,/^    devices:/' "$COMPOSE" \
            | awk '/^    cap_add:/{f=1;next} /^    [a-z_]+:/{f=0} f && /^      - [A-Z_]+$/{print $2}')"
    [[ -n "$CAPS" ]]

    docker network create "$NET" &>/dev/null
    docker run --rm -v "$BATS_TEST_TMPDIR:/out" --entrypoint /usr/sbin/openvpn2.6 \
        "$IMAGE" --genkey secret /out/static.key &>/dev/null
    [[ -s "$BATS_TEST_TMPDIR/static.key" ]]

    docker run -d --name "$SERVER" --network "$NET" --cap-add NET_ADMIN \
        --device /dev/net/tun:/dev/net/tun -v "$BATS_TEST_TMPDIR:/etc/ovpn:ro" \
        --entrypoint /usr/sbin/openvpn2.6 "$IMAGE" \
        --dev tun --proto udp --port 1194 --ifconfig 10.9.0.1 10.9.0.2 \
        --secret /etc/ovpn/static.key --cipher AES-256-CBC &>/dev/null
}

teardown() {
    [[ -n "${SERVER:-}" ]] && docker rm -f "$SERVER" &>/dev/null
    [[ -n "${NET:-}" ]] && docker network rm "$NET" &>/dev/null
    return 0
}

# Runs the OpenVPN client from the gluetun image with the given capabilities.
# `--user nobody` stands in for gluetun's `nonrootuser`, which gluetun creates
# at runtime from PUID/PGID and so does not exist when the entrypoint is
# bypassed. The syscall and the capability required are identical; only the
# target uid differs.
run_client() {
    local -a caps=()
    local c
    for c in "$@"; do caps+=(--cap-add "$c"); done

    timeout 40 docker run --rm --network "$NET" --cap-drop ALL "${caps[@]}" \
        --device /dev/net/tun:/dev/net/tun -v "$BATS_TEST_TMPDIR:/etc/ovpn:ro" \
        --entrypoint /usr/sbin/openvpn2.6 "$IMAGE" \
        --remote "$SERVER" 1194 --dev tun --proto udp \
        --ifconfig 10.9.0.2 10.9.0.1 --secret /etc/ovpn/static.key \
        --cipher AES-256-CBC --user nobody --verb 3 2>&1
}

@test "OpenVPN completes a tunnel with the capabilities the compose file grants" {
    run run_client $CAPS
    # Not merely "did not error". OpenVPN prints this only after it has brought
    # the tunnel up AND dropped privileges — the two steps the last two bugs
    # died between.
    assert_output --partial "Initialization Sequence Completed"
}

@test "and fails without SETUID, so the check above can actually fail" {
    # The negative case, in the suite rather than in a commit message. Without
    # it the test above passes on any sufficiently permissive cap set and never
    # tells anyone that the list it read had stopped mattering.
    local without_setuid=()
    local c
    for c in $CAPS; do [[ "$c" == "SETUID" ]] || without_setuid+=("$c"); done

    run run_client "${without_setuid[@]}"
    assert_output --partial "setuid('nobody') failed: Operation not permitted"
    refute_output --partial "Initialization Sequence Completed"
}
