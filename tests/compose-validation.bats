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
    skip "requires docker compose CLI"
    for f in $(get_compose_files); do
        run docker compose -f "$f" --env-file "$TEST_DIR/fixtures/.env.test" config -q
        assert_success
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
    images=$(get_pulled_images | sort -u)

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
        while IFS= read -r image; do
            [[ -z "$image" ]] && continue
            if [[ "$image" == *":latest"* ]]; then
                fail "Image '$image' in $fname uses :latest tag"
            fi
            if [[ "$image" != *":"* ]] && [[ "$image" != *'${'* ]]; then
                fail "Image '$image' in $fname has no version tag"
            fi
        done < <(get_pulled_images "$f")
    done
}

@test "node 1 (tailscale) does NOT advertise itself as an exit node" {
    # Node 1's exit node is non-functional AND fixing it would be worse than
    # leaving it broken:
    #   - Non-functional: Tailscale writes exit-node rules to the LEGACY
    #     iptables tables while Docker/UGOS enforce the NFT backend, where
    #     filter carries -P FORWARD DROP. Nothing accepts new forwarded flows
    #     from tailscale0. Subnet routing still works, which is what makes it
    #     look fine until you actually select it.
    #   - Fixing it would leak: a WORKING node-1 exit node egresses via the
    #     HOME IP, exactly the fallback the Go/No-Go leak test exists to catch.
    # Internet egress must leave via ProtonVPN through tailscale-exit.
    # The ACL's autoApprovers.exitNode grants tag:nas-router, so unapproving
    # in the admin console does not hold -- not advertising is the only fix.
    local block
    block=$(get_service_block "tailscale" "$REPO_ROOT/docker-compose.tailscale.yml")
    run grep -E '^[[:space:]]+- TS_EXTRA_ARGS=.*--advertise-exit-node' <<<"$block"
    assert_failure
}

@test "tailscale-exit DOES advertise itself as an exit node" {
    # The mirror of the guard above: the Proton-backed node is the one that is
    # supposed to offer exit-node service. If this ever stops being true the
    # stack has no exit node at all.
    local block
    block=$(get_service_block "tailscale-exit" "$REPO_ROOT/docker-compose.tailscale.yml")
    run grep -E '^[[:space:]]+- TS_EXTRA_ARGS=.*--advertise-exit-node' <<<"$block"
    assert_success
}

@test "node 1 still advertises its LAN subnet routes" {
    # The reason node 1 exists. Also why the exit-node removal had to be
    # surgical: SSH to the NAS and every .lan name ride this route.
    local block
    block=$(get_service_block "tailscale" "$REPO_ROOT/docker-compose.tailscale.yml")
    run grep -E '^[[:space:]]+- TS_EXTRA_ARGS=.*--advertise-routes=' <<<"$block"
    assert_success
}
