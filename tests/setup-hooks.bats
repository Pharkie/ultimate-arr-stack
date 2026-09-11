#!/usr/bin/env bats
# setup-hooks.sh
#
# tests/hooks-installed.bats asserts the two hook symlinks EXIST. That is a
# statement about the machine the suite is running on, not about this script --
# it passes on a developer box where someone ran setup-hooks by hand a year ago,
# and it would keep passing if this file were emptied tomorrow. It is the same
# presence-is-not-behaviour trap that let the post-merge hook sit installed,
# executable, correctly symlinked and entirely inert from the day it landed
# until 2026-08-31.
#
# So these tests RUN it, against a throwaway checkout with its own git repo, and
# assert what it did.

setup() {
    load helpers/setup

    command -v git >/dev/null 2>&1 \
        || skip "no host git binary on this machine (the NAS drives this repo through a containerised alpine/git)"

    # A miniature of this repo's layout: the script, the two hook scripts it
    # links, and the files it chmods. Built rather than copied, so a test can
    # start them non-executable and watch that change.
    CO="$BATS_TEST_TMPDIR/checkout"
    mkdir -p "$CO/scripts/lib"
    cp "$REPO_ROOT/setup-hooks.sh" "$CO/setup-hooks.sh"
    chmod +x "$CO/setup-hooks.sh"
    for f in scripts/pre-commit scripts/post-merge scripts/sync-nas.sh scripts/lib/check-x.sh; do
        printf '#!/bin/bash\n:\n' > "$CO/$f"
        chmod 644 "$CO/$f"
    done
    git init -q "$CO"
    HOOKS="$CO/.git/hooks"
}

@test "setup-hooks: it installs both hooks, pointing into this checkout" {
    run "$CO/setup-hooks.sh"
    assert_success
    [ -L "$HOOKS/pre-commit" ]
    [ -L "$HOOKS/post-merge" ]
    [ "$(readlink "$HOOKS/pre-commit")" = "$CO/scripts/pre-commit" ]
    [ "$(readlink "$HOOKS/post-merge")" = "$CO/scripts/post-merge" ]
}

@test "setup-hooks: the symlink targets are absolute" {
    # Hooks are shared by every worktree through the common git dir, so a
    # relative target resolves differently depending on which worktree git
    # happens to run the hook from. The script's own header says so; this is the
    # assertion that says it too.
    run "$CO/setup-hooks.sh"
    assert_success
    [[ "$(readlink "$HOOKS/pre-commit")" == /* ]]
    [[ "$(readlink "$HOOKS/post-merge")" == /* ]]
}

@test "setup-hooks: it makes the hook scripts executable" {
    # The symlinks are created before this happens, so a failure here leaves a
    # repo whose hooks are installed and cannot run -- the exact state that is
    # indistinguishable from working.
    [ ! -x "$CO/scripts/pre-commit" ]
    run "$CO/setup-hooks.sh"
    assert_success
    [ -x "$CO/scripts/pre-commit" ]
    [ -x "$CO/scripts/post-merge" ]
    [ -x "$CO/scripts/sync-nas.sh" ]
    [ -x "$CO/scripts/lib/check-x.sh" ]
}

@test "setup-hooks: running it twice is idempotent, and says what it replaced" {
    run "$CO/setup-hooks.sh"
    assert_success
    refute_output --partial "Removed existing"

    run "$CO/setup-hooks.sh"
    assert_success
    assert_output --partial "Removed existing pre-commit hook"
    assert_output --partial "Removed existing post-merge hook"
    [ "$(readlink "$HOOKS/pre-commit")" = "$CO/scripts/pre-commit" ]
}

@test "setup-hooks: DEFECT - a broken symlink is replaced, not fatal" {
    # The situation this script exists to repair: the checkout it pointed at was
    # moved or renamed, so the hooks silently stopped running. `[[ -e ]]` follows
    # the link, so a dangling one read as "nothing here", the rm never ran, and
    # ln -s died with "File exists" under set -e. Re-running the repair was the
    # one thing that could not work.
    ln -s "/nowhere/that/exists/pre-commit" "$HOOKS/pre-commit"
    run "$CO/setup-hooks.sh"
    assert_success
    [ "$(readlink "$HOOKS/pre-commit")" = "$CO/scripts/pre-commit" ]
}

@test "setup-hooks: it replaces a regular file, not only a symlink" {
    # git ships sample hooks as regular files; a repo that once had a real
    # pre-commit script has one too.
    printf '#!/bin/sh\nexit 0\n' > "$HOOKS/pre-commit"
    run "$CO/setup-hooks.sh"
    assert_success
    [ -L "$HOOKS/pre-commit" ]
}

@test "setup-hooks: a replacement that fails is fatal, not a success report" {
    # "Installed, correctly linked and inert" is this script's recorded failure
    # mode, so the status it exits with has to mean something. Removal is not
    # guaranteed to work: `rm` refuses a directory, and when the rm fails the
    # ln -s eight lines later fails too ("File exists"). The file's own set -e is
    # what stops there. With errexit gone the script walks to the end and prints
    # "Created symlink: ..." for a path it never replaced, then
    # "Done! Hooks installed: pre-commit, post-merge." -- exit 0, no pre-commit
    # hook, and nothing in the output saying so.
    mkdir "$HOOKS/pre-commit"
    run "$CO/setup-hooks.sh"
    assert_failure
    refute_output --partial "Done! Hooks installed"
    refute_output --partial "Created symlink"
}

@test "setup-hooks: in a worktree the hooks land in the common git dir" {
    # The whole reason this script uses --git-common-dir rather than [[ -d .git ]].
    # In a worktree .git is a FILE, so the naive check reads "not a git repo",
    # the script exits, and no hook is installed -- which is how a static-IP
    # collision reached this repo uncaught once already.
    # Committed, not just present: a worktree is populated from a commit, so an
    # uncommitted scripts/ dir would leave $wt empty and the test would be
    # measuring nothing.
    ( cd "$CO" && git add -A \
        && git -c user.email=t@example.com -c user.name=t commit -q -m init )
    local wt="$BATS_TEST_TMPDIR/wt"
    ( cd "$CO" && git worktree add -q -b wt-branch "$wt" ) || skip "git worktree unavailable"

    run "$wt/setup-hooks.sh"
    assert_success
    # Installed into the ORIGINAL repo's hooks dir, and pointing at the
    # worktree's own scripts.
    [ -L "$HOOKS/pre-commit" ]
    [ "$(readlink "$HOOKS/pre-commit")" = "$wt/scripts/pre-commit" ]
}

@test "setup-hooks: outside a git repo it refuses and installs nothing" {
    local bare="$BATS_TEST_TMPDIR/notarepo"
    mkdir -p "$bare/scripts/lib"
    cp "$REPO_ROOT/setup-hooks.sh" "$bare/setup-hooks.sh"
    chmod +x "$bare/setup-hooks.sh"

    # A directory with no git repo anywhere above it. $BATS_TEST_TMPDIR is under
    # /tmp, so this holds -- but assert it rather than assume it, because the
    # test would otherwise pass by finding THIS repo and installing hooks in it.
    if git -C "$bare" rev-parse --git-common-dir >/dev/null 2>&1; then
        skip "the test tmpdir is inside a git repo; this check would install hooks in it"
    fi

    run "$bare/setup-hooks.sh"
    [ "$status" -eq 1 ]
    assert_output --partial "ERROR: Not a git repository"
}

@test "setup-hooks: it installs exactly the hooks this repo actually ships" {
    # Derived, not restated. A third hook added under scripts/ and not wired in
    # here would otherwise be invisible: the script would keep passing while the
    # new hook never ran on anyone's machine.
    run "$CO/setup-hooks.sh"
    assert_success

    # The filter is git's own hook vocabulary, not a heuristic like "has no
    # extension" -- scripts/ also holds boot-compose-up.service, which is not a
    # hook and never will be.
    local hook
    for hook in applypatch-msg pre-applypatch post-applypatch pre-commit \
                pre-merge-commit prepare-commit-msg commit-msg post-commit \
                pre-rebase post-checkout post-merge pre-push pre-receive \
                update post-receive post-update push-to-checkout pre-auto-gc \
                post-rewrite sendemail-validate; do
        [ -f "$REPO_ROOT/scripts/$hook" ] || continue
        [ -L "$HOOKS/$hook" ] || {
            echo "scripts/$hook is a git hook but setup-hooks.sh never installs it"
            return 1
        }
    done
}
