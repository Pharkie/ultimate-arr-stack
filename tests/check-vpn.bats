#!/usr/bin/env bats
# Unit tests for scripts/check-vpn.sh, with docker faked.
#
# Cron pings the Kuma push monitor only when the script exits 0, so the point
# of these tests is the failures: every way the VPN can be wrong, or merely
# unverifiable, must exit non-zero with a FAIL line that says which.
#
# The `docker` shim answers from one file per container under $FAKE_DOCKER:
#   status=  id=  netmode=  egress=<ip>|fail  tool=curl|wget|none
# plus $FAKE_DOCKER/.dns (ok|fail) and $FAKE_DOCKER/.stackdir, the compose
# working_dir label on gluetun. Anything other than inspect, or exec of the
# read-only probes, exits 99, so a script that changed anything would fail.

setup() {
    load helpers/setup
    SCRIPT="$REPO_ROOT/scripts/check-vpn.sh"
    FAKE_DOCKER="$BATS_TEST_TMPDIR/containers"
    DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
    STACK="$BATS_TEST_TMPDIR/stack"
    export FAKE_DOCKER DOCKER_LOG
    mkdir -p "$FAKE_DOCKER" "$STACK" "$BATS_TEST_TMPDIR/bin"

    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'SHIM'
#!/bin/bash
echo "$*" >> "$DOCKER_LOG"
get() { sed -n "s/^$2=//p" "$FAKE_DOCKER/$1" 2>/dev/null; }
cmd="${1:-}"; shift
case "$cmd" in
inspect)
    fmt="" ref=""
    while [ $# -gt 0 ]; do
        case "$1" in --type) shift 2 ;; -f|--format) fmt="$2"; shift 2 ;; *) ref="$1"; shift ;; esac
    done
    [ -f "$FAKE_DOCKER/$ref" ] || { echo "Error: No such container: $ref" >&2; exit 1; }
    case "$fmt" in
        *working_dir*) cat "$FAKE_DOCKER/.stackdir" 2>/dev/null || echo "<no value>" ;;
        *) printf '%s\n' "$fmt" | sed -e "s|{{.Id}}|$(get "$ref" id)|g" \
               -e "s|{{.State.Status}}|$(get "$ref" status)|g" \
               -e "s|{{.HostConfig.NetworkMode}}|$(get "$ref" netmode)|g" ;;
    esac ;;
exec)
    c="$1"; shift
    [ "$(get "$c" status)" = running ] || { echo "Error: container $c is not running" >&2; exit 1; }
    case "$1" in
        sh)  # sh -c 'command -v curl || command -v wget'
            case "$(get "$c" tool)" in curl) echo /usr/bin/curl ;; wget) echo /usr/bin/wget ;; *) exit 1 ;; esac ;;
        curl|wget)
            [ "$1" = "$(get "$c" tool)" ] || { echo "$1: not found" >&2; exit 127; }
            e="$(get "$c" egress)"
            [ "$e" != fail ] || { echo "$1: could not connect" >&2; exit 7; }
            echo "$e" ;;
        getent)
            [ "$(cat "$FAKE_DOCKER/.dns")" = ok ] || exit 2
            echo "104.16.132.229  $3" ;;
        nslookup) exit 1 ;;
        *) echo "fake docker: refusing exec $*" >&2; exit 99 ;;
    esac ;;
*) echo "fake docker: refusing $cmd $*" >&2; exit 99 ;;
esac
SHIM
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    # A stack with two tunnelled services and one on the plain bridge.
    cat > "$STACK/docker-compose.arr-stack.yml" <<'YML'
name: fixture
services:
  gluetun:
    image: qmcgaw/gluetun
    container_name: gluetun
  qbittorrent:
    image: example/qbittorrent
    container_name: qbittorrent
    network_mode: "service:gluetun"
  prowlarr:
    image: example/prowlarr
    container_name: prowlarr
    network_mode: service:gluetun   # unquoted, with a comment
  sonarr:
    image: example/sonarr
    container_name: sonarr
YML
    printf '%s\n' "$STACK" > "$FAKE_DOCKER/.stackdir"
    echo ok > "$FAKE_DOCKER/.dns"

    VPN_IP=198.51.100.7
    HOST_IP=203.0.113.9
    container gluetun   status=running id="$(printf 'a%.0s' {1..64})" netmode=arr-stack tool=wget egress=$VPN_IP
    container sonarr    status=running id=s netmode=arr-stack tool=curl egress=$HOST_IP
    container qbittorrent status=running id=q netmode=container:x tool=curl egress=$VPN_IP
    container prowlarr  status=running id=p netmode=container:x tool=curl egress=$VPN_IP
}

# container NAME key=value...
container() {
    local name="$1"
    shift
    printf '%s\n' "$@" > "$FAKE_DOCKER/$name"
}

# set_field NAME key value
set_field() {
    sed -i.bak "s/^$2=.*/$2=$3/" "$FAKE_DOCKER/$1" && rm -f "$FAKE_DOCKER/$1.bak"
}

@test "healthy: every check passes, exit 0" {
    run "$SCRIPT"
    assert_success
    assert_output --partial "OK    DNS inside gluetun: cloudflare.com -> 104.16.132.229"
    assert_output --partial "OK    gluetun exits as $VPN_IP; the host exits as 203.0.x.x (via sonarr)"
    assert_output --partial "OK    qbittorrent exits through gluetun ($VPN_IP)"
    assert_output --partial "OK    prowlarr exits through gluetun ($VPN_IP)"
    assert_output --partial "PASS: VPN verified"
    refute_output --partial "FAIL"
    # sonarr is not tunnelled, so it is the probe and nothing else.
    refute_output --partial "sonarr exits through"
    # Read-only: every docker call was an inspect or a probe exec.
    run grep -vE '^(inspect|exec [a-z]+ (sh -c|curl|wget|getent|nslookup) )' "$DOCKER_LOG"
    assert_output ""
}

@test "works when piped to bash -s, finding the compose files via gluetun's labels" {
    run bash -s < "$SCRIPT"
    assert_success
    assert_output --partial "tunnelled services from $STACK: prowlarr qbittorrent"
    assert_output --partial "PASS: VPN verified"
}

@test "FAILS: gluetun exits as the host (the tunnel carries nothing)" {
    set_field gluetun egress "$HOST_IP"
    set_field qbittorrent egress "$HOST_IP"
    set_field prowlarr egress "$HOST_IP"
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  LEAK: gluetun exits as the host's own IP (203.0.x.x)"
    refute_output --partial "PASS"
}

@test "FAILS: a tunnelled service exits as the host" {
    set_field qbittorrent egress "$HOST_IP"
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  LEAK: qbittorrent exits as the host's own IP (203.0.x.x), not through gluetun"
    assert_output --partial "OK    prowlarr exits through gluetun"
}

@test "FAILS: a tunnelled service exits from some third IP" {
    set_field prowlarr egress 192.0.2.44
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  prowlarr exits as 192.0.2.44, not gluetun's $VPN_IP"
}

@test "FAILS: a service whose egress cannot be measured is a failure, not a skip" {
    set_field prowlarr egress fail
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  prowlarr: cannot measure its egress: no IP-echo service answered"
}

@test "FAILS: a tunnelled service that is not running, or has no curl/wget" {
    set_field qbittorrent status exited
    set_field prowlarr tool none
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  qbittorrent: cannot measure its egress: container is exited"
    assert_output --partial "FAIL  prowlarr: cannot measure its egress: no curl or wget found in it"
}

@test "FAILS: a tunnelled service in the compose file with no container at all" {
    rm "$FAKE_DOCKER/prowlarr"
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  prowlarr: cannot measure its egress: Error: No such container: prowlarr"
}

@test "FAILS: DNS does not resolve inside gluetun" {
    echo fail > "$FAKE_DOCKER/.dns"
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  DNS inside gluetun: cloudflare.com did not resolve"
}

@test "FAILS: the host's own egress cannot be measured, so a leak could not be seen" {
    set_field sonarr egress fail
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  cannot measure the host's own egress via sonarr"
}

@test "FAILS: a HOST_PROBE inside gluetun's namespace is refused" {
    HOST_PROBE=qbittorrent run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  HOST_PROBE=qbittorrent shares another container's network namespace"
}

@test "FAILS: gluetun missing or stopped" {
    set_field gluetun status exited
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  gluetun is exited, not running"
    rm "$FAKE_DOCKER/gluetun"
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  cannot inspect gluetun: Error: No such container: gluetun"
}

@test "FAILS: compose files that bind nothing to gluetun never pass vacuously" {
    sed -i.bak '/network_mode/d' "$STACK/docker-compose.arr-stack.yml"
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "is bound to gluetun's network namespace"
    refute_output --partial "PASS"
}
