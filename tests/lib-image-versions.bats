#!/usr/bin/env bats
# scripts/lib/check-image-versions.sh
#
# Warnings-only: it tells you a pinned image has a newer tag. Its value is
# entirely in being RIGHT, since nobody acts on a checker they have learned to
# distrust -- and it has two ways to be quietly wrong that no exit code shows.
#
# The first is the cache. _cache_get decides staleness with
#
#     $(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
#
# which reads as portable and is not. `-f` means "format" on BSD stat and
# `--file-system` on GNU -- where it is a VALID flag that prints a multi-line
# filesystem report to STDOUT and exits 1. Only stderr is suppressed. So on
# Linux the `||` fires, appends the real mtime to that report, and the
# arithmetic consuming it throws a syntax error; cache_age ends up empty, and
# `[[ "" -gt 86400 ]]` evaluates empty as 0. The 24-hour cache in /tmp never
# expires. Measured on this host, not inferred.
#
# The second is _find_latest's filtering, which decides what counts as "the
# same kind of version" as the current tag. It is right for the wrong-looking
# reasons often enough to deserve its cases spelled out.

setup() {
    load helpers/setup
    load helpers/stubs
    source "$REPO_ROOT/scripts/lib/common.sh"
    source "$REPO_ROOT/scripts/lib/check-image-versions.sh"
    # Reassign AFTER sourcing: the file sets these at source time, so a value
    # exported beforehand would be overwritten.
    _IMAGE_CACHE="$BATS_TEST_TMPDIR/cache"
    _CACHE_TTL=86400
}

# --- The cache, and why it never expired -----------------------------------

@test "image-versions: a missing cache file is a miss, not an error" {
    run _cache_get "some/image:1.0"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "image-versions: a fresh cache returns the stored tag" {
    printf 'some/image:1.0=2.0\n' > "$_IMAGE_CACHE"
    run _cache_get "some/image:1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
}

@test "image-versions: a cache older than the TTL is a miss and is deleted" {
    # The whole point of the file. Without a working mtime read this cache is
    # permanent, and a stale 'latest' is reported as fact until /tmp is cleared
    # -- silently, since a wrong answer and a right one look identical.
    printf 'some/image:1.0=2.0\n' > "$_IMAGE_CACHE"
    touch -d '25 hours ago' "$_IMAGE_CACHE"
    run _cache_get "some/image:1.0"
    [ "$status" -eq 1 ]
    [ ! -f "$_IMAGE_CACHE" ]
}

@test "image-versions: a cache just inside the TTL is still fresh" {
    # The other side of the boundary: over-eager expiry would make every commit
    # re-query 31 registries, which is how a check ends up disabled instead.
    printf 'some/image:1.0=2.0\n' > "$_IMAGE_CACHE"
    touch -d '23 hours ago' "$_IMAGE_CACHE"
    run _cache_get "some/image:1.0"
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
}

@test "image-versions: the mtime read yields a bare integer on this platform" {
    # Pins the actual defect rather than only its symptom. `stat -f` on GNU
    # succeeds at printing a filesystem report to stdout, so any implementation
    # that trusts stdout without checking the shape of it reintroduces this.
    run _file_mtime "$BATS_TEST_TMPDIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]] || { echo "not an integer: [$output]"; return 1; }
    [ "$output" -gt 1000000000 ]
}

@test "image-versions: a missing file reads as mtime 0, not as garbage" {
    run _file_mtime "$BATS_TEST_TMPDIR/definitely-absent"
    [ "$output" = "0" ]
}

@test "image-versions: storing a tag twice replaces rather than appends" {
    _cache_set "some/image:1.0" "2.0"
    _cache_set "some/image:1.0" "3.0"
    [ "$(grep -c '^some/image:1.0=' "$_IMAGE_CACHE")" -eq 1 ]
    run _cache_get "some/image:1.0"
    [ "$output" = "3.0" ]
}

@test "image-versions: rewriting one entry does not drop the others" {
    _cache_set "a/one:1" "9"
    _cache_set "b/two:1" "8"
    _cache_set "a/one:1" "10"
    run _cache_get "b/two:1"
    [ "$output" = "8" ]
}

# --- Version comparison -----------------------------------------------------

@test "image-versions: _is_newer is false for the same version" {
    run _is_newer "1.2.3" "1.2.3"
    [ "$status" -eq 1 ]
}

@test "image-versions: _is_newer is true only in the newer direction" {
    run _is_newer "1.2.3" "1.2.4"; [ "$status" -eq 0 ]
    run _is_newer "1.2.4" "1.2.3"; [ "$status" -eq 1 ]
}

@test "image-versions: _is_newer ignores a v prefix on either side" {
    run _is_newer "v1.2.3" "1.2.3"; [ "$status" -eq 1 ]
    run _is_newer "v1.2.3" "v1.2.4"; [ "$status" -eq 0 ]
}

@test "image-versions: _is_newer orders numerically, not lexically" {
    # The case a string compare gets wrong: "10" sorts before "9" as text.
    run _is_newer "1.9.0" "1.10.0"
    [ "$status" -eq 0 ]
}

@test "image-versions: _is_newer handles date-style versions" {
    run _is_newer "2026.7.3" "2026.8.3"
    [ "$status" -eq 0 ]
}

# --- Candidate filtering ----------------------------------------------------

@test "image-versions: _find_latest picks the highest newer candidate" {
    run _find_latest "1.2.3" <<< $'1.2.4\n1.2.9\n1.2.5'
    [ "$output" = "1.2.9" ]
}

@test "image-versions: _find_latest returns nothing when all are older" {
    run _find_latest "9.0.0" <<< $'1.2.4\n1.2.9'
    [ -z "$output" ]
}

@test "image-versions: a v-prefixed current tag only matches v-prefixed tags" {
    run _find_latest "v1.2.3" <<< $'1.9.9\nv1.2.4'
    [ "$output" = "v1.2.4" ]
}

@test "image-versions: a bare current tag only matches bare tags" {
    # Both directions matter: mixing the styles is how a checker starts
    # recommending a tag that does not exist under the name it printed.
    run _find_latest "1.2.3" <<< $'v9.9.9\n1.2.4'
    [ "$output" = "1.2.4" ]
}

@test "image-versions: candidates with a different segment depth are rejected" {
    # 'redis 7-alpine -> 8' style noise: a two-segment tag is not a candidate
    # for a three-segment pin, however much larger it sorts.
    run _find_latest "1.2.3" <<< $'9.9\n1.2.4'
    [ "$output" = "1.2.4" ]
}

@test "image-versions: non-numeric tags are rejected outright" {
    run _find_latest "1.2.3" <<< $'latest\nalpine\n1.2.4-rc1\n1.2.4'
    [ "$output" = "1.2.4" ]
}

@test "image-versions: an empty candidate list yields an empty answer" {
    run _find_latest "1.2.3" <<< ""
    [ -z "$output" ]
}

# --- Driving the check itself ----------------------------------------------
#
# Everything above tests a helper. The first full sweep showed what that costs:
# 21 mutants inside check_image_versions survived, because no test ever called
# it. The helpers were covered and the function that decides anything was not.
# It warns and never blocks, so a wrong answer changes nothing a machine
# notices -- a checker that has reported "all up to date" for a year looks
# exactly like one with nothing to report.
#
# curl is stubbed on PATH, so nothing here touches a registry. A test that
# really queried hub.docker.com would be slow, flaky and rate-limited, which is
# the same reason the check carries a 24-hour cache.

_empty_repo() {
    mkdir -p "$BATS_TEST_TMPDIR/repo"
    _REPO_ROOT="$BATS_TEST_TMPDIR/repo"
}

# A repo root whose only compose file is the text on stdin.
_fixture_repo() {
    _empty_repo
    cat > "$_REPO_ROOT/docker-compose.fixture.yml"
}

# Install the curl stub and export the knobs it reads when it runs:
#   FIXTURE_DOCKERHUB  file holding the Docker Hub API body (empty = no tags)
#   FIXTURE_GHCR       file holding the GHCR API body
#   PROBE_STATUS       exit status for the connectivity probe
#   API_STATUS         exit status for the registry calls
# Every URL it was asked for still lands in $STUB_LOG, which is how the cache
# tests assert that a cache hit reached no registry at all.
_stub_registry_curl() {
    stub_init
    stub_tool curl '
url=""
for a in "$@"; do
    case "$a" in http*) url="$a" ;; esac
done
case "$url" in
    *hub.docker.com/v2/repositories/*)
        [ -n "${FIXTURE_DOCKERHUB:-}" ] && cat "$FIXTURE_DOCKERHUB"
        exit "${API_STATUS:-0}" ;;
    *ghcr.io/v2/*)
        [ -n "${FIXTURE_GHCR:-}" ] && cat "$FIXTURE_GHCR"
        exit "${API_STATUS:-0}" ;;
esac
exit "${PROBE_STATUS:-0}"
'
    export FIXTURE_DOCKERHUB="${FIXTURE_DOCKERHUB:-}" FIXTURE_GHCR="${FIXTURE_GHCR:-}"
    export PROBE_STATUS="${PROBE_STATUS:-0}" API_STATUS="${API_STATUS:-0}"
}

# One pinned image, and a registry that has a newer tag for it.
_one_pinned_image_with_an_update() {
    _fixture_repo <<'YAML'
services:
  sonarr:
    image: linuxserver/sonarr:4.0.0
YAML
    printf '%s\n' '{"count":3,"results":[{"name":"latest"},{"name":"4.0.0"},{"name":"4.1.0"}]}' \
        > "$BATS_TEST_TMPDIR/dockerhub.json"
    FIXTURE_DOCKERHUB="$BATS_TEST_TMPDIR/dockerhub.json"
}

@test "image-versions: an offline host skips the check instead of reporting no updates" {
    _one_pinned_image_with_an_update
    PROBE_STATUS=1
    _stub_registry_curl
    run check_image_versions
    assert_success
    assert_output --partial "SKIP: No internet connectivity"
    refute_output --partial "Checking"
}

@test "image-versions: a repo with no compose files skips instead of checking nothing" {
    _empty_repo
    _stub_registry_curl
    run check_image_versions
    assert_success
    assert_output --partial "SKIP: No compose files found"
}

@test "image-versions: compose files with no pinned tags are a skip, not an empty check" {
    _fixture_repo <<'YAML'
services:
  web:
    image: nginx
YAML
    _stub_registry_curl
    run check_image_versions
    assert_success
    assert_output --partial "SKIP: No pinned images found"
    refute_output --partial "Checking"
}

@test "image-versions: a pinned image with a newer tag is reported as an update" {
    _one_pinned_image_with_an_update
    _stub_registry_curl
    run check_image_versions
    assert_success
    assert_output --partial "UPDATE: sonarr 4.0.0 → 4.1.0 available"
    assert_output --partial "Found 1 update(s) across 1 images"
}

@test "image-versions: a registry that answers with nothing is counted as skipped" {
    _fixture_repo <<'YAML'
services:
  sonarr:
    image: linuxserver/sonarr:4.0.0
YAML
    _stub_registry_curl
    run check_image_versions
    assert_success
    assert_output --partial "(1 images skipped - registry unavailable or rate-limited)"
}

@test "image-versions: nothing skipped means no skipped line is printed" {
    # Both halves matter. A counter that always prints its line is the same
    # defect as one that never prints it: the operator learns to ignore it.
    _one_pinned_image_with_an_update
    _stub_registry_curl
    run check_image_versions
    assert_success
    refute_output --partial "images skipped"
}

@test "image-versions: a cached newer tag is reported without querying the registry" {
    _one_pinned_image_with_an_update
    _cache_set "linuxserver/sonarr:4.0.0" "4.1.0"
    _stub_registry_curl
    run check_image_versions
    assert_success
    assert_output --partial "UPDATE: sonarr 4.0.0 → 4.1.0 available"
    assert_stub_not_called curl "v2/repositories"
}

@test "image-versions: a cache entry saying current is not an update" {
    _one_pinned_image_with_an_update
    _cache_set "linuxserver/sonarr:4.0.0" "current"
    _stub_registry_curl
    run check_image_versions
    assert_success
    refute_output --partial "UPDATE"
    assert_output --partial "OK: All 1 checked images are up to date"
    assert_stub_not_called curl "v2/repositories"
}

@test "image-versions: a cache entry equal to the pinned tag is not an update" {
    _one_pinned_image_with_an_update
    _cache_set "linuxserver/sonarr:4.0.0" "4.0.0"
    _stub_registry_curl
    run check_image_versions
    assert_success
    refute_output --partial "UPDATE"
}

@test "image-versions: _query_dockerhub reads tag names out of the registry JSON" {
    printf '%s\n' '{"count":4,"results":[{"name":"latest"},{"name":"4.0.0"},{"name":"4.1.0"},{"name":"4.1.0-beta.1"}]}' \
        > "$BATS_TEST_TMPDIR/dockerhub.json"
    FIXTURE_DOCKERHUB="$BATS_TEST_TMPDIR/dockerhub.json"
    _stub_registry_curl
    run _query_dockerhub "linuxserver/sonarr" "4.0.0"
    assert_success
    assert_output "$(printf '4.0.0\n4.1.0')"
}

@test "image-versions: _query_ghcr keeps versioned tags and drops prereleases" {
    printf '%s\n' '{"name":"flaresolverr/flaresolverr","tags":["latest","1.2.3","2.0.0-rc1","v1.2.4"]}' \
        > "$BATS_TEST_TMPDIR/ghcr.json"
    FIXTURE_GHCR="$BATS_TEST_TMPDIR/ghcr.json"
    _stub_registry_curl
    run _query_ghcr "flaresolverr/flaresolverr"
    assert_success
    assert_output "$(printf '1.2.3\nv1.2.4')"
}

@test "image-versions: a stat that prints a number and fails is not trusted as an mtime" {
    # The comment on _file_mtime spells this out: GNU's `stat -f` is a valid
    # flag that prints a filesystem report to stdout while exiting 1, so a value
    # is only accepted if it is actually a number. Chained with `||` the integer
    # check stops guarding the failure path, and the first line of that report
    # becomes the mtime -- the exact shape that made the 24-hour cache permanent.
    stub_init
    stub_tool stat 'echo 1234567890; exit 1'
    run _file_mtime "$BATS_TEST_TMPDIR/whatever"
    assert_success
    assert_output "0"
}

@test "image-versions: a cache exactly at the TTL boundary is still fresh" {
    printf 'some/image:1.0=2.0\n' > "$_IMAGE_CACHE"
    local mtime
    mtime=$(_file_mtime "$_IMAGE_CACHE")
    stub_init
    # Pin the clock rather than waiting a day: the age lands on exactly
    # _CACHE_TTL, which is the one value `-gt` and `-ge` disagree about.
    stub_tool date "echo $((mtime + _CACHE_TTL))"
    run _cache_get "some/image:1.0"
    assert_success
    assert_output "2.0"
}
