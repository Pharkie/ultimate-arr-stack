#!/usr/bin/env bats
# The NAS sync path, tested by RUNNING it.
#
# tests/hooks-installed.bats already asserts the post-merge symlink exists. It
# passed for the hook's entire life while the hook did nothing at all: it
# derived the repo root from ${BASH_SOURCE[0]}, which git sets to the path
# inside the git dir (.git/hooks/post-merge). bash does not resolve that
# symlink, so `git -C .git/hooks rev-parse --show-toplevel` fatalled, `|| true`
# swallowed it, and an `exit 0` guard meant for "not a git repo" fired on every
# merge. Installed, executable, correctly targeted -- and inert.
#
# So these tests never inspect the text of the scripts. They build a throwaway
# git repo with a real origin, install the hook the way setup-hooks.sh does,
# invoke it the way git does, and assert on what actually happened.

setup() {
    load helpers/setup
    command -v git >/dev/null 2>&1 \
        || skip "no host git binary on this machine (the NAS drives this repo through a containerised alpine/git)"
    FX="$BATS_TEST_TMPDIR/fx"
    REPO="$FX/repo"
    ORIGIN="$FX/origin.git"
    MARKER="$BATS_TEST_TMPDIR/sync-was-called"
    export MARKER
}

# A repo that looks like this one at hook time: on `main`, with an `origin`
# that already has that commit, and scripts/sync-nas.sh in place.
make_fixture() {
    mkdir -p "$REPO/scripts"
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main
    git -C "$REPO" config user.email t@example.com
    git -C "$REPO" config user.name  t
    git -C "$REPO" config commit.gpgsign false
    # A stub in place of the real sync: records that it ran, and from where.
    # `$PWD` is recorded because a hook that resolves the wrong root would run
    # the wrong script -- or none -- and that is the bug under test.
    cat > "$REPO/scripts/sync-nas.sh" <<'STUB'
#!/bin/bash
echo "$PWD" > "$MARKER"
exit "${SYNC_RC:-0}"
STUB
    chmod +x "$REPO/scripts/sync-nas.sh"
    cp "$REPO_ROOT/scripts/post-merge" "$REPO/scripts/post-merge"
    chmod +x "$REPO/scripts/post-merge"
    echo one > "$REPO/file.txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm initial
    git init --bare -q "$ORIGIN"
    git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
    git -C "$REPO" remote add origin "$ORIGIN"
    git -C "$REPO" push -q origin main
    # Exactly what setup-hooks.sh installs: an absolute symlink into scripts/.
    ln -sf "$REPO/scripts/post-merge" "$REPO/.git/hooks/post-merge"
}

# Git runs hooks with the working directory at the top of the work tree and
# invokes them by their path inside the git dir. Reproduce both.
run_hook() {
    cd "$REPO" && run ./.git/hooks/post-merge
}

@test "post-merge actually runs the NAS sync when main is already on origin" {
    make_fixture
    run_hook
    [ "$status" -eq 0 ] || { echo "hook exited $status"; echo "$output"; return 1; }
    [ -f "$MARKER" ] || {
        echo "the hook did NOT invoke scripts/sync-nas.sh - it is inert."
        echo "This is the exact defect the hook shipped with: it could not"
        echo "resolve its own repo root and exited 0 without a word."
        echo "hook output was: $output"
        return 1
    }
    [ "$(cat "$MARKER")" = "$REPO" ] || {
        echo "sync ran from $(cat "$MARKER"), expected $REPO"
        return 1
    }
}

@test "post-merge pushes an unpushed main so the NAS can reach it" {
    make_fixture
    echo two > "$REPO/file.txt"
    git -C "$REPO" commit -qam second
    local local_sha; local_sha=$(git -C "$REPO" rev-parse HEAD)
    run_hook
    [ "$status" -eq 0 ] || { echo "hook exited $status"; echo "$output"; return 1; }
    local origin_sha; origin_sha=$(git -C "$ORIGIN" rev-parse refs/heads/main)
    [ "$origin_sha" = "$local_sha" ] || {
        echo "origin/main is $origin_sha, expected $local_sha."
        echo "The NAS pulls from origin, so an unpushed merge can never reach it."
        return 1
    }
    [ -f "$MARKER" ] || { echo "sync did not run after the push"; return 1; }
}

@test "post-merge refuses to push a dirty tree, and says so" {
    make_fixture
    echo two > "$REPO/file.txt"
    git -C "$REPO" commit -qam second
    echo dirty > "$REPO/file.txt"
    run_hook
    [ "$status" -eq 0 ] || { echo "the hook must never fail a merge; exited $status"; return 1; }
    [ ! -f "$MARKER" ] || { echo "synced despite a dirty tree"; return 1; }
    [[ "$output" == *"dirty"* ]] || { echo "said nothing about the dirty tree: $output"; return 1; }
    local origin_sha; origin_sha=$(git -C "$ORIGIN" rev-parse refs/heads/main)
    [ "$origin_sha" != "$(git -C "$REPO" rev-parse HEAD)" ] || { echo "pushed anyway"; return 1; }
}

@test "post-merge refuses to push when main has diverged from origin" {
    make_fixture
    # Advance origin behind our back, then commit locally: neither is an
    # ancestor of the other. A hook must never resolve that by forcing.
    local clone="$FX/other"
    git clone -q -b main "$ORIGIN" "$clone"
    git -C "$clone" config user.email t@example.com
    git -C "$clone" config user.name t
    echo theirs > "$clone/file.txt"
    git -C "$clone" commit -qam theirs
    git -C "$clone" push -q origin main
    git -C "$REPO" fetch -q origin
    echo ours > "$REPO/file.txt"
    git -C "$REPO" commit -qam ours
    run_hook
    [ "$status" -eq 0 ] || { echo "the hook must never fail a merge; exited $status"; return 1; }
    [ ! -f "$MARKER" ] || { echo "synced despite divergence"; return 1; }
    [[ "$output" == *"diverged"* ]] || { echo "said nothing about divergence: $output"; return 1; }
}

@test "post-merge is silent and inert on a branch that is not main" {
    make_fixture
    git -C "$REPO" checkout -qb feature/x
    run_hook
    [ "$status" -eq 0 ]
    [ ! -f "$MARKER" ] || { echo "synced from a feature branch"; return 1; }
    [ -z "$output" ] || { echo "expected no output off main, got: $output"; return 1; }
}

@test "post-merge reports a failed sync instead of swallowing it" {
    make_fixture
    SYNC_RC=1 run_hook
    [ "$status" -eq 0 ] || { echo "a failed sync must not fail the merge; exited $status"; return 1; }
    [ -f "$MARKER" ] || { echo "sync never ran"; return 1; }
    [[ "$output" == *"FAILED"* ]] || {
        echo "a failing sync produced no complaint - indistinguishable from success: $output"
        return 1
    }
}

# --- scripts/sync-nas.sh --------------------------------------------------
#
# Driven against a stub `ssh` on PATH, so the NAS is never involved. What is
# being tested is the script's own reporting, which is where all three of its
# silent-success bugs lived.

# $1: what the stub should print for the post-sync `rev-parse HEAD` check.
#     Empty means the stub fails outright.
install_ssh_stub() {
    mkdir -p "$FX/bin"
    cat > "$FX/bin/ssh" <<STUB
#!/bin/bash
if [[ "\$*" == *"rev-parse HEAD"* ]]; then
    [[ -n "$1" ]] || exit 1
    echo "$1"
    echo "${2:-main}"
fi
exit 0
STUB
    chmod +x "$FX/bin/ssh"
    PATH="$FX/bin:$PATH"
}

use_real_sync_script() {
    cp "$REPO_ROOT/scripts/sync-nas.sh" "$REPO/scripts/sync-nas.sh"
    chmod +x "$REPO/scripts/sync-nas.sh"
}

@test "sync-nas fails when the NAS is unreachable instead of exiting 0" {
    make_fixture
    use_real_sync_script
    mkdir -p "$FX/bin"
    printf '#!/bin/bash\nexit 255\n' > "$FX/bin/ssh"
    chmod +x "$FX/bin/ssh"
    cd "$REPO"
    PATH="$FX/bin:$PATH" run ./scripts/sync-nas.sh
    [ "$status" -ne 0 ] || {
        echo "exited 0 with the NAS unreachable - 'not synced' and 'synced'"
        echo "were the same observable outcome, which is how this went unnoticed"
        return 1
    }
    [[ "$output" == *"NOT synced"* ]] || { echo "unclear message: $output"; return 1; }
}

@test "sync-nas refuses when the local commit is not on origin" {
    make_fixture
    use_real_sync_script
    install_ssh_stub "$(git -C "$REPO" rev-parse HEAD)"
    echo two > "$REPO/file.txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "unpushed"
    cd "$REPO"
    PATH="$FX/bin:$PATH" run ./scripts/sync-nas.sh
    [ "$status" -ne 0 ] || {
        echo "reported success for a commit origin does not have - the NAS pulls"
        echo "from origin, so this run could not possibly have deployed it"
        return 1
    }
    [[ "$output" == *"NOT synced"* ]] || { echo "unclear message: $output"; return 1; }
}

@test "sync-nas fails when the NAS ends up on the wrong commit" {
    make_fixture
    use_real_sync_script
    install_ssh_stub "0000000000000000000000000000000000000000"
    cd "$REPO"
    PATH="$FX/bin:$PATH" run ./scripts/sync-nas.sh
    [ "$status" -ne 0 ] || {
        echo "the remote commands succeeded and the script believed them."
        echo "Nothing asked the NAS what commit it was actually holding."
        return 1
    }
    [[ "$output" == *"VERIFICATION FAILED"* ]] || { echo "unclear message: $output"; return 1; }
}

@test "sync-nas fails when the NAS ends up on the wrong branch" {
    make_fixture
    use_real_sync_script
    install_ssh_stub "$(git -C "$REPO" rev-parse HEAD)" "feat/left-behind"
    cd "$REPO"
    PATH="$FX/bin:$PATH" run ./scripts/sync-nas.sh
    [ "$status" -ne 0 ] || {
        echo "right commit, wrong branch, reported as success. A NAS left on a"
        echo "feature branch is what cost 38 hours of dead downloads once."
        return 1
    }
    [[ "$output" == *"VERIFICATION FAILED"* ]] || { echo "unclear message: $output"; return 1; }
}

@test "sync-nas reports success only after verifying the NAS commit" {
    make_fixture
    use_real_sync_script
    install_ssh_stub "$(git -C "$REPO" rev-parse HEAD)"
    cd "$REPO"
    PATH="$FX/bin:$PATH" run ./scripts/sync-nas.sh
    [ "$status" -eq 0 ] || { echo "the happy path must pass; exited $status: $output"; return 1; }
    [[ "$output" == *"verified"* ]] || { echo "claimed done without verifying: $output"; return 1; }
}

@test "sync-nas refuses a branch origin has never seen" {
    make_fixture
    use_real_sync_script
    install_ssh_stub "$(git -C "$REPO" rev-parse HEAD)"
    git -C "$REPO" checkout -qb feat/never-pushed
    cd "$REPO"
    PATH="$FX/bin:$PATH" run ./scripts/sync-nas.sh
    [ "$status" -ne 0 ] || {
        echo "reported success for a branch that does not exist on origin"
        return 1
    }
    [[ "$output" == *"no branch"* ]] || { echo "unclear message: $output"; return 1; }
}

@test "sync-nas does not require GNU timeout (a stock macOS has none)" {
    # This script bounded its `git ls-remote` with a bare `timeout`. macOS ships
    # neither `timeout` nor `gtimeout` (the latter needs Homebrew coreutils), so
    # on the maintainer's Mac the script exited 127 having printed NOTHING -- and
    # the post-merge hook, whose only job is to invoke it, could report that the
    # deploy had failed but not why. Reproduced by running the real script with a
    # PATH built from just the tools it needs and no timeout binary anywhere on
    # it, which is also the state of a Debian host mid-bootstrap.
    make_fixture
    use_real_sync_script
    install_ssh_stub "$(git -C "$REPO" rev-parse HEAD)"
    local bin="$FX/minbin" tool p
    mkdir -p "$bin"
    for tool in bash git awk sed grep cat perl; do
        p="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$p" "$bin/$tool"
    done
    # The stub, not the real ssh: this test is about the bound, not the network.
    ln -sf "$FX/bin/ssh" "$bin/ssh"
    cd "$REPO"
    PATH="$bin" run ./scripts/sync-nas.sh
    [ "$status" -eq 0 ] \
        || { echo "exited $status with no timeout binary on PATH: $output"; return 1; }
    [[ "$output" == *"verified"* ]] \
        || { echo "never reached the verification step: $output"; return 1; }
}
