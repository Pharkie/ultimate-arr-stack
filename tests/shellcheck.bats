#!/usr/bin/env bats
# shellcheck at error severity over every tracked shell script.
#
# Error severity only: these are the findings that mean a script is broken
# (parse errors, array misuse, tests that can never be true), not style.
#
# shellcheck comes from the host if it has one, otherwise from the pinned
# koalaman/shellcheck image listed in .github/workflows/ci.yml, run through
# docker. With neither, the tests skip and say why.

setup() {
    load helpers/setup

    SHELLCHECK_IMAGE="$(grep -oE 'koalaman/shellcheck:[^ @]+@sha256:[0-9a-f]{64}' \
        "$REPO_ROOT/.github/workflows/ci.yml" | head -n1)"

    if command -v shellcheck >/dev/null 2>&1; then
        SHELLCHECK_VIA=host
    elif [ -z "$SHELLCHECK_IMAGE" ]; then
        skip "no shellcheck on PATH, and no pinned koalaman/shellcheck image in .github/workflows/ci.yml"
    elif ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        skip "no shellcheck on PATH, and no running docker to use $SHELLCHECK_IMAGE"
    else
        SHELLCHECK_VIA=docker
    fi
}

# scripts/pre-commit has no extension, so it is named here; everything else
# is any *.sh git tracks. Submodule contents (bats) are not listed by git
# ls-files in the superproject. Paths are relative to the repo root.
discover_scripts() {
    (
        cd "$REPO_ROOT" || exit 1
        { echo scripts/pre-commit; git ls-files -- '*.sh'; } |
            while read -r f; do [ -f "$f" ] && echo "$f"; done |
            sort -u
    )
}

# run_shellcheck DIR FILE...: shellcheck -S error -x on FILEs, relative to
# DIR, run from DIR so -x resolves `source` paths as the scripts do.
run_shellcheck() {
    local dir="$1"
    shift
    if [ "$SHELLCHECK_VIA" = host ]; then
        (cd "$dir" && shellcheck -S error -x "$@")
    else
        docker run --rm -v "$dir:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" -S error -x "$@"
    fi
}

@test "discovery finds the tracked shell scripts, pre-commit included" {
    run discover_scripts
    assert_success
    # Nothing found would make the next test pass while checking nothing.
    [ -n "$output" ] || fail "discovery found no shell scripts"
    assert_line "scripts/pre-commit"
    assert_line "scripts/lib/common.sh"
}

@test "every tracked shell script passes shellcheck -S error -x" {
    local files=() f
    while read -r f; do files+=("$f"); done < <(discover_scripts)
    [ "${#files[@]}" -gt 0 ] || fail "discovery found no shell scripts"
    run run_shellcheck "$REPO_ROOT" "${files[@]}"
    assert_success
}

@test "a real error-level fault fails the check (negative)" {
    mkdir -p "$BATS_TEST_TMPDIR/neg"
    # SC2068, error severity: unquoted $@ re-splits every argument, so a
    # filename with a space becomes two files.
    printf '#!/bin/bash\nfor f in $@; do rm -- "$f"; done\n' > "$BATS_TEST_TMPDIR/neg/bad.sh"
    run run_shellcheck "$BATS_TEST_TMPDIR/neg" bad.sh
    assert_failure
    assert_output --partial "SC2068"
}

@test "a warning-level finding alone does not fail it: the severity is error" {
    mkdir -p "$BATS_TEST_TMPDIR/warn"
    # SC2034 (unused variable) is a warning: reported at default severity,
    # silent at -S error. Proves the run above is not stricter than asked.
    printf '#!/bin/bash\nunused=1\n' > "$BATS_TEST_TMPDIR/warn/warn.sh"
    run run_shellcheck "$BATS_TEST_TMPDIR/warn" warn.sh
    assert_success
}
