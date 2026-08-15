#!/bin/bash
# Check if pinned Docker image versions have newer releases available
# Returns warnings only - does not block commits

# Source common functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Cache file to avoid repeated API calls (1 hour TTL)
_IMAGE_CACHE="/tmp/arr-stack-image-cache.json"
_CACHE_TTL=86400  # seconds (24 hours)

# Get cached result for an image, or empty if stale/missing
_cache_get() {
    local image="$1"
    if [[ ! -f "$_IMAGE_CACHE" ]]; then
        return 1
    fi

    local cache_age
    cache_age=$(( $(date +%s) - $(stat -f %m "$_IMAGE_CACHE" 2>/dev/null || stat -c %Y "$_IMAGE_CACHE" 2>/dev/null || echo 0) ))
    if [[ $cache_age -gt $_CACHE_TTL ]]; then
        rm -f "$_IMAGE_CACHE"
        return 1
    fi

    # Simple grep-based lookup: "image=latest_tag"
    grep "^${image}=" "$_IMAGE_CACHE" 2>/dev/null | cut -d= -f2-
}

# Store result in cache
_cache_set() {
    local image="$1" latest="$2"
    # Remove old entry if present, then append
    if [[ -f "$_IMAGE_CACHE" ]]; then
        grep -v "^${image}=" "$_IMAGE_CACHE" > "${_IMAGE_CACHE}.tmp" 2>/dev/null || true
        mv "${_IMAGE_CACHE}.tmp" "$_IMAGE_CACHE"
    fi
    echo "${image}=${latest}" >> "$_IMAGE_CACHE"
}

# Query Docker Hub for latest tag matching a version pattern
# Args: $1=namespace/image (e.g. "linuxserver/sonarr"), $2=current tag
# Returns: latest tag or empty
_query_dockerhub() {
    local repo="$1" current_tag="$2"
    local url="https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=25&ordering=last_updated"

    local response
    response=$(curl -s --max-time 3 "$url" 2>/dev/null) || return 1

    # Extract tag names from JSON (lightweight parsing without jq)
    echo "$response" | grep -oE '"name"\s*:\s*"[^"]+"' | sed 's/"name"\s*:\s*"//;s/"$//' | while read -r tag; do
        # Skip non-version tags
        case "$tag" in
            latest|develop|nightly|*-beta*|*-alpha*|*-rc*|*-dev*) continue ;;
        esac
        echo "$tag"
    done | head -20
}

# Query GHCR for tags
# Args: $1=owner/image (e.g. "flaresolverr/flaresolverr"), $2=current tag
_query_ghcr() {
    local repo="$1"
    local url="https://ghcr.io/v2/${repo}/tags/list"

    local response
    response=$(curl -s --max-time 3 "$url" 2>/dev/null) || return 1

    echo "$response" | grep -oE '"[v]?[0-9][^"]*"' | tr -d '"' | while read -r tag; do
        case "$tag" in
            *-beta*|*-alpha*|*-rc*|*-dev*) continue ;;
        esac
        echo "$tag"
    done
}

# Query lscr.io (LinuxServer) - uses GHCR under the hood
_query_lscr() {
    local image="$1"
    _query_ghcr "linuxserver/${image}"
}

# Strip leading 'v' from version for comparison
_strip_v() {
    echo "$1" | sed 's/^v//'
}

# Compare two semver-ish versions: returns 0 if $2 > $1 (newer available)
# Handles: 1.2.3, v1.2.3, 2025.11.1, 0.18, etc.
_is_newer() {
    local current="$1" candidate="$2"

    # Strip 'v' prefix for comparison
    current=$(_strip_v "$current")
    candidate=$(_strip_v "$candidate")

    # Same version
    [[ "$current" == "$candidate" ]] && return 1

    # Use sort -V (version sort) to determine ordering
    local highest
    highest=$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -1)

    [[ "$highest" == "$candidate" && "$highest" != "$current" ]]
}

# Find the latest matching tag from a list of tags
# Matches on the same "prefix style" (e.g., v-prefixed stays v-prefixed, same major version series)
# Args: $1=current tag, stdin=list of candidate tags
_find_latest() {
    local current="$1"
    local has_v=false
    [[ "$current" == v* ]] && has_v=true

    # Count dots in current version to match same segment depth
    local current_stripped
    current_stripped=$(_strip_v "$current")
    local current_dots
    current_dots=$(echo "$current_stripped" | tr -cd '.' | wc -c | tr -d ' ')

    local best=""
    while read -r tag; do
        [[ -z "$tag" ]] && continue

        # Match v-prefix style
        if $has_v; then
            [[ "$tag" != v* ]] && continue
        else
            [[ "$tag" == v* ]] && continue
        fi

        # Must look like a version number after stripping v
        local stripped
        stripped=$(_strip_v "$tag")
        [[ ! "$stripped" =~ ^[0-9]+(\.[0-9]+)*$ ]] && continue

        # Must have same number of version segments (dots) as current
        local tag_dots
        tag_dots=$(echo "$stripped" | tr -cd '.' | wc -c | tr -d ' ')
        [[ "$tag_dots" -ne "$current_dots" ]] && continue

        if [[ -z "$best" ]]; then
            if _is_newer "$current" "$tag"; then
                best="$tag"
            fi
        elif _is_newer "$best" "$tag"; then
            best="$tag"
        fi
    done

    echo "$best"
}

check_image_versions() {
    local repo_root warnings=0
    repo_root=$(get_repo_root)

    # Quick network check - skip if offline
    if ! curl -s --max-time 2 -o /dev/null "https://hub.docker.com" 2>/dev/null; then
        echo "    SKIP: No internet connectivity (cannot check registries)"
        return 0
    fi

    local compose_files=()
    for f in "$repo_root"/docker-compose*.yml; do
        [[ -f "$f" ]] && compose_files+=("$f")
    done

    if [[ ${#compose_files[@]} -eq 0 ]]; then
        echo "    SKIP: No compose files found"
        return 0
    fi

    # Extract unique image:tag pairs across all compose files
    local all_images=""
    for f in "${compose_files[@]}"; do
        local file_images
        file_images=$(grep -E '^\s+image:' "$f" 2>/dev/null | sed 's/.*image:\s*//' | xargs -L1 | grep ':')
        if [[ -n "$file_images" ]]; then
            all_images+="$file_images"$'\n'
        fi
    done

    # Deduplicate
    all_images=$(echo "$all_images" | grep -v '^$' | sort -u)

    if [[ -z "$all_images" ]]; then
        echo "    SKIP: No pinned images found"
        return 0
    fi

    # Convert to array
    local images=()
    while IFS= read -r img; do
        [[ -n "$img" ]] && images+=("$img")
    done <<< "$all_images"

    echo "    Checking ${#images[@]} pinned images for updates..."
    local checked=0
    local updates=0
    local skipped=0

    for image_ref in "${images[@]}"; do
        local registry="" namespace="" image="" tag=""

        # Parse image reference into components
        tag="${image_ref##*:}"
        local name_part="${image_ref%:*}"

        case "$name_part" in
            ghcr.io/*)
                registry="ghcr"
                # e.g. ghcr.io/flaresolverr/flaresolverr
                namespace="${name_part#ghcr.io/}"
                image="${namespace##*/}"
                ;;
            lscr.io/linuxserver/*)
                registry="lscr"
                image="${name_part#lscr.io/linuxserver/}"
                namespace="linuxserver/${image}"
                ;;
            */*)
                registry="dockerhub"
                namespace="$name_part"
                image="${name_part##*/}"
                ;;
            *)
                # Official Docker Hub image (e.g. traefik)
                registry="dockerhub"
                namespace="library/$name_part"
                image="$name_part"
                ;;
        esac

        # Check cache first
        local cached_latest
        cached_latest=$(_cache_get "$image_ref") || true
        if [[ -n "$cached_latest" ]]; then
            if [[ "$cached_latest" != "$tag" && "$cached_latest" != "current" ]]; then
                echo -e "      ${YELLOW:-}UPDATE${NC:-}: $image $tag → $cached_latest available"
                updates=$((updates + 1))
            fi
            checked=$((checked + 1))
            continue
        fi

        # Query the appropriate registry
        local tags_list=""
        case "$registry" in
            ghcr)
                tags_list=$(_query_ghcr "$namespace" "$tag") || true
                ;;
            lscr)
                tags_list=$(_query_lscr "$image" "$tag") || true
                ;;
            dockerhub)
                tags_list=$(_query_dockerhub "$namespace" "$tag") || true
                ;;
        esac

        if [[ -z "$tags_list" ]]; then
            skipped=$((skipped + 1))
            _cache_set "$image_ref" "current"
            continue
        fi

        # Find the latest version from available tags
        local latest
        latest=$(echo "$tags_list" | _find_latest "$tag")

        if [[ -n "$latest" ]]; then
            echo -e "      ${YELLOW:-}UPDATE${NC:-}: $image $tag → $latest available"
            _cache_set "$image_ref" "$latest"
            updates=$((updates + 1))
        else
            _cache_set "$image_ref" "current"
        fi
        checked=$((checked + 1))
    done

    if [[ $updates -eq 0 ]]; then
        echo "      OK: All $checked checked images are up to date"
    else
        echo "      Found $updates update(s) across $checked images"
    fi

    if [[ $skipped -gt 0 ]]; then
        echo "      ($skipped images skipped - registry unavailable or rate-limited)"
    fi

    # Always return 0 - this is a warning-only check
    return 0
}
