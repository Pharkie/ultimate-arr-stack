# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for setup-hooks.sh.
#
# Safe to run: tests/setup-hooks.bats copies the script into a throwaway git
# repo under $BATS_TEST_TMPDIR and runs it there, so a mutant installs its hooks
# into that repo's .git/hooks and never touches this one.

mutation setup-hooks-broken-symlink-fatal \
  --file setup-hooks.sh \
  --bats tests/setup-hooks.bats \
  --test "setup-hooks: DEFECT - a broken symlink is replaced, not fatal" \
  --why "drops the -L half of the removal guard. -e follows the link, so a hook pointing at a checkout that was moved or renamed reads as absent, the rm is skipped, and ln -s dies with 'File exists' under set -e. The failure lands precisely on the person re-running the repair because their hooks stopped working" \
  --apply 'sed -i "s@if \[\[ -e \"\$HOOKS_DIR/\$hook\" || -L \"\$HOOKS_DIR/\$hook\" \]\]@if [[ -e \"\$HOOKS_DIR/\$hook\" ]]@" "$F"'

mutation setup-hooks-relative-symlink \
  --file setup-hooks.sh \
  --bats tests/setup-hooks.bats \
  --test "setup-hooks: the symlink targets are absolute" \
  --why "links to a relative path instead of an absolute one. Hooks live in the common git dir shared by every worktree, so a relative target resolves against whichever worktree git happens to run the hook from - it works in the checkout it was created from and silently points at nothing everywhere else" \
  --apply 'sed -i "s@ln -s \"\$SCRIPT_DIR/scripts/pre-commit\"@ln -s \"scripts/pre-commit\"@" "$F"'

mutation setup-hooks-chmod-dropped \
  --file setup-hooks.sh \
  --bats tests/setup-hooks.bats \
  --test "setup-hooks: it makes the hook scripts executable" \
  --why "stops making the hook scripts executable. The symlinks are still created, git still finds them, and a non-executable hook is skipped by git without an error - installed, correctly linked, and inert, which is the exact state the post-merge hook sat in for months" \
  --apply 'sed -i "/^chmod +x \"\$SCRIPT_DIR\/scripts\/pre-commit\"$/d" "$F"'

mutation setup-hooks-git-dir-not-common \
  --file setup-hooks.sh \
  --bats tests/setup-hooks.bats \
  --test "setup-hooks: in a worktree the hooks land in the common git dir" \
  --why "asks for --git-dir instead of --git-common-dir. In a plain checkout the two are the same path, so every non-worktree test still passes; inside a worktree the hooks land in that worktree's private git dir, where git does look for them - but they are then absent from every other worktree and from the main checkout. This is the mutation that proves the worktree test is doing work rather than being a second copy of test 1" \
  --apply 'sed -i "s@--path-format=absolute --git-common-dir@--path-format=absolute --git-dir@" "$F"'

mutation setup-hooks-missing-repo-succeeds \
  --file setup-hooks.sh \
  --bats tests/setup-hooks.bats \
  --test "setup-hooks: outside a git repo it refuses and installs nothing" \
  --why "reports the error and exits 0 anyway. Anything driving this script - a bootstrap, a CI step, a human reading the last line - sees success and stops looking, while no hook was installed at all. An absent tool must never read as a pass" \
  --apply 'sed -i "/ERROR: Not a git repository/{n;s@    exit 1@    exit 0@}" "$F"'

mutation setup-hooks-post-merge-not-installed \
  --file setup-hooks.sh \
  --bats tests/setup-hooks.bats \
  --test "setup-hooks: it installs exactly the hooks this repo actually ships" \
  --why "installs pre-commit but not post-merge, while the closing summary still claims both. post-merge is what syncs main to the NAS after a merge, so its absence means merges land locally and the NAS quietly keeps running the previous commit - indistinguishable from a deployed one" \
  --apply 'sed -i "/^ln -s \"\$SCRIPT_DIR\/scripts\/post-merge\"/d" "$F"'

# --- Entries below close gaps the generative sweep found, not gaps anyone
# --- thought of first.

mutation setup-hooks-errexit-dropped \
  --file setup-hooks.sh \
  --bats tests/setup-hooks.bats \
  --test "setup-hooks: a replacement that fails is fatal, not a success report" \
  --why "replaces the file's set -e with a no-op, which is the only thing that makes any step below it fatal. rm is refused on a path that is not a removable file and the ln -s that follows then fails with 'File exists'; with errexit gone the script prints 'Created symlink: ...' for a path it never replaced and then 'Done! Hooks installed: pre-commit, post-merge.' - exit 0, no hook installed, and the output says the opposite" \
  --apply 'perl -pi -e "s/^set -e\$/true/" "$F"'
