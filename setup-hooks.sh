#!/bin/bash
# Installs this repo's pre-commit hook. Run once per clone: ./setup-hooks.sh
#
# Generated with LLM assistance and human-reviewed. Read it before you run it.

set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$REPO/scripts/pre-commit"

echo "Installing git hooks for ultimate-arr-stack..."
echo ""

# Let git say where hooks go. Every worktree of a clone shares the hooks of the
# main .git directory, and inside a worktree .git is just a pointer file, so a
# test for a .git directory would wrongly give up there.
if ! COMMON_GIT_DIR="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    echo "ERROR: $REPO is not inside a git clone."
    exit 1
fi
HOOKS_DIR="$COMMON_GIT_DIR/hooks"
mkdir -p "$HOOKS_DIR"

# Link by full path, so the hook resolves the same from any worktree and always
# runs the current scripts/pre-commit. -f replaces an old hook or copy.
ln -sfn "$HOOK_SRC" "$HOOKS_DIR/pre-commit"
echo "  Linked $HOOKS_DIR/pre-commit -> $HOOK_SRC"

chmod +x "$HOOK_SRC" "$REPO"/scripts/lib/*.sh
echo "  Made the hook and its checks executable"

# ---------------------------------------------------------------------------
# PyYAML, for the hook's YAML syntax check.
#
# If the system python3 already has it (most Linux, including the NAS), do
# nothing. Otherwise build a repo-local .venv — macOS ships an
# externally-managed Python (PEP 668) that refuses `pip install`, which is why
# the check used to run degraded on exactly the machine where commits happen.
# ---------------------------------------------------------------------------
if python3 -c "import yaml" 2>/dev/null; then
    echo "  PyYAML: already available via system python3"
elif [[ -x "$REPO/.venv/bin/python3" ]] && "$REPO/.venv/bin/python3" -c "import yaml" 2>/dev/null; then
    echo "  PyYAML: already available via .venv"
elif python3 -m venv "$REPO/.venv" 2>/dev/null &&
     "$REPO/.venv/bin/pip" install --quiet pyyaml 2>/dev/null; then
    echo "  PyYAML: installed into .venv (gitignored)"
else
    echo "  WARNING: could not provide PyYAML."
    echo "           The hook will fall back to 'docker compose config', or"
    echo "           report YAML validation as SKIPPED if that is missing too."
fi

echo ""
echo "Done. The hook now runs on every 'git commit'."
echo "Run it by hand: ./scripts/pre-commit"
echo "Remove it:      rm \"$HOOKS_DIR/pre-commit\""
