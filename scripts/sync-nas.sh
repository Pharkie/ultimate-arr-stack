#!/bin/bash
set -euo pipefail
#
# Sync the NAS deploy copy to whatever branch is checked out locally, via
# `git fetch`/`checkout`/`pull` run remotely on the NAS itself through a
# containerized `alpine/git` image. Native git can't be installed on this
# NAS's OS (`apt-get install git` fails on unmet deps that are tangled with
# unrelated vendor-pinned packages — don't try to force it with
# `apt --fix-broken install`, that risks cascading into Ugreen's pinned
# packages). The NAS repo itself was bootstrapped from a verified-identical
# fresh clone on 2026-08-15.
#
# Retired 2026-08-15: this used to be a tar-over-SSH file push (this NAS's
# own `rsync` binary is a vendor-patched backup-daemon wrapper, not a normal
# rsync server, so tar-over-SSH was the workaround at the time). `git pull`
# is simpler now that real git works on the NAS and doesn't require
# re-copying the entire tracked tree on every sync.
#
# Syncs the CURRENT LOCAL branch (feature branch pre-merge, main post-merge)
# — matches CLAUDE.md's branch-first deploy workflow, where the same command
# is used both to push a feature branch out for NAS testing and to sync main
# afterward. Run automatically by the post-merge hook (see setup-hooks.sh,
# main only) for local merges; must be run manually after a `gh pr merge`,
# since a remote GitHub-side merge doesn't fire any local git hook.
#
# This pulls files ONLY. It never recreates containers — after a sync that
# touches compose/service files, recreate the affected service(s) manually
# via their own compose file, per CLAUDE.md's deploy rules.
#
# Usage:
#   ./scripts/sync-nas.sh
#
# Env overrides:
#   NAS_SYNC_HOST=arr-stack-nas
#   NAS_SYNC_PATH=/volume1/docker/arr-stack

NAS_SYNC_HOST="${NAS_SYNC_HOST:-arr-stack-nas}"
NAS_SYNC_PATH="${NAS_SYNC_PATH:-/volume1/docker/arr-stack}"

cd "$(git rev-parse --show-toplevel)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
LOCAL_SHA="$(git rev-parse HEAD)"

# Reachability: a FAILURE, not a skip.
#
# This used to `exit 0` here. That made "the NAS is unreachable" and "the NAS
# is synced" the same observable outcome, and the post-merge hook -- which is
# the only automatic caller -- printed nothing either way. Exiting non-zero is
# safe for that caller: it explicitly tolerates a failure and says so out loud.
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$NAS_SYNC_HOST" true 2>/dev/null; then
    echo "sync-nas: ${NAS_SYNC_HOST} unreachable - NAS NOT synced" >&2
    exit 1
fi

# `timeout` is GNU coreutils. macOS ships neither it nor `gtimeout` (that one
# needs Homebrew coreutils), so calling it bare made this script exit 127 having
# printed NOTHING on the maintainer's Mac -- and the post-merge hook, whose only
# job is to invoke this script, could then only report that the deploy had
# failed, with no reason to look at. Prefer timeout, then gtimeout, then perl's
# alarm, which is in the base system on both macOS and Debian.
bounded() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        echo "sync-nas: no timeout, gtimeout or perl on PATH - cannot bound the remote call" >&2
        return 1
    fi
}

# The NAS pulls from origin, so origin -- not the local repo -- decides what it
# can reach. A local commit that has not been pushed is invisible to it, and the
# remote pull then succeeds with "Already up to date." while leaving the NAS on
# the old commit. Measured 2026-08-31: local at 90e72c4, NAS at 93c8ed4, this
# script printed "done." and exited 0. Compare against the remote ref before
# doing anything, so the impossible case fails before it can look like success.
REMOTE_SHA="$(GIT_TERMINAL_PROMPT=0 bounded 20 git ls-remote origin "refs/heads/${BRANCH}" 2>/dev/null | awk '{print $1}')"
if [[ -z "$REMOTE_SHA" ]]; then
    echo "sync-nas: origin has no branch '${BRANCH}' - push it first, the NAS pulls from origin" >&2
    exit 1
fi
if [[ "$REMOTE_SHA" != "$LOCAL_SHA" ]]; then
    echo "sync-nas: local ${BRANCH} (${LOCAL_SHA:0:7}) != origin/${BRANCH} (${REMOTE_SHA:0:7})" >&2
    echo "sync-nas: the NAS can only reach what origin has - NAS NOT synced" >&2
    echo "sync-nas: push (or pull) so the two agree, then re-run this script" >&2
    exit 1
fi

echo "sync-nas: syncing ${BRANCH} (${LOCAL_SHA:0:7}) on ${NAS_SYNC_HOST}:${NAS_SYNC_PATH} ..."

ARRGIT="docker run --rm -v '${NAS_SYNC_PATH}:/repo' -w /repo alpine/git -c safe.directory=/repo"

# Every ssh below carries an explicit ConnectTimeout. The probe above proves the
# NAS answered a moment ago, not that it still will: a NAS that stops answering
# between the probe and here parks a bare `ssh` on the OS-default TCP connect
# timeout for ~2 minutes. This project has already paid for that once -- a CI
# step sat there before anyone realised the connection was never being made --
# and it is worse in a git hook, which holds up the merge that invoked it.
SSH_OPTS=(-o ConnectTimeout=15 -o BatchMode=yes)

ssh "${SSH_OPTS[@]}" "$NAS_SYNC_HOST" "
    ${ARRGIT} fetch origin '${BRANCH}' &&
    ${ARRGIT} checkout '${BRANCH}' &&
    ${ARRGIT} pull --ff-only origin '${BRANCH}'
"

# Verify the OUTCOME, not the exit status of the commands that were supposed to
# produce it. Every silent-success bug this script has had shared one shape: a
# step reported OK and nobody asked the NAS what it was actually holding. Ask.
NAS_STATE="$(ssh "${SSH_OPTS[@]}" "$NAS_SYNC_HOST" "${ARRGIT} rev-parse HEAD && ${ARRGIT} rev-parse --abbrev-ref HEAD" 2>/dev/null || true)"
NAS_SHA="$(sed -n 1p <<<"$NAS_STATE")"
NAS_BRANCH="$(sed -n 2p <<<"$NAS_STATE")"
if [[ "$NAS_SHA" != "$LOCAL_SHA" || "$NAS_BRANCH" != "$BRANCH" ]]; then
    echo "sync-nas: VERIFICATION FAILED - the NAS did not reach the intended commit" >&2
    echo "sync-nas:   wanted ${BRANCH} @ ${LOCAL_SHA}" >&2
    echo "sync-nas:   got    ${NAS_BRANCH:-<none>} @ ${NAS_SHA:-<none>}" >&2
    exit 1
fi

echo "sync-nas: verified ${NAS_SYNC_HOST} is on ${BRANCH} @ ${NAS_SHA:0:7}."
echo "sync-nas: note - this only pulled files. If any compose/service file"
echo "          changed, recreate the affected service manually via its own"
echo "          compose file (see CLAUDE.md)."
