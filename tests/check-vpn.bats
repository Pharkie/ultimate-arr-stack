#!/usr/bin/env bats
# Unit tests for scripts/check-vpn.sh, with docker faked.
#
# Cron pings the Kuma push monitor only when the script exits 0, so the point
# of these tests is the failures: every way the VPN can be wrong, or merely
# unverifiable, must exit non-zero with a FAIL line that says which.
#
# The `docker` shim answers from one file per container under $FAKE_DOCKER:
#   status=  id=  netmode=  egress=<ip>|fail  tool=curl|wget|none  provider=
# plus $FAKE_DOCKER/.dns (ok|fail), $FAKE_DOCKER/.stackdir, the compose
# working_dir label on gluetun, and $FAKE_DOCKER/<name>.log for docker logs.
# Anything other than inspect, logs, or exec of the read-only probes exits 99,
# so a script that changed anything would fail. A fake host `curl` records the
# Uptime Kuma push in $CURL_LOG, one argument per line.

setup() {
    load helpers/setup
    SCRIPT="$REPO_ROOT/scripts/check-vpn.sh"
    FAKE_DOCKER="$BATS_TEST_TMPDIR/containers"
    DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
    CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
    STACK="$BATS_TEST_TMPDIR/stack"
    export FAKE_DOCKER DOCKER_LOG CURL_LOG
    unset VPN_CHECK_PUSH_URL VPN_NO_ANSWER_MINUTES
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
        *VPN_SERVICE_PROVIDER*) get "$ref" provider ;;
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
logs)
    ref="${*: -1}"
    [ -f "$FAKE_DOCKER/$ref" ] || { echo "Error: No such container: $ref" >&2; exit 1; }
    cat "$FAKE_DOCKER/$ref.log" 2>/dev/null ;;
*) echo "fake docker: refusing $cmd $*" >&2; exit 99 ;;
esac
SHIM
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SHIM'
#!/bin/bash
printf '%s\n' "$@" >> "$CURL_LOG"
SHIM
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
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
    container gluetun   status=running id="$(printf 'a%.0s' {1..64})" netmode=arr-stack tool=wget egress=$VPN_IP provider=surfshark
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

# no_way_out: gluetun and everything behind it reach nothing; the host does.
no_way_out() {
    set_field gluetun egress fail
    set_field qbittorrent egress fail
    set_field prowlarr egress fail
}

# gluetun_log AGO STEP SERVER...: `docker logs -t gluetun` when no server has
# answered for AGO seconds: the start banner, then a "Connecting to" and a
# restart every STEP seconds, through SERVER... in turn, until 3 s ago. The
# lines are the real ones from the 2026-11-03 outage, with fresh timestamps.
gluetun_log() {
    local ago=$1 step=$2
    shift 2
    awk -v now="$(date +%s)" -v ago="$ago" -v step="$step" -v servers="$*" '
        function iso(t,   s, z, era, doe, yoe, doy, mp, d, m, y) {
            s = t % 86400; z = int(t / 86400) + 719468
            era = int(z / 146097); doe = z - era * 146097
            yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
            y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
            mp = int((5 * doy + 2) / 153); d = doy - int((153 * mp + 2) / 5) + 1
            m = mp < 10 ? mp + 3 : mp - 9
            if (m <= 2) y++
            return sprintf("%04d-%02d-%02dT%02d:%02d:%02d", y, m, d, int(s / 3600), int(s % 3600 / 60), s % 60)
        }
        BEGIN {
            k = split(servers, srv, " ")
            t = now - ago
            print iso(t - 20) ".000000000Z Running version v3.41.3 built on 2026-07-30T14:53:40.495Z (commit 3d1e20c)"
            for (i = 0; t + i * step <= now - 3; i++) {
                c = t + i * step
                print iso(c - 6) ".000000000Z " iso(c - 6) "Z INFO [wireguard] Connecting to " srv[i % k + 1]
                print iso(c - 6) ".000000000Z " iso(c - 6) "Z INFO [wireguard] Wireguard setup is complete. Note Wireguard is a silent protocol and it may or may not work, without giving any error message. Typically i/o timeout errors indicate the Wireguard connection is not working."
                print iso(c) ".000000000Z " iso(c) "Z WARN [vpn] restarting VPN because it failed to pass the healthcheck: startup check: all check tries failed: parallel attempt 1/2 failed: dialing: dial tcp4 1.1.1.1:443: i/o timeout, parallel attempt 2/2 failed: dialing: dial tcp4 8.8.8.8:443: i/o timeout"
            }
        }' > "$FAKE_DOCKER/gluetun.log"
}

# The seven Netherlands servers gluetun cycled through on 2026-11-03.
NL="143.244.42.66:51820 81.19.208.109:51820 81.19.209.51:51820 212.102.35.204:51820 81.19.208.85:51820 89.46.223.187:51820 143.244.42.74:51820"

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
    # Nothing pushed: the success push belongs to the cron line.
    [ ! -e "$CURL_LOG" ]
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

# ---------------------------------------------------------------------------
# Why gluetun has no way out, read from its log
# ---------------------------------------------------------------------------

@test "names the subscription when no server has answered for hours (the 2026-11-03 outage, replayed)" {
    no_way_out
    gluetun_log 18000 60 $NL
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  No VPN server has answered for 5 h across 7 servers (300 attempts). Most likely the Surfshark subscription has expired or the WireGuard key was revoked: check my.surfshark.com. If the account is active, check that outbound UDP 51820 is not blocked."
    # It explains the lines it sits above, and leaves them in place.
    assert_output --partial "FAIL  cannot measure gluetun's egress: no IP-echo service answered"
    assert_output --partial "FAIL  qbittorrent: cannot measure its egress"
    # Still read-only, logs included.
    run grep -vE '^(inspect|logs -t gluetun$|exec [a-z]+ (sh -c|curl|wget|getent|nslookup) )' "$DOCKER_LOG"
    assert_output ""
}

@test "a run of restarts only minutes old is not yet blamed on the account" {
    no_way_out
    gluetun_log 120 6 $NL
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  The VPN has not connected for 2 min ("
    assert_output --partial "Too soon to rule out a passing outage; if it lasts, check the Surfshark subscription (my.surfshark.com) first, then outbound UDP 51820"
    refute_output --partial "Most likely"
}

@test "VPN_NO_ANSWER_MINUTES moves the line between the two" {
    no_way_out
    gluetun_log 600 6 $NL
    VPN_NO_ANSWER_MINUTES=15 run "$SCRIPT"
    assert_output --partial "Too soon to rule out a passing outage"
    VPN_NO_ANSWER_MINUTES=5 run "$SCRIPT"
    assert_output --partial "FAIL  No VPN server has answered for 10 min across 7 servers (100 attempts). Most likely"
}

@test "one server failing on its own is told apart from none answering" {
    no_way_out
    gluetun_log 1800 6 81.19.209.51:51820
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  VPN server 81.19.209.51:51820 has not answered for 30 min (300 attempts) and gluetun has tried no other. If the server selection allows only that one, widen it"
    refute_output --partial "Most likely"
}

@test "a blip that a server answered is over: no cause is guessed" {
    no_way_out
    gluetun_log 30 6 $NL
    echo "$(tail -n 1 "$FAKE_DOCKER/gluetun.log" | cut -d' ' -f1) INFO [ip getter] Public IP address is 81.19.208.86 (Netherlands)" >> "$FAKE_DOCKER/gluetun.log"
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  cannot measure gluetun's egress"
    refute_output --partial "has not connected"
    refute_output --partial "has answered"
}

@test "restarts that stopped minutes ago are not an ongoing outage" {
    no_way_out
    gluetun_log 3600 60 $NL
    # Keep only the lines from before the last ten minutes.
    head -n 150 "$FAKE_DOCKER/gluetun.log" > "$FAKE_DOCKER/gluetun.log.new"
    mv "$FAKE_DOCKER/gluetun.log.new" "$FAKE_DOCKER/gluetun.log"
    run "$SCRIPT"
    refute_output --partial "has answered"
    refute_output --partial "has not connected"
}

@test "an earlier run of restarts that ended is not counted into a new one" {
    no_way_out
    # An hour of restarts that stopped 20 min ago, then two minutes of new ones.
    gluetun_log 4800 60 $NL
    head -n 181 "$FAKE_DOCKER/gluetun.log" > "$BATS_TEST_TMPDIR/old.log"
    gluetun_log 120 6 $NL
    sed 1d "$FAKE_DOCKER/gluetun.log" >> "$BATS_TEST_TMPDIR/old.log"
    mv "$BATS_TEST_TMPDIR/old.log" "$FAKE_DOCKER/gluetun.log"
    run "$SCRIPT"
    assert_output --partial "FAIL  The VPN has not connected for 2 min ("
}

@test "a log docker has rotated mid-outage says 'at least'" {
    no_way_out
    gluetun_log 7200 60 $NL
    sed -i.bak 1d "$FAKE_DOCKER/gluetun.log"
    run "$SCRIPT"
    assert_output --partial "FAIL  No VPN server has answered for at least 2 h across 7 servers"
}

@test "when the host cannot get out either, the VPN is not blamed" {
    no_way_out
    set_field sonarr egress fail
    gluetun_log 18000 60 $NL
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "FAIL  The NAS's own connection is failing too (sonarr reached no IP-echo service), so this is not the VPN: check the internet connection and DNS (Pi-hole) first"
    refute_output --partial "subscription"
}

@test "another provider gets its own name, and a generic pointer" {
    no_way_out
    set_field gluetun provider "ivpn"
    gluetun_log 1800 6 $NL
    run "$SCRIPT"
    assert_output --partial "Most likely the ivpn subscription has expired or the WireGuard key was revoked: check the provider's website."
}

# ---------------------------------------------------------------------------
# The down push to Uptime Kuma
# ---------------------------------------------------------------------------

@test "Kuma push: a failing run pushes status=down with the cause, without the cron URL's query" {
    no_way_out
    gluetun_log 18000 60 $NL
    VPN_CHECK_PUSH_URL="http://kuma.test:3001/api/push/TOKEN?status=up&msg=OK" run "$SCRIPT"
    assert_failure 1
    assert_output --partial "Reported down to Uptime Kuma"
    run cat "$CURL_LOG"
    assert_line "status=down"
    assert_line "msg=No VPN server has answered for 5 h across 7 servers (300 attempts). Most likely the Surfshark subscription has expired or the WireGuard key was revoked: check my.surfshark.com. If the account is active, check that outbound UDP 51820 is not blocked. WireGuard never says why, so the three look the same from here"
    assert_line "http://kuma.test:3001/api/push/TOKEN"
    refute_output --partial "status=up"
}

@test "Kuma push: read from the stack's .env; any failure sends its first FAIL line" {
    printf '%s\n' 'VPN_CHECK_PUSH_URL="http://kuma.test:3001/api/push/FROMENV"' > "$STACK/.env"
    set_field prowlarr egress 192.0.2.44
    run "$SCRIPT"
    assert_failure 1
    run cat "$CURL_LOG"
    assert_line "msg=prowlarr exits as 192.0.2.44, not gluetun's $VPN_IP (if gluetun reconnected mid-check, re-run)"
    assert_line "http://kuma.test:3001/api/push/FROMENV"
}

@test "Kuma push: gluetun not running is pushed too" {
    VPN_CHECK_PUSH_URL="http://kuma.test:3001/api/push/T" run "$SCRIPT"
    assert_success
    [ ! -e "$CURL_LOG" ]
    set_field gluetun status exited
    VPN_CHECK_PUSH_URL="http://kuma.test:3001/api/push/T" run "$SCRIPT"
    assert_failure 1
    run cat "$CURL_LOG"
    assert_line "msg=gluetun is exited, not running"
}

@test "Kuma push: without VPN_CHECK_PUSH_URL nothing is sent" {
    no_way_out
    gluetun_log 18000 60 $NL
    run "$SCRIPT"
    assert_failure 1
    refute_output --partial "Uptime Kuma"
    [ ! -e "$CURL_LOG" ]
}
