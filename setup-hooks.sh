#!/bin/bash
# Setup script for pre-commit hooks
# Run once after cloning: ./setup-hooks.sh
#
# Works from a plain checkout or from inside a git worktree. In a worktree,
# `.git` is a file (a gitdir pointer), not a directory, and hooks live in
# the *common* git dir shared by every worktree of the repo — a plain
# `[[ -d .git ]]` check misdetects a worktree as "not a git repo" and this
# script silently never runs, which is exactly how a prior static-IP
# collision landed uncaught (the hook that would have blocked it was never
# installed in that worktree).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Setting up git hooks for ultimate-arr-stack..."
echo ""

# Check we're in a git repo (works for both a plain checkout and a worktree)
if ! GIT_COMMON_DIR="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    echo "ERROR: Not a git repository. Run this from the repo root."
    exit 1
fi

HOOKS_DIR="$GIT_COMMON_DIR/hooks"

# Create hooks directory if needed
mkdir -p "$HOOKS_DIR"

# Remove existing hooks if present
for hook in pre-commit post-merge; do
    if [[ -e "$HOOKS_DIR/$hook" ]]; then
        rm "$HOOKS_DIR/$hook"
        echo "  Removed existing $hook hook"
    fi
done

# Create symlinks. Hooks are shared across every worktree via the common git
# dir, so use an absolute path to this checkout's scripts/<hook> rather than
# a relative path that assumes a non-worktree layout.
ln -s "$SCRIPT_DIR/scripts/pre-commit" "$HOOKS_DIR/pre-commit"
echo "  Created symlink: $HOOKS_DIR/pre-commit -> $SCRIPT_DIR/scripts/pre-commit"
ln -s "$SCRIPT_DIR/scripts/post-merge" "$HOOKS_DIR/post-merge"
echo "  Created symlink: $HOOKS_DIR/post-merge -> $SCRIPT_DIR/scripts/post-merge"

# Ensure scripts are executable
chmod +x "$SCRIPT_DIR/scripts/pre-commit"
chmod +x "$SCRIPT_DIR/scripts/post-merge"
chmod +x "$SCRIPT_DIR/scripts/sync-nas.sh"
chmod +x "$SCRIPT_DIR/scripts/lib/"*.sh
echo "  Made scripts executable"

echo ""
echo "Done! Hooks installed: pre-commit, post-merge."
echo ""
echo "pre-commit runs automatically on 'git commit'. To test manually: ./scripts/pre-commit"
echo "post-merge auto-syncs tracked files to the NAS after a local merge/pull lands on"
echo "main (see scripts/sync-nas.sh) — no-op on any other branch. To test manually:"
echo "  ./scripts/sync-nas.sh"
echo ""
echo "To uninstall: rm \"$HOOKS_DIR/pre-commit\" \"$HOOKS_DIR/post-merge\""
