#!/usr/bin/env bats
# Static analysis over the repo's own shell scripts.
#
# The repo had no shellcheck coverage at all, while carrying ~25 shell files
# that run against a live NAS — the pre-commit hook, the backup script, the
# VPN checks. Quoting and expansion mistakes in those are exactly the class
# shellcheck exists to catch, and exactly the class that only shows up when
# something already went wrong.
#
# Scoped to `-S error`: syntax errors, invalid redirections, and the like.
# Widening to `-S warning` is a deliberate decision for another day, not a
# side effect of this file — it would surface 7 pre-existing findings as of
# this commit (4x SC2155 declare-and-assign, 3x SC2034 unused variable), all
# unrelated to anything here.
#
# Adapted from tests/shellcheck.bats in leonardoazeredo/ultimate-arr-stack,
# which skips outright when the binary is absent. Since shellcheck is nobody's
# default install, that skip is the normal case rather than the exception, and
# a check that normally does not run is not a check. This falls back to the
# published container image, which every machine that runs this stack already
# has a daemon for.

setup() {
    load helpers/setup
}

# Every shell file in the repo. scripts/pre-commit has no extension and is the
# one most worth checking, so it is listed explicitly. The rest come from git,
# not from globs over scripts/: those missed setup-hooks.sh, tests/run-tests.sh
# and duc/scan.sh, which the NAS runs inside the duc container.
shell_files() {
    printf '%s\n' scripts/pre-commit
    git -C "$REPO_ROOT" ls-files '*.sh' | sed "s|^|$REPO_ROOT/|"
}

@test "shell scripts have no shellcheck errors" {
    local -a rel=()
    local f
    for f in $(shell_files); do
        rel+=("${f#"$REPO_ROOT"/}")
    done
    [[ ${#rel[@]} -gt 1 ]]  # guard against the globs silently expanding to nothing

    if command -v shellcheck &>/dev/null; then
        cd "$REPO_ROOT"
        run shellcheck -S error -x "${rel[@]}"
    elif command -v docker &>/dev/null && docker info &>/dev/null; then
        run docker run --rm -v "$REPO_ROOT:/mnt" -w /mnt \
            koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d -S error -x "${rel[@]}"
    else
        skip "neither shellcheck nor a running docker daemon is available"
    fi

    assert_success
}
