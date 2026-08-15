#!/bin/bash
set -euo pipefail
#
# Sync git-tracked files in the current checkout to the NAS deploy path.
# The NAS has no git installed (deployment is file sync, not `git checkout`)
# so this is what keeps its plain-file copy from drifting out of sync with
# local `main` after a merge/pull. Run automatically by the post-merge hook
# (see setup-hooks.sh) for local merges; must be run manually after a
# `gh pr merge`, since a remote GitHub-side merge doesn't fire any local
# git hook.
#
# Uses tar piped over plain SSH rather than rsync: this NAS's rsync binary
# is a vendor-patched wrapper tied to its own backup daemon (tries to setuid
# to root and rejects a plain filesystem path with "invalid path") rather
# than a normal rsync-over-SSH server, confirmed live 2026-08-15. Also sets
# COPYFILE_DISABLE=1 — without it, macOS's tar injects AppleDouble `._*`
# resource-fork files and xattr headers into the stream (same cruft seen
# when the stremio-jellyfin source was first pulled off this NAS via scp).
#
# Only ever touches paths `git ls-files` reports for the current checkout —
# never .env, .claude/config.local.md, or any other NAS-local/gitignored
# file, since those simply aren't in that list, and tar only ever creates/
# overwrites the paths in the stream — it doesn't delete anything on the
# remote that's since been removed locally (a stale file left behind after
# a local `git rm` needs manual cleanup on the NAS).
#
# This copies files ONLY. It never recreates containers — after a sync that
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

if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$NAS_SYNC_HOST" true 2>/dev/null; then
    echo "sync-nas: ${NAS_SYNC_HOST} unreachable — skipping NAS sync" >&2
    exit 0
fi

echo "sync-nas: syncing tracked files to ${NAS_SYNC_HOST}:${NAS_SYNC_PATH} ..."

git ls-files -z | COPYFILE_DISABLE=1 tar cf - --null -T - \
    | ssh "$NAS_SYNC_HOST" "tar xf - -C '$NAS_SYNC_PATH'" 2>&1 \
    | grep -v "Ignoring unknown extended header keyword" || true

echo "sync-nas: done."
echo "sync-nas: note — this only copied files. If any compose/service file"
echo "          changed, recreate the affected service manually via its own"
echo "          compose file (see CLAUDE.md)."
