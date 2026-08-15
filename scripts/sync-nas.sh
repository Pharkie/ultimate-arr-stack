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

if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$NAS_SYNC_HOST" true 2>/dev/null; then
    echo "sync-nas: ${NAS_SYNC_HOST} unreachable — skipping NAS sync" >&2
    exit 0
fi

echo "sync-nas: syncing ${BRANCH} on ${NAS_SYNC_HOST}:${NAS_SYNC_PATH} ..."

ARRGIT="docker run --rm -v '${NAS_SYNC_PATH}:/repo' -w /repo alpine/git -c safe.directory=/repo"
ssh "$NAS_SYNC_HOST" "
    ${ARRGIT} fetch origin '${BRANCH}' &&
    ${ARRGIT} checkout '${BRANCH}' &&
    ${ARRGIT} pull --ff-only origin '${BRANCH}'
"

echo "sync-nas: done."
echo "sync-nas: note — this only pulled files. If any compose/service file"
echo "          changed, recreate the affected service manually via its own"
echo "          compose file (see CLAUDE.md)."
