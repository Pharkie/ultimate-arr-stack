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

# curl with a bounded retry, for the registry probes below.
#
# Those probes talk to live registries, and this suite is a required check, so a
# transient network failure is a blocked merge for whoever is unlucky enough to
# push during one. Observed 2026-09-11: the heavy run's suite went red on
# `curl -sf ... failed with status 35` (TLS connect error to hub.docker.com)
# while the push and pull-request runs of the same commit were green within the
# hour, and the failure read as "this image tag does not exist".
#
# Three attempts, one second apart. A 404 is still answered on the first
# attempt by the two call sites that do not pass -f, so a genuinely missing tag
# does not pay for the retries.
registry_probe() {
    local attempt rc=0
    for attempt in 1 2 3; do
        "$@" && return 0
        rc=$?
        sleep 1
    done
    return "$rc"
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
            token=$(registry_probe curl -sf "https://ghcr.io/token?scope=repository:${ghcr_repo}:pull" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
            if [[ -n "$token" ]]; then
                local status
                status=$(registry_probe curl -o /dev/null -w "%{http_code}" -s \
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
        http_code=$(registry_probe curl -sf -o /dev/null -w "%{http_code}" "$url")
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
    # The Tailscale exit-node role now runs on arr-stack-router (native
    # Tailscale + WireGuard, live device config outside this repo) — see
    # docs/EXIT-NODE-PROJECT-LOG.md. The ACL's autoApprovers.exitNode grants
    # tag:nas-router, so unapproving in the admin console does not hold --
    # not advertising is the only fix.
    local block
    block=$(get_service_block "tailscale" "$REPO_ROOT/docker-compose.tailscale.yml")
    run grep -E '^[[:space:]]+- TS_EXTRA_ARGS=.*--advertise-exit-node' <<<"$block"
    assert_failure
}

@test "node 1 still advertises its LAN subnet routes" {
    # The reason node 1 exists. Also why the exit-node removal had to be
    # surgical: SSH to the NAS and every .lan name ride this route.
    local block
    block=$(get_service_block "tailscale" "$REPO_ROOT/docker-compose.tailscale.yml")
    run grep -E '^[[:space:]]+- TS_EXTRA_ARGS=.*--advertise-routes=' <<<"$block"
    assert_success
}

@test "node 1 (tailscale) does NOT pass --reset in TS_EXTRA_ARGS" {
    # --reset forces tailscaled to wipe ALL persisted prefs back to exactly
    # these compose-file args on every restart, including live-only,
    # not-in-git state (e.g. `tailscale set --relay-server-port=41641` for
    # peer-relay support) that nothing else detects the loss of. It was only
    # ever needed to force-clear a stale AdvertiseRoutes left over from an
    # earlier exit-node experiment; that cleanup landed in a87400c (tasks
    # #77/#79, docs/EXIT-NODE-PROJECT-LOG.md §5/§7). Anchored on end-of-string
    # or whitespace, not a bare substring match -- --reset is short and
    # collision-prone.
    local block
    block=$(get_service_block "tailscale" "$REPO_ROOT/docker-compose.tailscale.yml")
    run grep -E -- '^[[:space:]]+- TS_EXTRA_ARGS=.*--reset($|[[:space:]])' <<<"$block"
    assert_failure
}

@test "cloudflared is opt-in: a plain 'up -d' cannot start a tunnel with no config" {
    # cloudflared/config.yml is gitignored, so any checkout where an operator has
    # not created one has no tunnel config at all. scripts/boot-compose-up.sh runs
    # `up -d` over every compose file in this repo on every boot, and
    # scripts/restart-stack.sh's `all` arm does the same, so an unprofiled
    # cloudflared is started unconditionally, exits immediately (nothing to read),
    # and is restarted forever by `restart: always` -- the crash-loop observed on
    # this NAS on 2026-08-16. A profiled service is skipped by a plain `up -d`;
    # verified against this file on the NAS: "no service selected", exit 0.
    local f="$REPO_ROOT/docker-compose.cloudflared.yml"
    [ -f "$f" ] || fail "docker-compose.cloudflared.yml is missing"
    get_service_block "cloudflared" "$f" | grep -qE '^    profiles:' \
        || fail "cloudflared must declare a profile, or boot/restart will crash-loop a tunnel with no config"
}

# --- architecture: what must be inside the VPN namespace ---------------------

@test "every BitTorrent or Usenet client runs inside gluetun's namespace" {
    # The suite already checked the binding for services that DECLARE it
    # (tests/vpn-zombies.bats parses every `network_mode: service:gluetun`). What
    # nothing asserted is the positive rule, which is the one that matters: a
    # download client added later without the binding leaks this house's IP to
    # the swarm and passes every other test in this file.
    #
    # Two ways in, deliberately overlapping. The named list is the one that must
    # hold today; the image pattern is what catches a second client added under a
    # name nobody remembered to add here. decypharr is the documented exception
    # and is named as one rather than pattern-matched out:
    # docker-compose.arr-stack.yml's own header says it pulls finished files from
    # TorBox over HTTPS and carries no swarm traffic from this host, so the VPN
    # is not its problem. Moving it inside the tunnel would be safe, so nothing
    # here fails if someone does.
    run python3 - "$REPO_ROOT" <<'PY'
import glob, os, re, sys

root = sys.argv[1]
BOUND = ("service:gluetun", "container:gluetun")
NAMED = {"qbittorrent", "sabnzbd", "magnetio-addon"}
CLIENT_IMAGE = re.compile(r"(qbittorrent|sabnzbd|transmission|deluge|rtorrent|nzbget)", re.I)
EXEMPT = {"decypharr"}

# service -> (file, image, network_mode or None), across every compose file.
services = {}
for path in sorted(glob.glob(os.path.join(root, "docker-compose*.yml"))):
    name = os.path.basename(path)
    svc, image, mode = None, None, None
    for line in open(path):
        m = re.match(r"^  ([A-Za-z0-9_.-]+):\s*$", line)
        if m:
            if svc:
                services[svc] = (name, image, mode)
            svc, image, mode = m.group(1), None, None
            continue
        if svc is None:
            continue
        s = line.strip()
        if s.startswith("image:"):
            image = s.split(":", 1)[1].strip().strip('"')
        elif s.startswith("network_mode:"):
            mode = s.split(":", 1)[1].strip().strip('"')
    if svc:
        services[svc] = (name, image, mode)

# The candidates: the named list, plus anything whose image says it is a
# download client under a name nobody added to the list.
candidates = set(NAMED)
for svc, (_, image, _) in services.items():
    if image and CLIENT_IMAGE.search(image) and svc not in EXEMPT:
        candidates.add(svc)

bad = []
for svc in sorted(candidates):
    if svc not in services:
        bad.append(f"{svc} is in the must-be-tunnelled list but no compose file defines it")
        continue
    name, image, mode = services[svc]
    if mode not in BOUND:
        bad.append(
            f"{name}: {svc} ({image or 'no image'}) has network_mode "
            f"{mode or 'unset'} -- it must be {' or '.join(BOUND)}"
        )

if bad:
    print("VIOLATION: a download client is outside the VPN namespace")
    print("\n".join("  " + b for b in bad))
    sys.exit(1)
print(f"checked {len(candidates)} client(s); decypharr exempt (debrid over HTTPS, no swarm traffic)")
PY
    assert_success
    refute_output --partial "VIOLATION"
}

@test "every compose file pins its project name" {
    # The project name is load-bearing, not cosmetic. Docker names every volume
    # and container `<project>_<name>`, backup-volume-resolution.bats resolves
    # backup volumes by that prefix, and CLAUDE.md's --remove-orphans warning
    # exists because the stack's services are split across files that share one
    # project. A file that loses its `name:` line silently renames its volumes on
    # the next recreate -- which is how a backup ends up written to a volume
    # nothing reads.
    #
    # The expected set is written out rather than derived: a rename should fail
    # here, and that is the point of pinning it.
    local expected="arr-core cloudflared magnetio tailscale traefik-edge arr-utilities"
    local f name actual=""
    for f in "$REPO_ROOT"/docker-compose*.yml; do
        name=$(grep -m1 '^name:' "$f" | sed 's/^name:[[:space:]]*//')
        [ -n "$name" ] || fail "$(basename "$f") does not pin a project name"
        actual="$actual $name"
    done
    # shellcheck disable=SC2086
    actual=$(printf '%s\n' $actual | sort | tr '\n' ' ' | sed 's/ $//')
    # shellcheck disable=SC2086
    expected=$(printf '%s\n' $expected | sort | tr '\n' ' ' | sed 's/ $//')
    [ "$actual" = "$expected" ] || fail "compose project names changed: expected [$expected], found [$actual]"
}

@test "the arr-core subnet and its dynamic range stay pinned" {
    # Two addresses in this stack are only safe because of these three lines.
    # Static IPs (gluetun .3, traefik .6, duc .14 ...) are pinned outside the
    # dynamic half, and ip_range is what confines Docker's own allocation to
    # 172.20.0.128/25 -- the reason a manually-added container does not collide
    # with a dynamic one on restart, which CLAUDE.md calls out by name. Widening
    # the range to the whole /24 puts the allocator back on top of the pins.
    local f="$REPO_ROOT/docker-compose.arr-stack.yml"
    local block
    block=$(get_service_block "arr-core" "$f")
    grep -qE '^[[:space:]]*-[[:space:]]*subnet:[[:space:]]*172\.20\.0\.0/24$' <<<"$block" \
        || fail "arr-core's subnet must stay 172.20.0.0/24"
    grep -qE '^[[:space:]]+ip_range:[[:space:]]*172\.20\.0\.128/25$' <<<"$block" \
        || fail "arr-core's ip_range must stay 172.20.0.128/25, or Docker's allocator overlaps the pinned static IPs"
    grep -qE '^[[:space:]]+gateway:[[:space:]]*172\.20\.0\.1$' <<<"$block" \
        || fail "arr-core's gateway must stay 172.20.0.1"
}
