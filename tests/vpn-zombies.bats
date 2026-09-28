#!/usr/bin/env bats
# Unit tests for scripts/detect-vpn-zombies.sh, plus the guards that keep its
# TUNNELED list, and the e2e suite's GLUETUN_NAMESPACE_SERVICES, in step with
# the compose files.
#
# Docker is faked by a `docker` shim first on PATH. It answers only
# `docker inspect [--type container] -f FORMAT REF`, from one file per
# container under $FAKE_DOCKER, and exits 99 on any other subcommand, so a
# script that tried to restart or modify anything would fail loudly here.

setup() {
    load helpers/setup
    SCRIPT="$REPO_ROOT/scripts/detect-vpn-zombies.sh"
    FAKE_DOCKER="$BATS_TEST_TMPDIR/containers"
    DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
    export FAKE_DOCKER DOCKER_LOG
    mkdir -p "$FAKE_DOCKER" "$BATS_TEST_TMPDIR/bin"

    cat > "$BATS_TEST_TMPDIR/bin/docker" <<'SHIM'
#!/bin/bash
echo "$*" >> "$DOCKER_LOG"
[ "${1:-}" = inspect ] || { echo "fake docker: refusing '$*'" >&2; exit 99; }
shift
fmt="" ref=""
while [ $# -gt 0 ]; do
    case "$1" in
        --type) shift 2 ;;
        -f|--format) fmt="$2"; shift 2 ;;
        *) ref="$1"; shift ;;
    esac
done
for f in "$FAKE_DOCKER"/*; do
    [ -f "$f" ] || continue
    name="${f##*/}"
    id="$(sed -n 's/^id=//p' "$f")"
    if [ "$ref" = "$name" ] || { [ -n "$id" ] && [ "$ref" = "$id" ]; }; then
        printf '%s\n' "$fmt" | sed \
            -e "s|{{.Id}}|$id|g" \
            -e "s|{{.Name}}|/$name|g" \
            -e "s|{{.HostConfig.NetworkMode}}|$(sed -n 's/^netmode=//p' "$f")|g" \
            -e "s|{{.State.Status}}|$(sed -n 's/^status=//p' "$f")|g"
        exit 0
    fi
done
echo "Error: No such container: $ref" >&2
exit 1
SHIM
    chmod +x "$BATS_TEST_TMPDIR/bin/docker"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    # Full-length IDs, as Docker records them in HostConfig.NetworkMode.
    GLUETUN_ID="$(printf 'a%.0s' {1..64})"
    OLD_ID="$(printf 'b%.0s' {1..64})"
    OTHER_ID="$(printf 'c%.0s' {1..64})"
}

# container NAME ID NETMODE [STATUS]
container() {
    printf 'id=%s\nnetmode=%s\nstatus=%s\n' "$2" "$3" "${4:-running}" > "$FAKE_DOCKER/$1"
}

healthy_stack() {
    container gluetun "$GLUETUN_ID" arr-stack
    local svc n=0
    for svc in qbittorrent sabnzbd prowlarr flaresolverr; do
        n=$((n + 1))
        container "$svc" "$(printf '%064d' "$n")" "container:$GLUETUN_ID"
    done
}

# Anything but `inspect` would have exited 99 and logged; prove none happened.
assert_only_inspected() {
    run grep -v '^inspect ' "$DOCKER_LOG"
    assert_failure
    assert_output ""
}

# ---------------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------------

@test "healthy: every service is in gluetun's namespace, exit 0 with an OK line" {
    healthy_stack
    run "$SCRIPT"
    assert_success
    assert_output --partial "OK: no VPN zombies — 4 service(s) in gluetun's namespace (aaaaaaaaaaaa), 0 skipped"
    refute_output --partial "ZOMBIE"
    assert_only_inspected
}

@test "stranded on a destroyed gluetun: listed, fix suggested, exit 1" {
    healthy_stack
    container qbittorrent 0000000000000000000000000000000000000000000000000000000000000001 "container:$OLD_ID"
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "ZOMBIE  qbittorrent (running): joined to bbbbbbbbbbbb, which no longer exists; gluetun is now aaaaaaaaaaaa"
    assert_output --partial "1 service(s) stranded outside gluetun's current namespace: qbittorrent"
    assert_output --partial "up -d --no-deps --force-recreate qbittorrent"
    # Only the stranded one goes into the fix; the healthy ones are left alone.
    refute_output --partial "force-recreate qbittorrent sabnzbd"
    refute_output --partial "OK: no VPN zombies"
    assert_only_inspected
}

@test "stranded on a different, still-live container: named, exit 1" {
    healthy_stack
    container gluetun-old "$OTHER_ID" arr-stack exited
    container sabnzbd 0000000000000000000000000000000000000000000000000000000000000002 "container:$OTHER_ID" exited
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "ZOMBIE  sabnzbd (exited): joined to gluetun-old (cccccccccccc), a different container from gluetun (aaaaaaaaaaaa)"
    assert_output --partial "force-recreate sabnzbd"
}

@test "both kinds at once are all listed in one fix" {
    healthy_stack
    container gluetun-old "$OTHER_ID" arr-stack
    container qbittorrent 0000000000000000000000000000000000000000000000000000000000000001 "container:$OLD_ID"
    container flaresolverr 0000000000000000000000000000000000000000000000000000000000000004 "container:$OTHER_ID"
    run "$SCRIPT"
    assert_failure 1
    assert_output --partial "2 service(s) stranded outside gluetun's current namespace: qbittorrent flaresolverr"
    assert_output --partial "force-recreate qbittorrent flaresolverr"
}

@test "a service joined by gluetun's name, not its ID, is not a zombie" {
    healthy_stack
    container prowlarr 0000000000000000000000000000000000000000000000000000000000000003 "container:gluetun"
    run "$SCRIPT"
    assert_success
    assert_output --partial "OK      prowlarr (running) is in gluetun's namespace"
}

@test "absent and not-joined services are skipped, not reported as zombies" {
    healthy_stack
    rm "$FAKE_DOCKER/sabnzbd"
    container flaresolverr 0000000000000000000000000000000000000000000000000000000000000004 arr-stack
    run "$SCRIPT"
    assert_success
    assert_output --partial "SKIP    sabnzbd: no such container"
    assert_output --partial "SKIP    flaresolverr: not joined to any container's namespace (network mode 'arr-stack')"
    assert_output --partial "OK: no VPN zombies — 2 service(s) in gluetun's namespace (aaaaaaaaaaaa), 2 skipped"
    refute_output --partial "ZOMBIE"
}

@test "gluetun missing: a clear error and exit 2, never OK" {
    healthy_stack
    rm "$FAKE_DOCKER/gluetun"
    run "$SCRIPT"
    assert_failure 2
    assert_output --partial "ERROR: cannot inspect the gluetun container 'gluetun': Error: No such container: gluetun"
    refute_output --partial "OK:"
}

@test "gluetun with an empty ID: a clear error and exit 2, never OK" {
    healthy_stack
    container gluetun "" arr-stack
    run "$SCRIPT"
    assert_failure 2
    assert_output --partial "ERROR: docker inspect returned an empty ID for 'gluetun'"
    refute_output --partial "OK:"
}

@test "GLUETUN_CONTAINER points the comparison at another container" {
    healthy_stack
    mv "$FAKE_DOCKER/gluetun" "$FAKE_DOCKER/vpn"
    GLUETUN_CONTAINER=vpn run "$SCRIPT"
    assert_success
    assert_output --partial "in vpn's namespace (aaaaaaaaaaaa)"
}

# ---------------------------------------------------------------------------
# Drift guard: TUNNELED must name every service the compose files bind into
# gluetun's namespace. A service missing from it would never be checked, and
# the script would still print OK.
# ---------------------------------------------------------------------------

# Words of the one-line `TUNNELED=(...)` array in FILE. Prints nothing if the
# line is missing or spread over several lines.
tunneled_list() {
    sed -n 's/^TUNNELED=(\([^)]*\))[[:space:]]*\(#.*\)\{0,1\}$/\1/p' "$1" | tr -d "\"'" | tr -s ' \t' '\n' | sed '/^$/d'
}

# Container name (container_name, else the service key) of every service in
# the given compose files with network_mode service:gluetun or container:gluetun.
# Written separately from check-vpn.sh's parser, so the two can check each other.
compose_tunnelled() {
    local f
    for f in "$@"; do
        awk '
            /^[^[:space:]#]/ { if (bound) print name; svc = ""; bound = 0; next }
            /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
                if (bound) print name
                svc = $1; sub(/:$/, "", svc); name = svc; bound = 0; next
            }
            svc != "" && /^    container_name:/ { v = $2; gsub(/["\047]/, "", v); name = v }
            svc != "" && /^    network_mode:[[:space:]]*["\047]?(service|container):gluetun["\047]?[[:space:]]*(#.*)?$/ { bound = 1 }
            END { if (bound) print name }
        ' "$f"
    done
}

# Succeeds if every compose-bound service is in SCRIPT's TUNNELED list, by
# whole name. Fails, saying why, if either list comes out empty: an empty
# extraction means the parsing broke, and would otherwise pass vacuously.
tunneled_drift() {
    local script="$1" declared bound svc t found missing=""
    shift
    declared="$(tunneled_list "$script")"
    bound="$(compose_tunnelled "$@" | sort -u)"
    [ -n "$declared" ] || { echo "no TUNNELED=(...) on one line in $script"; return 1; }
    [ -n "$bound" ] || { echo "no gluetun-bound service found in: $*"; return 1; }
    for svc in $bound; do
        found=no
        for t in $declared; do
            [ "$t" = "$svc" ] && found=yes
        done
        [ "$found" = yes ] || missing="$missing $svc"
    done
    [ -z "$missing" ] || { echo "bound to gluetun in compose but missing from TUNNELED:$missing"; return 1; }
}

# A compose file with the repo's layout; each argument is "service[:network_mode]".
fixture_compose() {
    local out="$1" spec svc mode
    shift
    { echo "name: fixture"; echo "services:"
      echo "  gluetun:"; echo "    image: qmcgaw/gluetun"; echo "    container_name: gluetun"
      for spec in "$@"; do
          svc="${spec%%:*}" mode="${spec#*:}"
          echo "  $svc:"
          echo "    image: example/$svc"
          echo "    container_name: $svc"
          [ "$mode" = "$spec" ] || echo "    network_mode: \"$mode\""
      done
    } > "$out"
}

fixture_script() {
    printf '#!/bin/bash\n%s\necho body\n' "$2" > "$1"
}

@test "drift guard: TUNNELED covers every service the compose files bind into gluetun" {
    run tunneled_drift "$SCRIPT" "$REPO_ROOT"/docker-compose*.yml
    assert_success
}

@test "drift guard: TUNNELED has no stale entries the compose files no longer bind" {
    local bound t stale=""
    bound="$(compose_tunnelled "$REPO_ROOT"/docker-compose*.yml)"
    [ -n "$bound" ]
    for t in $(tunneled_list "$SCRIPT"); do
        printf '%s\n' "$bound" | grep -qxF "$t" || stale="$stale $t"
    done
    [ -z "$stale" ] || fail "in TUNNELED but not bound to gluetun in any compose file:$stale"
}

@test "drift guard: check-vpn.sh derives the same tunnelled list from the compose files" {
    run env ARR_STACK_DIR="$REPO_ROOT" "$REPO_ROOT/scripts/check-vpn.sh" --list-tunnelled
    assert_success
    [ -n "$output" ]
    assert_equal "$output" "$(compose_tunnelled "$REPO_ROOT"/docker-compose*.yml | sort -u)"
}

@test "drift guard FAILS: a bound service missing from TUNNELED" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" qbittorrent:service:gluetun sabnzbd:service:gluetun dl:service:gluetun plain
    fixture_script "$BATS_TEST_TMPDIR/s.sh" 'TUNNELED=(qbittorrent sabnzbd)'
    run tunneled_drift "$BATS_TEST_TMPDIR/s.sh" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output "bound to gluetun in compose but missing from TUNNELED: dl"
}

@test "drift guard FAILS: container:gluetun bindings count too" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" qbittorrent:service:gluetun sidecar:container:gluetun
    fixture_script "$BATS_TEST_TMPDIR/s.sh" 'TUNNELED=(qbittorrent)'
    run tunneled_drift "$BATS_TEST_TMPDIR/s.sh" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output "bound to gluetun in compose but missing from TUNNELED: sidecar"
}

@test "drift guard FAILS: names must match whole, not as substrings" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" qbittorrent:service:gluetun sabnzbd:service:gluetun
    fixture_script "$BATS_TEST_TMPDIR/s.sh" 'TUNNELED=(qbittorrent-old sab sabnzbd)'
    run tunneled_drift "$BATS_TEST_TMPDIR/s.sh" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output "bound to gluetun in compose but missing from TUNNELED: qbittorrent"
}

@test "drift guard FAILS: an empty TUNNELED" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" qbittorrent:service:gluetun
    fixture_script "$BATS_TEST_TMPDIR/s.sh" 'TUNNELED=()'
    run tunneled_drift "$BATS_TEST_TMPDIR/s.sh" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output --partial "no TUNNELED=(...) on one line"
}

@test "drift guard FAILS: TUNNELED spread over several lines" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" qbittorrent:service:gluetun
    fixture_script "$BATS_TEST_TMPDIR/s.sh" "$(printf 'TUNNELED=(\n  qbittorrent\n)')"
    run tunneled_drift "$BATS_TEST_TMPDIR/s.sh" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output --partial "no TUNNELED=(...) on one line"
}

@test "drift guard FAILS: compose files with no gluetun binding found" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" plain other
    fixture_script "$BATS_TEST_TMPDIR/s.sh" 'TUNNELED=(qbittorrent)'
    run tunneled_drift "$BATS_TEST_TMPDIR/s.sh" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output --partial "no gluetun-bound service found"
}

# ---------------------------------------------------------------------------
# Drift guard: GLUETUN_NAMESPACE_SERVICES in tests/e2e/helpers.ts is what the
# e2e egress and namespace checks iterate over. It must name exactly the
# services the compose files bind into gluetun: one missing is never checked
# for a leak, and a stale one points the e2e run at a container that isn't
# tunnelled.
# ---------------------------------------------------------------------------

# Names in FILE's one-line `export const GLUETUN_NAMESPACE_SERVICES = [...]`.
# Prints nothing if the line is missing or spread over several lines.
e2e_tunnelled_list() {
    sed -n 's/^export const GLUETUN_NAMESPACE_SERVICES = \[\([^]]*\)\].*$/\1/p' "$1" |
        tr -d "\"' \t" | tr ',' '\n' | sed '/^$/d'
}

# Succeeds if FILE's GLUETUN_NAMESPACE_SERVICES and the compose bindings are
# the same set of whole names. Fails, saying why, if they differ or if either
# list comes out empty.
e2e_tunnelled_drift() {
    local ts="$1" declared bound svc missing="" extra=""
    shift
    declared="$(e2e_tunnelled_list "$ts" | sort -u)"
    bound="$(compose_tunnelled "$@" | sort -u)"
    [ -n "$declared" ] || { echo "no one-line GLUETUN_NAMESPACE_SERVICES = [...] in $ts"; return 1; }
    [ -n "$bound" ] || { echo "no gluetun-bound service found in: $*"; return 1; }
    for svc in $bound; do
        printf '%s\n' "$declared" | grep -qxF "$svc" || missing="$missing $svc"
    done
    for svc in $declared; do
        printf '%s\n' "$bound" | grep -qxF "$svc" || extra="$extra $svc"
    done
    [ -n "$missing$extra" ] || return 0
    [ -z "$missing" ] || echo "bound to gluetun in compose but missing from GLUETUN_NAMESPACE_SERVICES:$missing"
    [ -z "$extra" ] || echo "in GLUETUN_NAMESPACE_SERVICES but not bound to gluetun in any compose file:$extra"
    return 1
}

fixture_ts() {
    printf '%s\n' "import { x } from './y';" "$2" "export const OTHER = ['qbittorrent'] as const;" > "$1"
}

@test "drift guard: e2e GLUETUN_NAMESPACE_SERVICES equals the compose gluetun bindings" {
    run e2e_tunnelled_drift "$REPO_ROOT/tests/e2e/helpers.ts" "$REPO_ROOT"/docker-compose*.yml
    assert_success
    assert_output ""
}

@test "e2e drift guard FAILS: a bound service missing from GLUETUN_NAMESPACE_SERVICES" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" qbittorrent:service:gluetun sabnzbd:service:gluetun dl:container:gluetun plain
    fixture_ts "$BATS_TEST_TMPDIR/h.ts" "export const GLUETUN_NAMESPACE_SERVICES = ['qbittorrent', 'sabnzbd'] as const;"
    run e2e_tunnelled_drift "$BATS_TEST_TMPDIR/h.ts" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output "bound to gluetun in compose but missing from GLUETUN_NAMESPACE_SERVICES: dl"
}

@test "e2e drift guard FAILS: a name no compose file binds" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" qbittorrent:service:gluetun plain
    fixture_ts "$BATS_TEST_TMPDIR/h.ts" "export const GLUETUN_NAMESPACE_SERVICES = ['qbittorrent', 'plain'] as const;"
    run e2e_tunnelled_drift "$BATS_TEST_TMPDIR/h.ts" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output "in GLUETUN_NAMESPACE_SERVICES but not bound to gluetun in any compose file: plain"
}

@test "e2e drift guard FAILS: names must match whole, not as substrings" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" qbittorrent:service:gluetun sabnzbd:service:gluetun
    fixture_ts "$BATS_TEST_TMPDIR/h.ts" 'export const GLUETUN_NAMESPACE_SERVICES = ["qbit", "sabnzbd"] as const;'
    run e2e_tunnelled_drift "$BATS_TEST_TMPDIR/h.ts" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output "bound to gluetun in compose but missing from GLUETUN_NAMESPACE_SERVICES: qbittorrent
in GLUETUN_NAMESPACE_SERVICES but not bound to gluetun in any compose file: qbit"
}

@test "e2e drift guard FAILS: an empty GLUETUN_NAMESPACE_SERVICES" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" qbittorrent:service:gluetun
    fixture_ts "$BATS_TEST_TMPDIR/h.ts" "export const GLUETUN_NAMESPACE_SERVICES = [] as const;"
    run e2e_tunnelled_drift "$BATS_TEST_TMPDIR/h.ts" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output --partial "no one-line GLUETUN_NAMESPACE_SERVICES = [...]"
}

@test "e2e drift guard FAILS: GLUETUN_NAMESPACE_SERVICES spread over several lines" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" qbittorrent:service:gluetun
    fixture_ts "$BATS_TEST_TMPDIR/h.ts" "$(printf "export const GLUETUN_NAMESPACE_SERVICES = [\n  'qbittorrent',\n] as const;")"
    run e2e_tunnelled_drift "$BATS_TEST_TMPDIR/h.ts" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output --partial "no one-line GLUETUN_NAMESPACE_SERVICES = [...]"
}

@test "e2e drift guard FAILS: compose files with no gluetun binding found" {
    fixture_compose "$BATS_TEST_TMPDIR/c.yml" plain other
    fixture_ts "$BATS_TEST_TMPDIR/h.ts" "export const GLUETUN_NAMESPACE_SERVICES = ['qbittorrent'] as const;"
    run e2e_tunnelled_drift "$BATS_TEST_TMPDIR/h.ts" "$BATS_TEST_TMPDIR/c.yml"
    assert_failure
    assert_output --partial "no gluetun-bound service found"
}
