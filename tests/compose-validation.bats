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

# --- architecture: rules the compose files must keep, and can silently lose ---
#
# Adapted from leonardoazeredo/ultimate-arr-stack (tests/compose-validation.bats,
# the "quality plan" branch). Each rule has negative tests that feed the same
# check a fixture or a mutated copy and assert the SPECIFIC failure message —
# a negative that would also pass on an empty directory proves nothing.
#
# Every check reads `docker compose config --format json`, never the YAML:
# anchors, merge keys and ${VARS} are resolved by compose, and a line parser
# was fooled by all of them. docker-compose.override.yml is skipped on
# purpose — it is partial by design, and compose merges it only when no -f
# is given. `--profile '*'` renders services in every profile: without it a
# service behind `profiles:` (configarr is) is left out of the JSON, and every
# check below would pass without having seen it.

require_compose() {
    if ! docker compose version &>/dev/null; then skip "docker compose CLI not available"; fi
}

# resolve_compose DIR: one <name>.json per docker-compose*.yml in DIR, written
# to $BATS_TEST_TMPDIR/resolved/. Prints the JSON paths.
resolve_compose() {
    local dir="$1" out="$BATS_TEST_TMPDIR/resolved" f n found=0
    rm -rf "$out"; mkdir -p "$out"
    for f in "$dir"/docker-compose*.yml; do
        [ -e "$f" ] || continue
        n=$(basename "$f" .yml)
        case "$n" in *.override) continue ;; esac
        docker compose -f "$f" --env-file "$TEST_DIR/fixtures/.env.test" --profile '*' config --format json > "$out/$n.json" \
            || { echo "docker compose config failed for $f" >&2; return 1; }
        found=1
    done
    [ "$found" = 1 ] || { echo "no compose files in $dir" >&2; return 1; }
    ls "$out"/*.json
}

@test "every BitTorrent or Usenet client runs inside gluetun's namespace" {
    require_compose
    resolved=(); while IFS= read -r line; do resolved+=("$line"); done < <(resolve_compose "$REPO_ROOT")
    run python3 "$TEST_DIR/helpers/check-clients-tunnelled.py" "${resolved[@]}"
    assert_success
    # Both named clients, and no phantom from the image pattern.
    assert_output "checked 2 client(s), all inside gluetun's namespace"
}

@test "tunnelled-clients check: the image pattern finds an unlisted client and ignores a same-named exporter" {
    require_compose
    cp "$TEST_DIR/fixtures/compose-clients-tunnelled.yml" "$BATS_TEST_TMPDIR/docker-compose.fixture.yml"
    resolved=(); while IFS= read -r line; do resolved+=("$line"); done < <(resolve_compose "$BATS_TEST_TMPDIR")
    run python3 "$TEST_DIR/helpers/check-clients-tunnelled.py" "${resolved[@]}"
    assert_success
    assert_output "checked 3 client(s), all inside gluetun's namespace"
}

@test "tunnelled-clients check: sees a client that sits behind a compose profile" {
    require_compose
    sed 's/^    container_name: qbittorrent$/    container_name: qbittorrent\n    profiles: ["manual"]/' \
        "$TEST_DIR/fixtures/compose-client-outside-vpn.yml" > "$BATS_TEST_TMPDIR/docker-compose.fixture.yml"
    grep -q 'profiles: \["manual"\]' "$BATS_TEST_TMPDIR/docker-compose.fixture.yml"
    resolved=(); while IFS= read -r line; do resolved+=("$line"); done < <(resolve_compose "$BATS_TEST_TMPDIR")
    run python3 "$TEST_DIR/helpers/check-clients-tunnelled.py" "${resolved[@]}"
    assert_failure
    assert_output --partial "qbittorrent (lscr.io/linuxserver/qbittorrent:5.1.2) has network_mode unset"
}

@test "tunnelled-clients check: rejects a named client with no VPN binding" {
    require_compose
    cp "$TEST_DIR/fixtures/compose-client-outside-vpn.yml" "$BATS_TEST_TMPDIR/docker-compose.fixture.yml"
    resolved=(); while IFS= read -r line; do resolved+=("$line"); done < <(resolve_compose "$BATS_TEST_TMPDIR")
    run python3 "$TEST_DIR/helpers/check-clients-tunnelled.py" "${resolved[@]}"
    assert_failure
    assert_output --partial "qbittorrent (lscr.io/linuxserver/qbittorrent:5.1.2) has network_mode unset"
}

@test "tunnelled-clients check: rejects an unlisted client (found by image) with no VPN binding" {
    require_compose
    cp "$TEST_DIR/fixtures/compose-unlisted-client-outside-vpn.yml" "$BATS_TEST_TMPDIR/docker-compose.fixture.yml"
    resolved=(); while IFS= read -r line; do resolved+=("$line"); done < <(resolve_compose "$BATS_TEST_TMPDIR")
    run python3 "$TEST_DIR/helpers/check-clients-tunnelled.py" "${resolved[@]}"
    assert_failure
    assert_output --partial "dl (lscr.io/linuxserver/transmission:4.0.6) has network_mode unset"
}

# Which compose files form one project is not cosmetic: it is why
# `--remove-orphans` on one file deletes the others' containers (CLAUDE.md),
# and why the `arr-stack_` prefix on networks is stable. Written out rather
# than derived, so a rename fails here — that is the point of pinning it.
assert_project_names() {
    local dir="$1" f base name expected found=0
    for f in "$dir"/docker-compose*.yml; do
        [ -e "$f" ] || continue
        base=$(basename "$f")
        case "$base" in *.override.yml) continue ;; esac
        found=1
        [ -s "$f" ] || { echo "$base is empty"; return 1; }
        name=$(grep -m1 '^name:' "$f" | sed 's/^name:[[:space:]]*//')
        [ -n "$name" ] || { echo "$base does not pin a project name"; return 1; }
        case "$base" in
            docker-compose.arr-stack.yml|docker-compose.traefik.yml|docker-compose.utilities.yml) expected=arr-stack ;;
            docker-compose.cloudflared.yml) expected=cloudflared ;;
            docker-compose.tailscale.yml)   expected=tailscale ;;
            *) echo "$base is not in the expected-project-name table; add it"; return 1 ;;
        esac
        [ "$name" = "$expected" ] || { echo "$base pins project '$name', expected '$expected'"; return 1; }
    done
    [ "$found" = 1 ] || { echo "no compose files in $dir"; return 1; }
    echo "project names pinned as expected"
}

@test "every compose file pins its project name, and the core three share arr-stack" {
    run assert_project_names "$REPO_ROOT"
    assert_success
    assert_output "project names pinned as expected"
}

@test "project-name check: fails when the core file loses its name line" {
    grep -v '^name:' "$REPO_ROOT/docker-compose.arr-stack.yml" > "$BATS_TEST_TMPDIR/docker-compose.arr-stack.yml"
    [ -s "$BATS_TEST_TMPDIR/docker-compose.arr-stack.yml" ]
    run assert_project_names "$BATS_TEST_TMPDIR"
    assert_failure
    assert_output "docker-compose.arr-stack.yml does not pin a project name"
}

@test "project-name check: fails when the core file pins a different name" {
    sed 's/^name: arr-stack$/name: renamed/' "$REPO_ROOT/docker-compose.arr-stack.yml" > "$BATS_TEST_TMPDIR/docker-compose.arr-stack.yml"
    run assert_project_names "$BATS_TEST_TMPDIR"
    assert_failure
    assert_output "docker-compose.arr-stack.yml pins project 'renamed', expected 'arr-stack'"
}

# Two addresses in this stack are only safe because of these values: gluetun's
# reserved 172.20.0.3 and every other static IP sit outside the dynamic half,
# and ip_range is what confines Docker's allocator to 172.20.0.128/25 — the
# reason a neighbouring container does not land on gluetun's address after a
# reboot (CLAUDE.md, "Cross-Stack"). Widen the range and the allocator is back
# on top of the pins. Read from the resolved JSON, so it is the value compose
# will actually apply.
assert_arr_network_pinned() {
    local json="$1"
    python3 - "$json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
cfg = ((doc.get("networks") or {}).get("arr-stack") or {}).get("ipam", {}).get("config") or [{}]
want = {"subnet": "172.20.0.0/24", "ip_range": "172.20.0.128/25", "gateway": "172.20.0.1"}
bad = [f"arr-stack {k} must stay {v} (found {cfg[0].get(k)!r})" for k, v in want.items() if cfg[0].get(k) != v]
if bad:
    print("\n".join(bad)); sys.exit(1)
print("arr-stack network pins intact")
PY
}

@test "the arr-stack subnet, dynamic range and gateway stay pinned" {
    require_compose
    resolved=(); while IFS= read -r line; do resolved+=("$line"); done < <(resolve_compose "$REPO_ROOT")
    run assert_arr_network_pinned "$BATS_TEST_TMPDIR/resolved/docker-compose.arr-stack.json"
    assert_success
    assert_output "arr-stack network pins intact"
}

@test "network-pin check: fails when the dynamic range, subnet or gateway changes" {
    require_compose
    local key val
    for key in ip_range:172.20.0.128/25:172.20.0.0/24 subnet:172.20.0.0/24:172.20.0.0/23 gateway:172.20.0.1:172.20.0.254; do
        IFS=: read -r field was now <<<"$key"
        sed "s|${field}: ${was}|${field}: ${now}|" "$REPO_ROOT/docker-compose.arr-stack.yml" > "$BATS_TEST_TMPDIR/docker-compose.arr-stack.yml"
        grep -q "${field}: ${now}" "$BATS_TEST_TMPDIR/docker-compose.arr-stack.yml"   # the mutation landed
        resolve_compose "$BATS_TEST_TMPDIR" >/dev/null
        run assert_arr_network_pinned "$BATS_TEST_TMPDIR/resolved/docker-compose.arr-stack.json"
        assert_failure
        assert_output --partial "arr-stack ${field} must stay ${was}"
    done
}
