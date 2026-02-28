#!/bin/bash
# Setup script for pre-commit hooks
# Run once after cloning: ./setup-hooks.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/.git/hooks"

echo "Setting up git hooks for ultimate-arr-stack..."
echo ""

# Check we're in a git repo
if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
    echo "ERROR: Not a git repository. Run this from the repo root."
    exit 1
fi

# Create hooks directory if needed
mkdir -p "$HOOKS_DIR"

# Remove existing hook if present
if [[ -e "$HOOKS_DIR/pre-commit" ]]; then
    rm "$HOOKS_DIR/pre-commit"
    echo "  Removed existing pre-commit hook"
fi

# Create symlink (relative path so it works if repo is moved)
ln -s "../../scripts/pre-commit" "$HOOKS_DIR/pre-commit"
echo "  Created symlink: .git/hooks/pre-commit -> scripts/pre-commit"

# Ensure scripts are executable
chmod +x "$SCRIPT_DIR/scripts/pre-commit"
chmod +x "$SCRIPT_DIR/scripts/lib/"*.sh
echo "  Made scripts executable"

echo ""
echo "Done! Pre-commit hook installed."
echo ""
echo "The hook will run automatically on 'git commit'."
echo "To test manually: ./scripts/pre-commit"
echo ""
echo "To uninstall: rm .git/hooks/pre-commit"
