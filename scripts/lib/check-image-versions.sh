#!/bin/bash
# Check if pinned Docker image versions have newer releases available
# Returns warnings only - does not block commits

# Source common functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Cache file to avoid repeated API calls (1 hour TTL)
_IMAGE_CACHE="/tmp/arr-stack-image-cache.json"
_CACHE_TTL=86400  # seconds (24 hours)

# GHCR tag listing: tags per page, and how many pages to follow before
# giving up (10 x 1000 is well past the biggest listing here, seerr's ~440).
_GHCR_PAGE_SIZE=1000
_GHCR_MAX_PAGES=10

# Get cached result for an image, or empty if stale/missing
_cache_get() {
    local image="$1" line value stamp
    [[ -f "$_IMAGE_CACHE" ]] || return 1

    # EACH ENTRY CARRIES ITS OWN TIMESTAMP ("image=latest|epoch"). The TTL
    # used to be the cache FILE's age, and every _cache_set rewrites the file,
    # so any new entry renewed all the old ones: seerr's wrong "current"
    # outlived the 24 h by riding on other images' writes. Found 2026-09-28.
    # A line in the old format has no stamp and reads as expired.
    line=$(grep "^${image}=" "$_IMAGE_CACHE" 2>/dev/null | tail -1)
    value=${line#*=}
    [[ "$value" == *"|"* ]] || return 1
    stamp=${value##*|}
    [[ "$stamp" =~ ^[0-9]+$ ]] || return 1
    (( $(date +%s) - stamp <= _CACHE_TTL )) || return 1
    echo "${value%|*}"
}

# Store result in cache
_cache_set() {
    local image="$1" latest="$2"
    # Remove old entry if present, then append
    if [[ -f "$_IMAGE_CACHE" ]]; then
        grep -v "^${image}=" "$_IMAGE_CACHE" > "${_IMAGE_CACHE}.tmp" 2>/dev/null || true
        mv "${_IMAGE_CACHE}.tmp" "$_IMAGE_CACHE"
    fi
    echo "${image}=${latest}|$(date +%s)" >> "$_IMAGE_CACHE"
}

# Pull the plain version tags out of one Docker Hub tag listing.
# Args: $1=response body. Returns 1 if the body is not a tag listing at all.
_dockerhub_version_tags() {
    local response="$1"

    # A real listing always has "results", even an empty one. An empty body,
    # an HTML error page or {"message":"...rate limit..."} is the registry NOT
    # answering, and must never read as "answered, no newer version".
    [[ "$response" == *'"results"'* ]] || return 1

    # Keep ONLY plain version tags: 1.6.0, 4.0.19, v3.5.0, 2026.8.2, 10.11.
    #
    # The previous case-based skip list matched the exact string "nightly" but
    # not "6.4.2-nightly", and nothing at all excluded arch prefixes
    # ("amd64-…", "arm64v8-…") or LinuxServer build suffixes ("…-ls84"). A
    # positive match on the shape we want is far harder to fool than a list of
    # the shapes we happen to have seen.
    echo "$response" \
        | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | sed 's/.*:[[:space:]]*"//;s/"$//' \
        | grep -E '^v?[0-9]+(\.[0-9]+)*$'
    return 0
}

# Query Docker Hub for latest tag matching a version pattern
# Args: $1=namespace/image (e.g. "linuxserver/sonarr"), $2=current tag
# Returns: version tags (possibly none) on stdout; 1 if the registry did not
# answer, which the caller reports differently from "no version tags".
_query_dockerhub() {
    local repo="$1" current_tag="$2"

    # page_size=100, not 25. LinuxServer pushes nightlies continuously, so
    # ordering=last_updated fills the first 25 entirely with nightly and
    # arch-prefixed variants — every one of radarr's first 25 was a nightly,
    # and the newest STABLE tag never appeared in the window at all.
    local url="https://hub.docker.com/v2/repositories/${repo}/tags/?page_size=100&ordering=last_updated"

    local response tags
    # 3s was too tight for a 100-tag page.
    response=$(curl -s --max-time 15 "$url" 2>/dev/null) || return 1
    tags=$(_dockerhub_version_tags "$response") || return 1

    # Even 100 is not enough for a repo whose CI tags every commit: all 100 of
    # klutchell/dnscrypt-proxy's newest were build-<sha>, renovate branches and
    # main, so nothing survived the filter and the image was "skipped" on
    # every run — it could never have reported a release. Found 2026-09-28.
    # Ask again for only tags containing a dot (name= is a substring match).
    # Not "name=2." for the current major: that could never see a 3.0.0. A
    # dotless tag has no such filter, so it stays a visible skip.
    if [[ -z "$tags" && "$current_tag" == *.* ]]; then
        response=$(curl -s --max-time 15 "${url}&name=." 2>/dev/null) || return 1
        tags=$(_dockerhub_version_tags "$response") || return 1
    fi

    [[ -n "$tags" ]] && echo "$tags"
    return 0
}

# Query GHCR for tags
# Args: $1=owner/image (e.g. "flaresolverr/flaresolverr"), $2=current tag
# Returns: version tags on stdout; 1 if the registry did not answer; 2 if the
# listing ran past _GHCR_MAX_PAGES pages and was not read to the end.
_query_ghcr() {
    local repo="$1"

    # GHCR REQUIRES A BEARER TOKEN, even for public images. Without one,
    # /v2/<repo>/tags/list returns
    #   {"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}
    # which contains no version-shaped strings, so the tag list came back empty
    # for EVERY ghcr.io and lscr.io image — that is most of this stack — and the
    # caller cached the empty result as "current". The check therefore reported
    # Sonarr, Radarr, Prowlarr, Bazarr and SABnzbd as up to date while five real
    # releases sat unnoticed. Found 2026-08-15.
    #
    # The token is anonymous and needs no credentials; the endpoint just has to
    # be asked for it first.
    local token
    token=$(curl -s --max-time 10 "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null \
            | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    [[ -z "$token" ]] && return 1

    # FOLLOW THE Link: rel="next" HEADER. GHCR pages the listing and orders it
    # by push, oldest first, so the newest releases are on the LAST page. It
    # used to read one page of 200: seerr's stopped at v3.1.0, v3.4.1 and
    # v3.5.0 sat on pages 2 and 3, and the pinned v3.4.1 was cached "current".
    # Found 2026-09-28.
    local url="https://ghcr.io/v2/${repo}/tags/list?n=${_GHCR_PAGE_SIZE}"
    local hdrs response next all="" pages=0
    hdrs=$(mktemp) || return 1

    while [[ -n "$url" ]]; do
        # Out of pages with more to come: the newest tags are the unread
        # ones, so a partial listing would say "current" exactly when wrong.
        if (( pages++ >= _GHCR_MAX_PAGES )); then
            rm -f "$hdrs"
            return 2
        fi
        # 3s was too tight once a token round-trip is involved.
        response=$(curl -s --max-time 10 -D "$hdrs" -H "Authorization: Bearer $token" "$url" 2>/dev/null) \
            || { rm -f "$hdrs"; return 1; }
        # {"errors":[...TOOMANYREQUESTS...]} is not an answer; a tag list has
        # "tags". That goes for every page: page 1 alone is not the listing.
        [[ "$response" == *'"tags"'* ]] || { rm -f "$hdrs"; return 1; }
        all+="$response"$'\n'
        next=$(tr -d '\r' < "$hdrs" \
               | sed -n 's/^[Ll][Ii][Nn][Kk]:[[:space:]]*<\([^>]*\)>.*rel="\{0,1\}next.*/\1/p' | head -1)
        # GHCR sends </v2/...?last=...&n=...>, relative to itself. A next page
        # in any other form is not silently dropped (that would be page 1 again
        # posing as the listing), and the token never leaves ghcr.io.
        case "$next" in
            "")                url="" ;;
            /*)                url="https://ghcr.io$next" ;;
            https://ghcr.io/*) url="$next" ;;
            *)                 rm -f "$hdrs"; return 1 ;;
        esac
    done
    rm -f "$hdrs"

    echo "$all" | grep -oE '"[v]?[0-9][^"]*"' | tr -d '"' | while read -r tag; do
        case "$tag" in
            *-beta*|*-alpha*|*-rc*|*-dev*) continue ;;
        esac
        echo "$tag"
    done
}

# Query lscr.io (LinuxServer) - uses GHCR under the hood
_query_lscr() {
    local image="$1" current_tag="$2"

    # Ask DOCKER HUB, not GHCR. LinuxServer publishes to both, but GHCR's
    # /v2/<repo>/tags/list returns tags in arbitrary order with no `ordering`
    # parameter and no way to ask for the newest — the first page for
    # linuxserver/sonarr is full of 2.0.0.x and 3.0.4.x builds from years ago,
    # so 4.0.19 never appeared and the image looked current. Docker Hub's API
    # supports ordering=last_updated and answers correctly first time.
    #
    # This is why Sonarr, Radarr, Prowlarr, Bazarr and SABnzbd were all silently
    # reported as up to date while five real releases sat unnoticed.
    _query_dockerhub "linuxserver/${image}" "$current_tag"
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
    local repo_root
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
    local skip_lines=()

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
        cached_latest=$(_cache_get "$image_ref")
        if [[ -n "$cached_latest" ]]; then
            if [[ "$cached_latest" != "$tag" && "$cached_latest" != "current" ]]; then
                echo -e "      ${YELLOW:-}UPDATE${NC:-}: $image $tag → $cached_latest available"
                updates=$((updates + 1))
            fi
            checked=$((checked + 1))
            continue
        fi

        # Query the appropriate registry. Non-zero status = it did not answer;
        # zero with no tags = it answered, with no version tags in it.
        local tags_list="" query_rc=0
        case "$registry" in
            ghcr)
                tags_list=$(_query_ghcr "$namespace" "$tag") || query_rc=$?
                ;;
            lscr)
                tags_list=$(_query_lscr "$image" "$tag") || query_rc=$?
                ;;
            dockerhub)
                tags_list=$(_query_dockerhub "$namespace" "$tag") || query_rc=$?
                ;;
        esac

        if [[ $query_rc -ne 0 || -z "$tags_list" ]]; then
            skipped=$((skipped + 1))
            local reason="registry did not answer"
            [[ $query_rc -eq 0 ]] && reason="registry answered, but with no version tags"
            [[ $query_rc -eq 2 ]] && reason="tag listing runs past ${_GHCR_MAX_PAGES} pages, newest tags unread"
            skip_lines+=("$image_ref not checked - $reason")
            # DELIBERATELY NOT CACHED. This used to _cache_set "current" here,
            # which turned a failed lookup into a positive "you are up to date"
            # for the whole cache lifetime — so one rate-limited run produced a
            # permanent false all-clear, and the image was reported as *checked*
            # on every subsequent run. A lookup that did not happen must stay
            # unknown, and be counted as skipped.
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

    # Name every skip and say why. The bare "(1 images skipped - registry
    # unavailable or rate-limited)" printed on every run for dnscrypt-proxy,
    # blamed a registry that had answered fine, and read as routine noise.
    if [[ $skipped -gt 0 ]]; then
        local line
        for line in "${skip_lines[@]}"; do
            echo -e "      ${YELLOW:-}SKIP${NC:-}: $line"
        done
    fi

    # Always return 0 - this is a warning-only check
    return 0
}
