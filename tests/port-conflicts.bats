#!/usr/bin/env bats
# Host-port and static-IP clashes: check_conflicts (scripts/lib/check-conflicts.sh),
# the hook's check 4, which reads the rendered compose model.
#
# The grep it replaced read the YAML text and wanted `- "HOST:CONTAINER"` with
# nothing after it. It saw 3 of the 18 ports this repo publishes, and giving
# Pi-hole qBittorrent's 8085 passed it, this suite and `docker compose config`.
# Every negative below hides its clash in a way that grep could not see, so
# each one passed on the old code. Found 2026-09-28.

setup() {
    load helpers/setup
    T="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$T"
}

require_tools() {
    docker compose version &>/dev/null || skip "docker compose CLI not available"
    python3 -c 'import json' &>/dev/null || skip "python3 not available"
}

# check_conflicts with the repo root pointed at $1 (default: the throwaway
# repo). PATH_PREFIX, when set, goes in front of PATH, for stubs.
run_check() {
    local root="${1:-$T}" path="$PATH"
    [[ -n "${PATH_PREFIX:-}" ]] && path="$PATH_PREFIX:$PATH"
    run env PATH="$path" bash -c "
        source '$REPO_ROOT/scripts/lib/check-conflicts.sh'
        git() { echo '$root'; }
        check_conflicts
    "
}

# Port entries the files declare, counted from the text by indentation, not
# by what each entry looks like, so comments, suffixes, host IPs and the long
# syntax don't hide one. No entry in this repo maps a range, so this must
# equal the number the check reads from the rendered model.
count_declared_ports() {
    awk '
        FNR == 1 { inp = 0 }
        /^[ \t]*(#|$)/ { next }
        {
            match($0, /^ */); ind = RLENGTH
            if (inp) {
                if (ind < pind || (ind == pind && $0 !~ /^ *- /)) inp = 0
                else {
                    if ($0 ~ /^ *- / && (item < 0 || ind == item)) { item = ind; n++ }
                    next
                }
            }
            if ($0 ~ /^ *ports:[ \t]*(#.*)?$/) { inp = 1; pind = ind; item = -1 }
        }
        END { print n + 0 }
    ' "$@"
}

# --- the real compose files ----------------------------------------------

@test "the real compose files: no clashes, and every published port and static IP is checked" {
    require_tools
    local files ports ips
    read -ra files <<< "$(get_compose_files)"
    ports=$(count_declared_ports "${files[@]}")
    ips=$(cat "${files[@]}" | grep -cE '^[[:space:]]*ipv4_address:')
    # The old grep saw 3 ports; a count this low means the counter went blind.
    [[ $ports -gt 3 ]] || fail "counted only $ports declared ports"
    run_check "$REPO_ROOT"
    assert_success
    assert_output --partial "OK: No conflicts among $ports published host ports and $ips static IPs in ${#files[@]} compose files"
}

# The clash that proved the old check blind, on the real files.
@test "the real compose files: Pi-hole's web UI moved onto qBittorrent's 8085 is caught" {
    require_tools
    cp "$REPO_ROOT"/docker-compose*.yml "$T/"
    sed 's/"8081:80"/"8085:80"/' "$REPO_ROOT/docker-compose.arr-stack.yml" > "$T/docker-compose.arr-stack.yml"
    grep -q '"8085:80"' "$T/docker-compose.arr-stack.yml" || fail "the edit did not apply"
    run_check
    assert_failure
    assert_output --partial "ERROR: Duplicate ports in docker-compose.arr-stack.yml:"
    assert_output --partial "Port 8085/tcp is used multiple times: gluetun 8085->8085/tcp (for flaresolverr, prowlarr, qbittorrent, sabnzbd); pihole 8085->80/tcp"
}

# --- forms the old grep could not see ------------------------------------

@test "a port behind a trailing comment is checked" {
    require_tools
    cat > "$T/docker-compose.yml" <<'EOF'
services:
  gluetun:
    image: alpine:3.20
    ports:
      - "8085:8085"   # qBittorrent
  pihole:
    image: alpine:3.20
    ports:
      - "8085:80"  # Web UI
EOF
    run_check
    assert_failure
    assert_output --partial "Port 8085/tcp is used multiple times: gluetun 8085->8085/tcp; pihole 8085->80/tcp"
}

@test "a /udp port is checked, and tcp and udp on one port don't clash" {
    require_tools
    cat > "$T/docker-compose.yml" <<'EOF'
services:
  jellyfin:
    image: alpine:3.20
    ports:
      - "1900:1900/udp"
  dlna:
    image: alpine:3.20
    ports:
      - "1900:1900/udp"
      - "1900:1900/tcp"
EOF
    run_check
    assert_failure
    assert_output --partial "Port 1900/udp is used multiple times: dlna 1900->1900/udp; jellyfin 1900->1900/udp"
    refute_output --partial "1900/tcp is used"
}

@test "a port with a host-IP prefix is checked against the wildcard and the same IP" {
    require_tools
    cat > "$T/docker-compose.yml" <<'EOF'
services:
  pihole:
    image: alpine:3.20
    ports:
      - "${NAS_IP}:8080:80"
      - "127.0.0.1:9000:9000"
  web:
    image: alpine:3.20
    ports:
      - "8080:8080"
      - "127.0.0.1:9000:80"
EOF
    run_check
    assert_failure
    assert_output --partial "Port 8080/tcp is used multiple times: pihole 192.168.1.100:8080->80/tcp; web 8080->8080/tcp"
    assert_output --partial "Port 9000/tcp is used multiple times: pihole 127.0.0.1:9000->9000/tcp; web 127.0.0.1:9000->80/tcp"
}

@test "the same port on two different host IPs doesn't clash" {
    require_tools
    cat > "$T/docker-compose.yml" <<'EOF'
services:
  a:
    image: alpine:3.20
    ports:
      - "127.0.0.1:8080:80"
  b:
    image: alpine:3.20
    ports:
      - "127.0.0.2:8080:80"
EOF
    run_check
    assert_success
    assert_output --partial "OK: No conflicts among 2 published host ports"
}

# The old grep read text, so profiles never hid anything from it; a render
# that doesn't ask for every profile would. The long syntax here is what hid
# the port from the old code.
@test "a service behind a profile is checked" {
    require_tools
    cat > "$T/docker-compose.yml" <<'EOF'
services:
  web:
    image: alpine:3.20
    ports:
      - "8080:80"
  debug:
    image: alpine:3.20
    profiles: ["manual"]
    ports:
      - target: 8080
        published: 8080
EOF
    run_check
    assert_failure
    assert_output --partial "Port 8080/tcp is used multiple times: debug 8080->8080/tcp; web 8080->80/tcp"
}

@test "a port two services take from one YAML anchor is checked" {
    require_tools
    cat > "$T/docker-compose.yml" <<'EOF'
x-web: &web
  image: alpine:3.20
  ports:
    - "8080:80"
services:
  a:
    <<: *web
  b:
    <<: *web
EOF
    run_check
    assert_failure
    assert_output --partial "Port 8080/tcp is used multiple times: a 8080->80/tcp; b 8080->80/tcp"
}

# Separate projects, one host. gluetun publishes for the services in its
# namespace, so the clash is gluetun's and names who is behind it.
@test "a clash across two files is caught, and a port gluetun publishes names its services" {
    require_tools
    cat > "$T/docker-compose.arr-stack.yml" <<'EOF'
services:
  gluetun:
    image: alpine:3.20
    ports:
      - "8085:8085"   # qBittorrent
  qbittorrent:
    image: alpine:3.20
    network_mode: "service:gluetun"
EOF
    cat > "$T/docker-compose.utilities.yml" <<'EOF'
services:
  uptime-kuma:
    image: alpine:3.20
    ports:
      - "8085:3001"  # Local network access only
EOF
    run_check
    assert_failure
    assert_output --partial "ERROR: Port 8085/tcp used across multiple files:"
    assert_output --partial "- docker-compose.arr-stack.yml: gluetun 8085->8085/tcp (for qbittorrent)"
    assert_output --partial "- docker-compose.utilities.yml: uptime-kuma 8085->3001/tcp"
}

# Moved from pre-commit-checks.bats: the plain forms the old grep did see.
@test "plain duplicate ports within a file and across files are still caught" {
    require_tools
    cp "$REPO_ROOT/tests/fixtures/compose-port-conflict.yml" "$T/docker-compose.conflict.yml"
    run_check
    assert_failure
    assert_output --partial "Duplicate ports in docker-compose.conflict.yml"

    rm "$T/docker-compose.conflict.yml"
    printf 'services:\n  svc-a:\n    image: alpine:3.20\n    ports:\n      - "9999:80"\n' > "$T/docker-compose.a.yml"
    printf 'services:\n  svc-b:\n    image: alpine:3.20\n    ports:\n      - "9999:8080"\n' > "$T/docker-compose.b.yml"
    run_check
    assert_failure
    assert_output --partial "Port 9999/tcp used across multiple files"
}

# --- shared network namespaces -------------------------------------------

@test "ports on a service inside gluetun's namespace are an error" {
    require_tools
    cat > "$T/docker-compose.yml" <<'EOF'
services:
  gluetun:
    image: alpine:3.20
  qbittorrent:
    image: alpine:3.20
    network_mode: "service:gluetun"
    ports:
      - "8085:8085"
EOF
    run_check
    assert_failure
    assert_output --partial "qbittorrent has network_mode: service:gluetun, so Docker refuses to publish ports on it. Publish them on gluetun instead."
}

# --- static IPs ----------------------------------------------------------

@test "a static IP given through a variable is checked" {
    require_tools
    cat > "$T/docker-compose.yml" <<'EOF'
name: lan-test
services:
  traefik:
    image: alpine:3.20
    networks:
      lan:
        ipv4_address: ${TRAEFIK_LAN_IP}
  other:
    image: alpine:3.20
    networks:
      lan:
        ipv4_address: 192.168.1.11
networks:
  lan:
EOF
    run_check
    assert_failure
    assert_output --partial "IP 192.168.1.11 on network lan-test_lan is assigned to multiple services: other, traefik"
}

@test "a static IP clash on the shared arr-stack network is caught across files" {
    require_tools
    cat > "$T/docker-compose.arr-stack.yml" <<'EOF'
services:
  gluetun:
    image: alpine:3.20
    networks:
      arr-stack:
        ipv4_address: 172.20.0.3
networks:
  arr-stack:
    name: arr-stack
EOF
    cat > "$T/docker-compose.neighbour.yml" <<'EOF'
services:
  neighbour:
    image: alpine:3.20
    networks:
      arr-stack:
        ipv4_address: 172.20.0.3
networks:
  arr-stack:
    external: true
EOF
    run_check
    assert_failure
    assert_output --partial "ERROR: IP 172.20.0.3 on network arr-stack used across multiple files:"
    assert_output --partial "- docker-compose.arr-stack.yml: gluetun"
    assert_output --partial "- docker-compose.neighbour.yml: neighbour"
}

# The old check compared bare address strings, so this was a false alarm.
@test "one static IP on two different networks doesn't clash" {
    require_tools
    printf 'name: one\nservices:\n  a:\n    image: alpine:3.20\n    networks:\n      net:\n        ipv4_address: 10.1.0.5\nnetworks:\n  net:\n' > "$T/docker-compose.one.yml"
    printf 'name: two\nservices:\n  b:\n    image: alpine:3.20\n    networks:\n      net:\n        ipv4_address: 10.1.0.5\nnetworks:\n  net:\n' > "$T/docker-compose.two.yml"
    run_check
    assert_success
    assert_output --partial "OK: No conflicts among 0 published host ports and 2 static IPs in 2 compose files"
}

@test "all static IPs within 172.20.0.0/24 or 10.8.1.0/24 range" {
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        [[ "$ip" == *'${'* ]] && continue
        if [[ "$ip" =~ ^172\.20\.0\.[0-9]+$ ]] || [[ "$ip" =~ ^10\.8\.1\.[0-9]+$ ]]; then
            continue
        fi
        fail "Static IP $ip is outside expected ranges (172.20.0.0/24 or 10.8.1.0/24)"
    done < <(get_all_ips)
}

# --- when it cannot check ------------------------------------------------

@test "a compose file that cannot be rendered fails the check, not passes it" {
    require_tools
    printf 'services:\n  x:\n    image: alpine:3.20\n    ports:\n      - "not-a-port"\n' > "$T/docker-compose.yml"
    run_check
    [[ $status -eq 2 ]] || fail "expected exit 2, got $status"
    assert_output --partial "ERROR: docker-compose.yml could not be rendered by docker compose config"
    refute_output --partial "OK:"
}

@test "without docker compose or python3 it says SKIPPED and passes, never OK" {
    cat > "$T/docker-compose.yml" <<'EOF'
services:
  a:
    image: alpine:3.20
    ports:
      - "8080:80"
  b:
    image: alpine:3.20
    ports:
      - "8080:80"
EOF
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/docker"
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    PATH_PREFIX="$BATS_TEST_TMPDIR/bin" run_check
    assert_success
    assert_output --partial "SKIPPED: docker compose not available"
    refute_output --partial "OK:"

    command -v docker &>/dev/null && docker compose version &>/dev/null \
        || skip "docker compose CLI not available for the python3 half"
    rm "$BATS_TEST_TMPDIR/bin/docker"
    printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/python3"
    chmod +x "$BATS_TEST_TMPDIR/bin/python3"
    PATH_PREFIX="$BATS_TEST_TMPDIR/bin" run_check
    assert_success
    assert_output --partial "SKIPPED: python3 not available"
    refute_output --partial "OK:"
}
