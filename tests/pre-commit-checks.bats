#!/usr/bin/env bats
# Tests for the pre-commit check scripts themselves

setup() {
    load helpers/setup
    # Source the check scripts
    source "$REPO_ROOT/scripts/lib/common.sh"
}

# Run check_secrets against a throwaway git repo containing $2 as $1.
#
# This deliberately does NOT stub get_files_to_scan/read_file_content. The
# previous version of these tests did, and the stubs did not survive into
# bats' `run` subshell — so check_secrets fell back to the real git-backed
# file list, found nothing, and returned 0. bats reported that as a plain
# failure with empty output for months. Driving the real code path in a real
# (tiny) git repo is both more honest and immune to that whole class of
# harness bug: if it passes, the production path genuinely works.
scan_in_temp_repo() {
    local filename="$1" content="$2" t
    t=$(mktemp -d)
    printf '%s\n' "$content" > "$t/$filename"
    git -C "$t" init -q
    git -C "$t" add -A
    run bash -c "cd '$t' && source '$REPO_ROOT/scripts/lib/common.sh' \
        && source '$REPO_ROOT/scripts/lib/check-secrets.sh' && check_secrets"
    rm -rf "$t"
}

# The fake key itself stays in tests/fixtures/, which check_secrets skips by
# design. Inlining it here instead is not an option: this file is not exempt,
# so the hook flags its own test suite and blocks the commit (it did).
@test "check_secrets catches a known WireGuard key pattern" {
    scan_in_temp_repo docker-compose.secrets.yml \
        "$(cat "$REPO_ROOT/tests/fixtures/compose-with-secrets.yml")"
    assert_failure
    assert_output --partial "WireGuard private key"
}

# Regression guard for the BSD-grep "empty (sub)expression" bug: the old
# pattern's trailing empty alternative made grep error out, so every one of
# these slipped through the hook on macOS.
@test "check_secrets catches PEM private key blocks of every flavour" {
    local header
    for header in "-----BEGIN PRIVATE KEY-----" \
                  "-----BEGIN RSA PRIVATE KEY-----" \
                  "-----BEGIN EC PRIVATE KEY-----" \
                  "-----BEGIN OPENSSH PRIVATE KEY-----" \
                  "-----BEGIN ENCRYPTED PRIVATE KEY-----"; do
        scan_in_temp_repo id_leaked.pem "$header"
        assert_failure
        assert_output --partial "Private key block detected"
    done
}

@test "check_secrets does not flag a public key" {
    scan_in_temp_repo id_public.pem "-----BEGIN PUBLIC KEY-----"
    assert_success
}

@test "check_secrets passes a repo with no secrets" {
    scan_in_temp_repo docker-compose.clean.yml "services: {}"
    assert_success
}

@test "check_env_vars catches an undocumented variable" {
    source "$REPO_ROOT/scripts/lib/check-env-vars.sh"

    # Create a temp compose file with an undocumented var
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.test.yml" <<'EOF'
services:
  test:
    image: alpine:3.20
    environment:
      - UNDOCUMENTED_VAR_XYZZY=${UNDOCUMENTED_VAR_XYZZY}
EOF

    # Run check_env_vars in a subshell with overridden repo root
    run bash -c "
        source '$REPO_ROOT/scripts/lib/common.sh'
        source '$REPO_ROOT/scripts/lib/check-env-vars.sh'
        # Override git rev-parse to use tmpdir
        git() { echo '$tmpdir'; }
        export -f git
        # Copy .env.example to tmpdir
        cp '$REPO_ROOT/.env.example' '$tmpdir/'
        check_env_vars
    "
    assert_failure
    assert_output --partial "UNDOCUMENTED_VAR_XYZZY"

    rm -rf "$tmpdir"
}

@test "check_conflicts catches duplicate ports within a file" {
    source "$REPO_ROOT/scripts/lib/check-conflicts.sh"

    # Create a temp dir with a conflicting compose file
    local tmpdir
    tmpdir=$(mktemp -d)
    cp "$REPO_ROOT/tests/fixtures/compose-port-conflict.yml" "$tmpdir/docker-compose.conflict.yml"

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-conflicts.sh'
        # Override git rev-parse to use tmpdir
        git() { echo '$tmpdir'; }
        export -f git
        check_conflicts
    "
    assert_failure
    assert_output --partial "Duplicate ports"

    rm -rf "$tmpdir"
}

@test "check_conflicts catches cross-file port duplicates" {
    source "$REPO_ROOT/scripts/lib/check-conflicts.sh"

    # Create two compose files with same port in different files
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.a.yml" <<'EOF'
services:
  svc-a:
    image: alpine:3.20
    ports:
      - "9999:80"
EOF
    cat > "$tmpdir/docker-compose.b.yml" <<'EOF'
services:
  svc-b:
    image: alpine:3.20
    ports:
      - "9999:8080"
EOF

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-conflicts.sh'
        git() { echo '$tmpdir'; }
        export -f git
        check_conflicts
    "
    assert_failure
    assert_output --partial "Port 9999 used across multiple files"

    rm -rf "$tmpdir"
}

# --- doc links -------------------------------------------------------------
#
# check_doc_links was hook-only: nothing in the suite ran it, so a contributor
# without the hooks could merge a broken link and CI would never know. It
# resolves the repo from the working directory, so the negative drives it in a
# throwaway git repo with one broken link.

@test "check_doc_links: every internal link in the repo's markdown resolves" {
    run bash -c "cd '$REPO_ROOT' && source scripts/lib/common.sh && source scripts/lib/check-doc-links.sh && check_doc_links"
    assert_success
    assert_output --partial "OK: All internal doc links valid"
}

@test "check_doc_links: reports a link to a file that does not exist" {
    local t; t=$(mktemp -d)
    printf '# Doc\n\nSee [the guide](docs/MISSING.md).\n' > "$t/README.md"
    git -C "$t" init -q && git -C "$t" add -A
    run bash -c "cd '$t' && source '$REPO_ROOT/scripts/lib/common.sh' && source '$REPO_ROOT/scripts/lib/check-doc-links.sh' && check_doc_links"
    rm -rf "$t"
    assert_failure
    assert_output --partial "broken link to 'docs/MISSING.md'"
}

# --- image versions --------------------------------------------------------
#
# curl is replaced by a stub on PATH that serves canned registry answers, so
# these run offline and cannot pass just because the live registry happened to
# answer well. For Docker Hub the stub answers the unfiltered newest-100 query
# from first.json and any name-filtered query from filtered.json, falling back
# to first.json. For GHCR it hands out a token, then answers the first page of
# the tag listing from ghcr1.json and any later page (?last=), on any host,
# from ghcr2.json; a ghcrN.link file becomes that page's Link header. A
# <name>.fail file makes that query fail the way a dead connection does.
#
# The fallback matters: with a missing filtered.json the stub's cat failed, so
# the rate-limit case "passed" as did-not-answer even with the "results" guard
# deleted — it was testing the stub, not the check.

# Docker Hub tags listing containing the given tag names, newest first.
hub_listing() {
    local out='{"count":0,"next":null,"previous":null,"results":[' sep='' t
    for t in "$@"; do out+="$sep{\"name\":\"$t\"}"; sep=','; done
    echo "$out]}"
}

# One page of a GHCR tags listing containing the given tag names.
ghcr_listing() {
    local out='{"name":"example/paged","tags":[' sep='' t
    for t in "$@"; do out+="$sep\"$t\""; sep=','; done
    echo "$out]}"
}

image_check_setup() {
    IMG_T=$(mktemp -d)
    mkdir -p "$IMG_T/bin" "$IMG_T/repo"
    git -C "$IMG_T/repo" init -q
    cat > "$IMG_T/bin/curl" <<STUB
#!/bin/bash
hdrs="" auth=""
while [[ \$# -gt 1 ]]; do
    case "\$1" in
        -D) hdrs="\$2"; shift ;;
        -H) auth="\$2"; shift ;;
    esac
    shift
done
url="\$1"
case "\$url" in
    https://hub.docker.com) exit 0 ;;
    https://ghcr.io/token*) echo '{"token":"anon"}'; exit 0 ;;
    # Any host: a check that followed a link off ghcr.io must visibly succeed.
    */tags/list[?]last=*) f=ghcr2 ;;
    https://ghcr.io/v2/*) f=ghcr1 ;;
    *name=*) f=filtered ;;
    *) f=first ;;
esac
[[ -f "$IMG_T/\$f.fail" ]] && exit 7
if [[ "\$f" == ghcr* ]]; then
    # Real GHCR refuses every page, not just the first, without the token.
    if [[ "\$auth" != "Authorization: Bearer anon" ]]; then
        echo '{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}'
        exit 0
    fi
    if [[ -n "\$hdrs" ]]; then
        { printf 'HTTP/2 200\r\ncontent-type: application/json\r\n'
          [[ -f "$IMG_T/\$f.link" ]] && printf 'link: %s\r\n' "\$(cat "$IMG_T/\$f.link")"
          printf '\r\n'; } > "\$hdrs"
    fi
fi
[[ -f "$IMG_T/\$f.json" ]] || f=first
cat "$IMG_T/\$f.json"
STUB
    chmod +x "$IMG_T/bin/curl"
}

# $1 = the one image the throwaway repo's compose file pins
run_image_check() {
    printf 'services:\n  x:\n    image: %s\n' "$1" > "$IMG_T/repo/docker-compose.yml"
    run bash -c "cd '$IMG_T/repo' && export PATH='$IMG_T/bin':\"\$PATH\" \
        && source '$REPO_ROOT/scripts/lib/common.sh' \
        && source '$REPO_ROOT/scripts/lib/check-image-versions.sh' \
        && _IMAGE_CACHE='$IMG_T/cache' && check_image_versions"
}

# klutchell/dnscrypt-proxy's newest 100 tags were all build-<sha>, renovate
# branches and main, so the image was "skipped" on every run and could never
# have reported a release.
@test "check_image_versions: finds releases buried under CI tags" {
    image_check_setup
    hub_listing build-renovate-ubuntu-26.x build-e1149f2 main > "$IMG_T/first.json"
    hub_listing build-renovate-ubuntu-26.x 2.1.18 v2.1.18 2.1.17 > "$IMG_T/filtered.json"
    run_image_check example/ci-flooded:2.1.17
    rm -rf "$IMG_T"
    assert_success
    assert_output --partial "UPDATE: ci-flooded 2.1.17 → 2.1.18 available"
    assert_output --partial "Found 1 update(s) across 1 images"
    refute_output --partial "SKIP"
    refute_output --partial "skipped"
}

@test "check_image_versions: a registry that did not answer is a named skip" {
    local body
    # A dead connection, then an answer that is a rate-limit message rather
    # than a tag listing. Neither may read as "no newer version".
    for body in FAIL '{"message":"You have reached your pull rate limit."}'; do
        image_check_setup
        if [[ "$body" == FAIL ]]; then touch "$IMG_T/first.fail"
        else echo "$body" > "$IMG_T/first.json"; fi
        run_image_check example/ci-flooded:2.1.17
        rm -rf "$IMG_T"
        assert_success
        assert_output --partial "SKIP: example/ci-flooded:2.1.17 not checked - registry did not answer"
        refute_output --partial "UPDATE"
    done
}

@test "check_image_versions: an answer with no version tags is a named skip, not 'registry unavailable'" {
    image_check_setup
    hub_listing build-e1149f2 main > "$IMG_T/first.json"
    hub_listing build-renovate-ubuntu-26.x > "$IMG_T/filtered.json"
    run_image_check example/ci-flooded:2.1.17
    rm -rf "$IMG_T"
    assert_success
    assert_output --partial "SKIP: example/ci-flooded:2.1.17 not checked - registry answered, but with no version tags"
    refute_output --partial "did not answer"
}

# GHCR pages its tag listing and lists tags in push order, so the newest
# releases are on the LAST page. seerr's first page stopped at v3.1.0 while
# v3.5.0 sat on page 3, and the check cached "current" for v3.4.1.
@test "check_image_versions: follows GHCR's tag listing onto the next page" {
    image_check_setup
    ghcr_listing develop v3.1.0 v3.4.1 sha-0b8f872 > "$IMG_T/ghcr1.json"
    echo '</v2/example/paged/tags/list?last=sha-0b8f872&n=1000>; rel="next"' > "$IMG_T/ghcr1.link"
    ghcr_listing sha-cd8aa1f v3.5.0 v3.5 v3.6.0-beta.1 > "$IMG_T/ghcr2.json"
    run_image_check ghcr.io/example/paged:v3.4.1
    rm -rf "$IMG_T"
    assert_success
    assert_output --partial "UPDATE: paged v3.4.1 → v3.5.0 available"
    refute_output --partial "SKIP"
}

@test "check_image_versions: a GHCR next page that cannot be read fails the whole listing" {
    local body
    # Page 1 alone says "current"; that must not stand in for the full listing.
    # A dead connection, a rate-limit answer, and a next link off ghcr.io.
    for body in FAIL '{"errors":[{"code":"TOOMANYREQUESTS","message":"rate limited"}]}' OFFSITE; do
        image_check_setup
        ghcr_listing v3.4.1 sha-0b8f872 > "$IMG_T/ghcr1.json"
        echo '</v2/example/paged/tags/list?last=sha-0b8f872&n=1000>; rel="next"' > "$IMG_T/ghcr1.link"
        ghcr_listing v3.5.0 > "$IMG_T/ghcr2.json"
        case "$body" in
            FAIL) touch "$IMG_T/ghcr2.fail" ;;
            OFFSITE) echo '<https://elsewhere.example/v2/example/paged/tags/list?last=sha-0b8f872>; rel="next"' > "$IMG_T/ghcr1.link" ;;
            *) echo "$body" > "$IMG_T/ghcr2.json" ;;
        esac
        run_image_check ghcr.io/example/paged:v3.4.1
        rm -rf "$IMG_T"
        assert_success
        assert_output --partial "SKIP: ghcr.io/example/paged:v3.4.1 not checked - registry did not answer"
        refute_output --partial "All 1 checked images are up to date"
    done
}

# The TTL was the cache FILE's age, and every write rewrites the file, so a
# stale "current" lived on as long as any other image kept being written.
@test "check_image_versions: an expired cache entry is re-checked even when the cache file is fresh" {
    image_check_setup
    ghcr_listing v3.4.1 v3.5.0 > "$IMG_T/ghcr1.json"
    printf '%s\n' "ghcr.io/example/paged:v3.4.1=current|$(( $(date +%s) - 90000 ))" \
        "ghcr.io/example/other:v1.0.0=current|$(date +%s)" > "$IMG_T/cache"
    run_image_check ghcr.io/example/paged:v3.4.1
    rm -rf "$IMG_T"
    assert_success
    assert_output --partial "UPDATE: paged v3.4.1 → v3.5.0 available"
}

@test "check_image_versions: a cache line without a timestamp is re-checked, not trusted" {
    image_check_setup
    ghcr_listing v3.4.1 v3.5.0 > "$IMG_T/ghcr1.json"
    echo "ghcr.io/example/paged:v3.4.1=current" > "$IMG_T/cache"
    run_image_check ghcr.io/example/paged:v3.4.1
    rm -rf "$IMG_T"
    assert_success
    assert_output --partial "UPDATE: paged v3.4.1 → v3.5.0 available"
}

@test "check_image_versions: a GHCR listing that never ends is a named skip, not 'current'" {
    image_check_setup
    ghcr_listing v3.4.1 > "$IMG_T/ghcr1.json"
    echo '</v2/example/paged/tags/list?last=v3.4.1&n=1000>; rel="next"' > "$IMG_T/ghcr1.link"
    ghcr_listing sha-0b8f872 > "$IMG_T/ghcr2.json"
    echo '</v2/example/paged/tags/list?last=sha-0b8f872&n=1000>; rel="next"' > "$IMG_T/ghcr2.link"
    run_image_check ghcr.io/example/paged:v3.4.1
    rm -rf "$IMG_T"
    assert_success
    assert_output --partial "SKIP: ghcr.io/example/paged:v3.4.1 not checked - tag listing runs past"
    refute_output --partial "All 1 checked images are up to date"
}

# --- the hook as a whole ---------------------------------------------------
#
# scripts/pre-commit runs under set -e and counted with ((ERRORS++)), as did
# the warning-only libs with ((warnings++)). A post-increment from 0 evaluates
# to 0, which is exit status 1, and bash >= 4.1 exits on it. So on CI's bash 5
# the first blocking failure ended the hook with no later checks and no
# summary, and a warning-only hit blocked the commit before printing the
# warning. macOS /bin/bash 3.2 never exits on a failed (( )), which is why it
# went unseen. These drive the real hook in a throwaway repo under the bash
# running the suite. On 3.2 they cannot tell the old code from the new, so
# they skip rather than pass.

hook_temp_repo() {
    (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1) )) \
        || skip "bash $BASH_VERSION does not exit on a failed (( )) under set -e; CI's bash 5 runs this"
    HOOK_T=$(mktemp -d)
    git -C "$HOOK_T" init -q
}

run_hook() {
    git -C "$HOOK_T" add -A
    run bash -c "cd '$HOOK_T' && '$BASH' '$REPO_ROOT/scripts/pre-commit'"
    rm -rf "$HOOK_T"
}

@test "pre-commit: a blocking failure still runs every later check and the summary" {
    hook_temp_repo
    # Fails CHECK 1 (the fixture key, under a name the scanner does not
    # exempt) and CHECK 11 (a broken doc link), the first and last checks.
    cp "$REPO_ROOT/tests/fixtures/compose-with-secrets.yml" "$HOOK_T/leak.txt"
    printf '# Doc\n\nSee [the guide](docs/MISSING.md).\n' > "$HOOK_T/README.md"
    run_hook
    assert_failure
    assert_output --partial "WireGuard private key"
    assert_output --partial "broken link to 'docs/MISSING.md'"
    assert_output --partial "BLOCKED: 2 error(s) found"
}

@test "pre-commit: a warning-only hit does not block the commit" {
    hook_temp_repo
    printf 'DOMAIN=example-custom.test\n' > "$HOOK_T/.env"
    printf '.env\n' > "$HOOK_T/.gitignore"
    printf 'served at example-custom.test\n' > "$HOOK_T/notes.txt"
    run_hook
    assert_success
    assert_output --partial "WARNING: Your domain 'example-custom.test' is hardcoded"
    assert_output --partial "PASSED: All checks passed"
}
