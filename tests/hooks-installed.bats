#!/usr/bin/env bats
# Is the pre-commit hook that setup-hooks.sh installs actually in place, where
# git will run it?
#
# Every check the hook makes stops happening, silently, if the hook is
# missing, in the wrong directory, or not executable: git skips a hook it
# cannot execute without failing the commit. So the hook must be:
#   - in the COMMON git dir's hooks/, which every worktree shares (a hook in
#     one worktree's private git dir is never run), and git must not have been
#     pointed elsewhere by core.hooksPath;
#   - a symlink to scripts/pre-commit in a checkout of THIS repository, as
#     setup-hooks.sh makes it (a copy goes stale; a link to another clone
#     runs that clone's checks);
#   - executable.
#
# The negatives build throwaway repos and install with the real
# setup-hooks.sh, so the checker is proven against what the installer makes.

setup() {
    load helpers/setup
}

# canon DIR: DIR with symlinks resolved (macOS temp paths go via /private).
canon() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"; }

# Follow a chain of symlinks, bash 3.2 style (no readlink -f on older macOS).
resolve_link() {
    local p="$1" l
    while [ -L "$p" ]; do
        l="$(readlink "$p")"
        case "$l" in
            /*) p="$l" ;;
            *) p="$(dirname "$p")/$l" ;;
        esac
    done
    printf '%s/%s\n' "$(canon "$(dirname "$p")")" "$(basename "$p")"
}

# hook_problem REPO_DIR: succeed silently if git in REPO_DIR would run the
# pre-commit hook setup-hooks.sh installs; otherwise print why not and fail.
hook_problem() {
    local repo="$1" common hooks hook target tdir troot tcommon
    common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)" ||
        { echo "not a git repository: $repo"; return 1; }
    common="$(canon "$common")"
    # Where git will actually look, honouring core.hooksPath.
    hooks="$(git -C "$repo" rev-parse --path-format=absolute --git-path hooks)"
    hooks="$(canon "$(dirname "$hooks")")/$(basename "$hooks")"
    if [ "$hooks" != "$common/hooks" ]; then
        echo "git runs hooks from $hooks (core.hooksPath), not $common/hooks where setup-hooks.sh installs"
        return 1
    fi
    hook="$common/hooks/pre-commit"
    if [ ! -e "$hook" ] && [ ! -L "$hook" ]; then
        echo "no pre-commit hook at $hook: run ./setup-hooks.sh"
        return 1
    fi
    if [ ! -L "$hook" ]; then
        echo "$hook is a copy, not a symlink to scripts/pre-commit, so it goes stale: run ./setup-hooks.sh"
        return 1
    fi
    if [ ! -e "$hook" ]; then
        echo "$hook is a dangling symlink (-> $(readlink "$hook")): run ./setup-hooks.sh"
        return 1
    fi
    target="$(resolve_link "$hook")"
    tdir="$(dirname "$target")"
    troot="$(git -C "$tdir" rev-parse --show-toplevel 2>/dev/null)" && troot="$(canon "$troot")"
    tcommon="$(git -C "$tdir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
        tcommon="$(canon "$tcommon")"
    # Any worktree of this repository will do: the hook is shared by all of them.
    if [ "$tcommon" != "$common" ] || [ "$target" != "$troot/scripts/pre-commit" ]; then
        echo "$hook points at $target, not scripts/pre-commit in a checkout of this repository"
        return 1
    fi
    if [ ! -x "$hook" ]; then
        echo "$hook -> $target is not executable, so git silently skips it"
        return 1
    fi
}

# A throwaway repository with its own copy of setup-hooks.sh and a stub hook,
# isolated from the developer's git config (a global core.hooksPath, say).
make_repo() {
    local r="$1"
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
    export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    : > "$GIT_CONFIG_GLOBAL"
    git init -q "$r"
    mkdir -p "$r/.git/hooks"
    mkdir -p "$r/scripts/lib"
    cp "$REPO_ROOT/setup-hooks.sh" "$r/"
    printf '#!/bin/sh\nexit 0\n' > "$r/scripts/pre-commit"
    printf '#!/bin/bash\n' > "$r/scripts/lib/stub.sh"
    chmod +x "$r/scripts/pre-commit"
    git -C "$r" add -A
    git -C "$r" commit -qm init
}

# setup-hooks.sh, minus its PyYAML step: a python3 that already "has" yaml.
install_hook() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/python3"
    chmod +x "$BATS_TEST_TMPDIR/bin/python3"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$1/setup-hooks.sh" >/dev/null
}

@test "this repository has the pre-commit hook installed where git will run it" {
    [ -z "${CI:-}" ] || skip "CI checkouts have no hooks; this guards developer clones"
    run hook_problem "$REPO_ROOT"
    assert_success
    assert_output ""
}

@test "passes on a repo set up by setup-hooks.sh" {
    make_repo "$BATS_TEST_TMPDIR/r"
    install_hook "$BATS_TEST_TMPDIR/r"
    run hook_problem "$BATS_TEST_TMPDIR/r"
    assert_success
}

@test "passes from a worktree too: the hook lives in the common git dir" {
    make_repo "$BATS_TEST_TMPDIR/r"
    install_hook "$BATS_TEST_TMPDIR/r"
    git -C "$BATS_TEST_TMPDIR/r" worktree add -q "$BATS_TEST_TMPDIR/wt"
    run hook_problem "$BATS_TEST_TMPDIR/wt"
    assert_success
}

@test "FAILS: no hook installed" {
    make_repo "$BATS_TEST_TMPDIR/r"
    run hook_problem "$BATS_TEST_TMPDIR/r"
    assert_failure
    assert_output --partial "no pre-commit hook at"
}

@test "FAILS: a hook only in a worktree's private git dir, which git never runs" {
    make_repo "$BATS_TEST_TMPDIR/r"
    git -C "$BATS_TEST_TMPDIR/r" worktree add -q "$BATS_TEST_TMPDIR/wt"
    local private
    private="$(git -C "$BATS_TEST_TMPDIR/wt" rev-parse --path-format=absolute --git-dir)/hooks"
    mkdir -p "$private"
    ln -s "$BATS_TEST_TMPDIR/wt/scripts/pre-commit" "$private/pre-commit"
    run hook_problem "$BATS_TEST_TMPDIR/wt"
    assert_failure
    assert_output --partial "no pre-commit hook at"
}

@test "FAILS: core.hooksPath sends git somewhere else" {
    make_repo "$BATS_TEST_TMPDIR/r"
    install_hook "$BATS_TEST_TMPDIR/r"
    git -C "$BATS_TEST_TMPDIR/r" config core.hooksPath "$BATS_TEST_TMPDIR/elsewhere"
    run hook_problem "$BATS_TEST_TMPDIR/r"
    assert_failure
    assert_output --partial "(core.hooksPath)"
}

@test "FAILS: a copy of the hook instead of the symlink" {
    make_repo "$BATS_TEST_TMPDIR/r"
    cp "$BATS_TEST_TMPDIR/r/scripts/pre-commit" "$BATS_TEST_TMPDIR/r/.git/hooks/pre-commit"
    run hook_problem "$BATS_TEST_TMPDIR/r"
    assert_failure
    assert_output --partial "is a copy, not a symlink"
}

@test "FAILS: a symlink to another repository's scripts/pre-commit" {
    make_repo "$BATS_TEST_TMPDIR/r"
    make_repo "$BATS_TEST_TMPDIR/other"
    ln -s "$BATS_TEST_TMPDIR/other/scripts/pre-commit" "$BATS_TEST_TMPDIR/r/.git/hooks/pre-commit"
    run hook_problem "$BATS_TEST_TMPDIR/r"
    assert_failure
    assert_output --partial "not scripts/pre-commit in a checkout of this repository"
}

@test "FAILS: a dangling symlink" {
    make_repo "$BATS_TEST_TMPDIR/r"
    install_hook "$BATS_TEST_TMPDIR/r"
    rm "$BATS_TEST_TMPDIR/r/scripts/pre-commit"
    run hook_problem "$BATS_TEST_TMPDIR/r"
    assert_failure
    assert_output --partial "dangling symlink"
}

@test "FAILS: the hook is not executable" {
    make_repo "$BATS_TEST_TMPDIR/r"
    install_hook "$BATS_TEST_TMPDIR/r"
    chmod -x "$BATS_TEST_TMPDIR/r/scripts/pre-commit"
    run hook_problem "$BATS_TEST_TMPDIR/r"
    assert_failure
    assert_output --partial "is not executable, so git silently skips it"
}

@test "why the executable check exists: git commits straight past a non-executable hook" {
    make_repo "$BATS_TEST_TMPDIR/r"
    install_hook "$BATS_TEST_TMPDIR/r"
    printf '#!/bin/sh\necho blocked; exit 1\n' > "$BATS_TEST_TMPDIR/r/scripts/pre-commit"
    run git -C "$BATS_TEST_TMPDIR/r" commit -q --allow-empty -m executable
    assert_failure
    chmod -x "$BATS_TEST_TMPDIR/r/scripts/pre-commit"
    run git -C "$BATS_TEST_TMPDIR/r" -c advice.ignoredHook=false commit -q --allow-empty -m ignored
    assert_success
}
