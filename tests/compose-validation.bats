#!/usr/bin/env bats
# Compose file validation tests

setup() {
    load helpers/setup
}

# Extract lines belonging to a specific service from a compose file
# Args: $1 = service name, $2 = file path
get_service_block() {
    local svc="$1" file="$2"
    awk -v svc="$svc" '
        $0 ~ "^  "svc":" { found=1; next }
        found && /^  [a-zA-Z#]/ { found=0 }
        found
    ' "$file"
}

@test "all compose files pass docker compose config" {
    # This used to be an UNCONDITIONAL `skip "requires docker compose CLI"`,
    # so the one test that checks whether these files parse at all had never
    # run since it was written. The skip is now conditional and reports the
    # reason, so a missing CLI is visible rather than silently green.
    if ! docker compose version &>/dev/null; then
        skip "docker compose CLI not available"
    fi
    for f in $(get_compose_files); do
        run docker compose -f "$f" --env-file "$TEST_DIR/fixtures/.env.test" --profile '*' config -q
        assert_success
    done
}

# Guards the pinning in docker-compose.arr-stack.yml / .utilities.yml. Those
# `name:` keys are what stop a project/directory rename from silently swapping
# in empty volumes, so an unpinned volume is a data-loss risk, not a style nit.
@test "every named volume is pinned to an explicit physical name" {
    if ! docker compose version &>/dev/null; then
        skip "docker compose CLI not available"
    fi
    for f in $(get_compose_files); do
        local vols nkeys nnames
        vols=$(awk '/^volumes:/{f=1;next} /^[a-zA-Z]/{if(f)exit} f' "$f")
        [[ -z "${vols//[[:space:]]/}" ]] && continue
        nkeys=$(echo "$vols" | grep -cE '^  [a-z0-9-]+:' || true)
        nnames=$(echo "$vols" | grep -cE '^    name: ' || true)
        if [[ "$nkeys" -ne "$nnames" ]]; then
            echo "$(basename "$f"): $nkeys volume(s) declared, only $nnames pinned with an explicit name:"
            false
        fi
    done
}

@test "every service has a restart policy" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        local services
        services=$(awk '/^services:/{found=1; next} found && /^  [a-z]/{gsub(/:.*/, ""); gsub(/^  /, ""); print} found && /^[a-z]/{found=0}' "$f")
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            local block
            block=$(get_service_block "$svc" "$f")
            if ! echo "$block" | grep -q 'restart:'; then
                fail "Service '$svc' in $fname is missing restart policy"
            fi
        done <<< "$services"
    done
}

@test "every service has logging config" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        local services
        services=$(awk '/^services:/{found=1; next} found && /^  [a-z]/{gsub(/:.*/, ""); gsub(/^  /, ""); print} found && /^[a-z]/{found=0}' "$f")
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            local block
            block=$(get_service_block "$svc" "$f")
            if ! echo "$block" | grep -q 'logging:'; then
                fail "Service '$svc' in $fname is missing logging config"
            fi
        done <<< "$services"
    done
}

@test "no service uses privileged: true" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        if grep -qE 'privileged:[[:space:]]*true' "$f" 2>/dev/null; then
            fail "privileged: true found in $fname"
        fi
    done
}

@test "all image tags exist on their registry" {
    # Checks every pinned image:tag exists on its registry via HTTP API
    # No Docker CLI needed — uses curl against registry APIs directly
    if ! command -v curl &>/dev/null; then
        skip "requires curl"
    fi

    local failed=()
    local images
    images=$(get_all_images | sort -u)

    while IFS= read -r image; do
        [[ -z "$image" ]] && continue
        # Skip images with variable substitution
        [[ "$image" == *'${'* ]] && continue

        # Split image:tag
        local repo="${image%:*}"
        local tag="${image##*:}"

        # Route to the correct registry API
        if [[ "$repo" == lscr.io/* ]]; then
            # LinuxServer: query Docker Hub (lscr.io mirrors linuxserver/*)
            local hub_repo="${repo#lscr.io/}"
            local url="https://hub.docker.com/v2/repositories/${hub_repo}/tags/${tag}"
        elif [[ "$repo" == ghcr.io/* ]]; then
            # GitHub Container Registry: use OCI token + manifest check
            local ghcr_repo="${repo#ghcr.io/}"
            local token
            token=$(curl -sf "https://ghcr.io/token?scope=repository:${ghcr_repo}:pull" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
            if [[ -n "$token" ]]; then
                local status
                status=$(curl -o /dev/null -w "%{http_code}" -s \
                    -H "Authorization: Bearer $token" \
                    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json" \
                    "https://ghcr.io/v2/${ghcr_repo}/manifests/${tag}")
                [[ "$status" == "200" ]] && continue
            fi
            failed+=("$image")
            continue
        elif [[ "$repo" == */* ]]; then
            # Docker Hub with org/repo
            local url="https://hub.docker.com/v2/repositories/${repo}/tags/${tag}"
        else
            # Docker Hub official image (library/*)
            local url="https://hub.docker.com/v2/repositories/library/${repo}/tags/${tag}"
        fi

        # Check Docker Hub API
        local http_code
        http_code=$(curl -sf -o /dev/null -w "%{http_code}" "$url")
        if [[ "$http_code" != "200" ]]; then
            failed+=("$image")
        fi
    done <<< "$images"

    if [[ ${#failed[@]} -gt 0 ]]; then
        local msg="Image tags not found on registry:"
        for img in "${failed[@]}"; do
            msg+=$'\n'"  - $img"
        done
        fail "$msg"
    fi
}

@test "all images are pinned (no :latest, no missing tags)" {
    for f in $(get_compose_files); do
        local fname
        fname=$(basename "$f")
        while IFS= read -r line; do
            local image
            image=$(echo "$line" | sed -E 's/^[[:space:]]+image:[[:space:]]*//')
            [[ -z "$image" ]] && continue
            if [[ "$image" == *":latest"* ]]; then
                fail "Image '$image' in $fname uses :latest tag"
            fi
            if [[ "$image" != *":"* ]] && [[ "$image" != *'${'* ]]; then
                fail "Image '$image' in $fname has no version tag"
            fi
        done < <(grep -E '^[[:space:]]+image:[[:space:]]' "$f" 2>/dev/null)
    done
}

# ===========================================================================
# Architecture rules, checked on the RENDERED compose model
# ===========================================================================
# tests/helpers/compose-architecture.py renders each file with
#   docker compose -f FILE --env-file tests/fixtures/.env.test --profile '*' config --format json
# and reads the JSON, so anchors, merge keys, variables and profile-only
# services count exactly as compose counts them. Every rule has negative tests
# that feed the check a fixture or a one-line mutation of a real file and
# assert exit 1 plus the SPECIFIC FAIL line (exit 2 means "could not render").
# A negative that only wanted a non-zero exit would also pass if the helper
# crashed, or if the mutation matched nothing.

# Expected top-level project `name:` per compose file; the compose files point
# here. The three core files are ONE project, which is why --remove-orphans on
# any of them deletes the others' containers (docs/TROUBLESHOOTING.md), and a
# file that loses its pin falls back to the deploy directory's name
# (docs/UPGRADING.md, v1.13.0). Cloudflared and Tailscale are kept as separate
# projects so compose runs on the core files cannot stop the tunnels. A new
# compose file fails the check until it is listed here.
EXPECTED_PROJECT_NAMES=(
    "docker-compose.arr-stack.yml=arr-stack"
    "docker-compose.traefik.yml=arr-stack"
    "docker-compose.utilities.yml=arr-stack"
    "docker-compose.cloudflared.yml=cloudflared"
    "docker-compose.tailscale.yml=tailscale"
)

# The arr-stack network (CLAUDE.md, "Cross-Stack"). Gluetun's static 172.20.0.3
# is safe only while Docker hands out dynamic addresses from the ip_range alone:
# otherwise a neighbouring container can take it first and the VPN stack fails
# with "Address already in use".
ARR_NET_SUBNET="172.20.0.0/24"
ARR_NET_IP_RANGE="172.20.0.128/25"
ARR_NET_GATEWAY="172.20.0.1"

require_arch_tools() {
    docker compose version &>/dev/null || skip "docker compose CLI not available"
    command -v python3 &>/dev/null || skip "python3 not available"
}

arch_check() {
    local check="$1"
    shift
    python3 "$TEST_DIR/helpers/compose-architecture.py" "$check" \
        --env-file "$TEST_DIR/fixtures/.env.test" "$@"
}

check_clients() {
    arch_check clients "$@"
}

check_project_names() {
    local args=() e
    for e in "${EXPECTED_PROJECT_NAMES[@]}"; do
        args+=(--expect "$e")
    done
    arch_check project-name "${args[@]}" "$@"
}

check_arr_network() {
    arch_check network --subnet "$ARR_NET_SUBNET" --ip-range "$ARR_NET_IP_RANGE" \
        --gateway "$ARR_NET_GATEWAY" "$@"
}

# mutate_one_line SRC DEST SED-SCRIPT
# Writes SRC through a sed script to DEST and fails the test unless exactly one
# line of SRC was changed or removed. A script that matched nothing would turn
# the negative test into a re-run of the positive one.
mutate_one_line() {
    local src="$1" dest="$2" script="$3" touched
    mkdir -p "$(dirname "$dest")"
    sed -e "$script" "$src" > "$dest"
    touched=$(diff "$src" "$dest" | grep -c '^<' || true)
    [[ "$touched" -eq 1 ]] || fail "sed '$script' touched $touched line(s) of $(basename "$src"), expected exactly 1"
}

# --- Download clients reach the internet only through gluetun ---------------

@test "every download client runs in gluetun's network namespace" {
    require_arch_tools
    local files
    read -r -a files <<< "$(get_compose_files)"
    run check_clients "${files[@]}"
    assert_success
    # Both shipped clients must have been SEEN: a detection that found nothing
    # would otherwise pass here.
    assert_line --partial "OK   docker-compose.arr-stack.yml: download client 'qbittorrent' runs in gluetun's network namespace (service:gluetun;"
    assert_line --partial "OK   docker-compose.arr-stack.yml: download client 'sabnzbd' runs in gluetun's network namespace (service:gluetun;"
}

@test "client check: a named client outside the VPN is caught" {
    require_arch_tools
    run check_clients "$TEST_DIR/fixtures/compose-client-outside-vpn.yml"
    assert_failure 1
    assert_line "FAIL compose-client-outside-vpn.yml: download client 'qbittorrent' is outside gluetun's network namespace: network_mode is not set, want service:gluetun or container:gluetun (image lscr.io/linuxserver/qbittorrent:5.1.2, matched by name and image)"
    refute_line --partial "FAIL compose-client-outside-vpn.yml: download client 'sabnzbd'"
}

@test "client check: a client under a name nobody listed is caught by its image" {
    require_arch_tools
    run check_clients "$TEST_DIR/fixtures/compose-unlisted-client-outside-vpn.yml"
    assert_failure 1
    assert_line "FAIL compose-unlisted-client-outside-vpn.yml: download client 'dl' is outside gluetun's network namespace: network_mode is not set, want service:gluetun or container:gluetun (image lscr.io/linuxserver/transmission:4.0.6, matched by image)"
}

@test "client check: a shipped client whose image is not recognised is caught by its name" {
    require_arch_tools
    local copy="$BATS_TEST_TMPDIR/compose-client-outside-vpn.yml"
    mutate_one_line "$TEST_DIR/fixtures/compose-client-outside-vpn.yml" "$copy" \
        's|image: lscr.io/linuxserver/qbittorrent:5.1.2|image: registry.example.com/mirror/qbt:5.1.2|'
    run check_clients "$copy"
    assert_failure 1
    assert_line "FAIL compose-client-outside-vpn.yml: download client 'qbittorrent' is outside gluetun's network namespace: network_mode is not set, want service:gluetun or container:gluetun (image registry.example.com/mirror/qbt:5.1.2, matched by name)"
}

@test "client check: a client that exists only behind a compose profile is still caught" {
    require_arch_tools
    local fixture="$TEST_DIR/fixtures/compose-profiled-client-outside-vpn.yml"
    # A plain render leaves it out entirely...
    run env -u COMPOSE_PROFILES docker compose -f "$fixture" \
        --env-file "$TEST_DIR/fixtures/.env.test" config --services
    assert_success
    assert_line "qbittorrent"
    refute_line "deluge"
    # ...the check renders every profile, so it sees it.
    run check_clients "$fixture"
    assert_failure 1
    assert_line "FAIL compose-profiled-client-outside-vpn.yml: download client 'deluge' is outside gluetun's network namespace: network_mode is not set, want service:gluetun or container:gluetun (image lscr.io/linuxserver/deluge:2.2.0, matched by image, profiles: extra)"
    # sabnzbd is bound only through a merge key, which the rendered model resolves.
    assert_line --partial "OK   compose-profiled-client-outside-vpn.yml: download client 'sabnzbd' runs in gluetun's network namespace (service:gluetun;"
}

@test "client check: tunnelled clients pass and an exporter sidecar is not taken for a client" {
    require_arch_tools
    run check_clients "$TEST_DIR/fixtures/compose-clients-tunnelled.yml"
    assert_success
    assert_line "OK   compose-clients-tunnelled.yml: download client 'dl' runs in gluetun's network namespace (service:gluetun; image lscr.io/linuxserver/transmission:4.0.6, matched by image)"
    # sabnzbd-exporter is on the bridge, as it should be, and must not be flagged.
    refute_output --partial "sabnzbd-exporter"
}

@test "client check: qbittorrent's network_mode removed from the real compose file is caught" {
    require_arch_tools
    local copy="$BATS_TEST_TMPDIR/docker-compose.arr-stack.yml"
    mutate_one_line "$REPO_ROOT/docker-compose.arr-stack.yml" "$copy" \
        '/^  qbittorrent:$/,/^  [a-z]/{/^    network_mode: "service:gluetun"$/d;}'
    run check_clients "$copy"
    assert_failure 1
    assert_line --partial "FAIL docker-compose.arr-stack.yml: download client 'qbittorrent' is outside gluetun's network namespace: network_mode is not set,"
    refute_line --partial "FAIL docker-compose.arr-stack.yml: download client 'sabnzbd'"
}

@test "client check: finding no client, or a file it cannot render, is a failure" {
    require_arch_tools
    run check_clients "$REPO_ROOT/docker-compose.tailscale.yml"
    assert_failure 1
    assert_line "FAIL no download client found in any file, so nothing was checked"
    run check_clients "$BATS_TEST_TMPDIR/missing.yml"
    assert_failure 2
    assert_output --partial "missing.yml: docker compose config failed"
}

# --- Project names ------------------------------------------------------------

@test "every compose file pins its project name, and the core three share arr-stack" {
    require_arch_tools
    local files
    read -r -a files <<< "$(get_compose_files)"
    run check_project_names "${files[@]}"
    assert_success
    assert_line "OK   docker-compose.arr-stack.yml: pins project name 'arr-stack'"
    assert_line "OK   docker-compose.traefik.yml: pins project name 'arr-stack'"
    assert_line "OK   docker-compose.utilities.yml: pins project name 'arr-stack'"
}

@test "project-name check: a lost name: is caught, even deployed in a directory called arr-stack" {
    require_arch_tools
    local copy="$BATS_TEST_TMPDIR/arr-stack/docker-compose.traefik.yml"
    mutate_one_line "$REPO_ROOT/docker-compose.traefik.yml" "$copy" '/^name: arr-stack$/d'
    # The blind spot: in the documented deploy directory compose derives the
    # very name the pin used to give, so the rendered name alone looks right.
    run env -u COMPOSE_PROJECT_NAME docker compose -f "$copy" \
        --env-file "$TEST_DIR/fixtures/.env.test" config
    assert_success
    assert_line "name: arr-stack"
    # The check renders against a directory no file would name, and ignores
    # COMPOSE_PROJECT_NAME, which would also override the key.
    export COMPOSE_PROJECT_NAME=arr-stack
    run check_project_names "$copy"
    assert_failure 1
    assert_line "FAIL docker-compose.traefik.yml: no top-level project \`name:\`, so compose takes the name from the deploy directory"
}

@test "project-name check: a core file that leaves the shared project is caught" {
    require_arch_tools
    local copy="$BATS_TEST_TMPDIR/docker-compose.utilities.yml"
    mutate_one_line "$REPO_ROOT/docker-compose.utilities.yml" "$copy" 's/^name: arr-stack$/name: utilities/'
    run check_project_names "$copy"
    assert_failure 1
    assert_line "FAIL docker-compose.utilities.yml: project name is 'utilities', expected 'arr-stack'"
}

@test "project-name check: a compose file with no recorded expectation is caught" {
    require_arch_tools
    run check_project_names "$TEST_DIR/fixtures/compose-clients-tunnelled.yml"
    assert_failure 1
    assert_line "FAIL compose-clients-tunnelled.yml: pins project name 'fixture' but no expected name is recorded for this file"
}

# --- The arr-stack network ----------------------------------------------------

@test "the arr-stack network keeps its subnet, dynamic ip_range and gateway" {
    require_arch_tools
    local files
    read -r -a files <<< "$(get_compose_files)"
    run check_arr_network "${files[@]}"
    assert_success
    assert_line "OK   docker-compose.arr-stack.yml: the arr-stack network is pinned (subnet 172.20.0.0/24, ip_range 172.20.0.128/25, gateway 172.20.0.1)"
    assert_line "OK   docker-compose.arr-stack.yml: service 'gluetun' has static IP 172.20.0.3, outside the dynamic ip_range"
}

@test "network check: dropping the ip_range from the real compose file is caught" {
    require_arch_tools
    local copy="$BATS_TEST_TMPDIR/docker-compose.arr-stack.yml"
    mutate_one_line "$REPO_ROOT/docker-compose.arr-stack.yml" "$copy" '/^ *ip_range: 172\.20\.0\.128\/25$/d'
    run check_arr_network "$copy"
    assert_failure 1
    assert_line "FAIL docker-compose.arr-stack.yml: the arr-stack network's ip_range is missing, expected '172.20.0.128/25'"
}

@test "network check: a changed subnet or gateway is caught" {
    require_arch_tools
    local copy="$BATS_TEST_TMPDIR/subnet/docker-compose.arr-stack.yml"
    mutate_one_line "$REPO_ROOT/docker-compose.arr-stack.yml" "$copy" 's|subnet: 172\.20\.0\.0/24$|subnet: 172.20.0.0/16|'
    run check_arr_network "$copy"
    assert_failure 1
    assert_line "FAIL docker-compose.arr-stack.yml: the arr-stack network's subnet is '172.20.0.0/16', expected '172.20.0.0/24'"

    copy="$BATS_TEST_TMPDIR/gateway/docker-compose.arr-stack.yml"
    mutate_one_line "$REPO_ROOT/docker-compose.arr-stack.yml" "$copy" 's|gateway: 172\.20\.0\.1$|gateway: 172.20.0.254|'
    run check_arr_network "$copy"
    assert_failure 1
    assert_line "FAIL docker-compose.arr-stack.yml: the arr-stack network's gateway is '172.20.0.254', expected '172.20.0.1'"
}

@test "network check: gluetun's static IP moved into the dynamic ip_range is caught" {
    require_arch_tools
    local copy="$BATS_TEST_TMPDIR/docker-compose.arr-stack.yml"
    mutate_one_line "$REPO_ROOT/docker-compose.arr-stack.yml" "$copy" 's/ipv4_address: 172\.20\.0\.3$/ipv4_address: 172.20.0.200/'
    run check_arr_network "$copy"
    assert_failure 1
    assert_line "FAIL docker-compose.arr-stack.yml: service 'gluetun' has static IP 172.20.0.200 inside the dynamic ip_range 172.20.0.128/25, where Docker can hand it to another container first"
}

@test "network check: files that only reference the network as external are a failure" {
    require_arch_tools
    run check_arr_network "$REPO_ROOT/docker-compose.traefik.yml" "$REPO_ROOT/docker-compose.utilities.yml"
    assert_failure 1
    assert_line "FAIL no file defines the arr-stack network (only external references), so nothing was checked"
}
