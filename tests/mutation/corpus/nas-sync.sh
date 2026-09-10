# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for the NAS sync path (scripts/post-merge, scripts/sync-nas.sh).
#
# Each entry reintroduces a defect that path has actually had, or a near
# neighbour of one. `tests/hooks-installed.bats` passed for the hook's whole
# life while it was inert; nothing here is trusted until it is watched failing.

mutation hook-cannot-resolve-repo-root \
  --file scripts/post-merge \
  --bats tests/nas-sync.bats \
  --test "post-merge actually runs the NAS sync" \
  --why "the original bug: the hook could not work out its own repo root, so it exited 0 having synced nothing" \
  --apply 'sed -i -e "s@^REPO_ROOT=\"\$(git rev-parse.*@REPO_ROOT=\"\"@" -e "s@^    resolved=.*@    resolved=\"\"@" "$F"'

mutation hook-skips-the-push \
  --file scripts/post-merge \
  --bats tests/nas-sync.bats \
  --test "post-merge pushes an unpushed main" \
  --why "without the push, the merge commit never reaches origin and the NAS -- which pulls from origin -- can never see it" \
  --apply 'sed -i "s@^    if ! git -C \"\$REPO_ROOT\" push origin.*@    if false; then@" "$F"'

mutation hook-pushes-a-dirty-tree \
  --file scripts/post-merge \
  --bats tests/nas-sync.bats \
  --test "refuses to push a dirty tree" \
  --why "publishes a commit the working copy disagrees with, from a hook, with no chance to look at it first" \
  --apply 'sed -i "s@^    if ! git -C \"\$REPO_ROOT\" diff --quiet.*@    if false; then@" "$F"'

mutation hook-pushes-when-diverged \
  --file scripts/post-merge \
  --bats tests/nas-sync.bats \
  --test "refuses to push when main has diverged" \
  --why "a hook that pushes into a diverged branch either fails noisily or invites a force -- neither belongs in an automatic step" \
  --apply 'sed -i "s@^    if \[\[ -n \"\$REMOTE\" \]\] && ! git -C.*@    if false; then@" "$F"'

mutation hook-runs-off-main \
  --file scripts/post-merge \
  --bats tests/nas-sync.bats \
  --test "silent and inert on a branch that is not main" \
  --why "would push and deploy every feature branch merge, which is how the NAS ends up quietly running something that was never merged" \
  --apply 'sed -i "s@^\[\[ \"\$BRANCH\" != \"main\" \]\] && exit 0@:@" "$F"'

mutation hook-swallows-sync-failure \
  --file scripts/post-merge \
  --bats tests/nas-sync.bats \
  --test "reports a failed sync" \
  --why "a failed sync that prints nothing is indistinguishable from a successful one -- the defect class this whole branch exists to remove" \
  --apply 'sed -i "s@^if ! \"\$REPO_ROOT/scripts/sync-nas.sh\"; then@if \"\$REPO_ROOT/scripts/sync-nas.sh\"; then@" "$F"'

mutation sync-exits-0-when-unreachable \
  --file scripts/sync-nas.sh \
  --bats tests/nas-sync.bats \
  --test "fails when the NAS is unreachable" \
  --why "the original behaviour: an unreachable NAS and a synced NAS produced the same exit status and the same silence" \
  --apply 'sed -i "/unreachable - NAS NOT synced/{n;s@exit 1@exit 0@;}" "$F"'

mutation sync-ignores-origin-mismatch \
  --file scripts/sync-nas.sh \
  --bats tests/nas-sync.bats \
  --test "refuses when the local commit is not on origin" \
  --why "the measured failure: local at 90e72c4, NAS at 93c8ed4, output \"Already up to date.\" and exit 0" \
  --apply 'sed -i "s@^if \[\[ \"\$REMOTE_SHA\" != \"\$LOCAL_SHA\" \]\]; then@if false; then@" "$F"'

mutation sync-ignores-missing-remote-branch \
  --file scripts/sync-nas.sh \
  --bats tests/nas-sync.bats \
  --test "refuses a branch origin has never seen" \
  --why "an unpushed feature branch would be reported as deployed" \
  --apply 'sed -i "s@^if \[\[ -z \"\$REMOTE_SHA\" \]\]; then@if false; then@" "$F"'

mutation sync-skips-verification-commit \
  --file scripts/sync-nas.sh \
  --bats tests/nas-sync.bats \
  --test "fails when the NAS ends up on the wrong commit" \
  --why "trusts the exit status of the commands that were supposed to produce the outcome, instead of asking the NAS what it holds" \
  --apply 'sed -i "s@^if \[\[ \"\$NAS_SHA\" != \"\$LOCAL_SHA\".*@if false; then@" "$F"'

mutation sync-skips-verification-branch \
  --file scripts/sync-nas.sh \
  --bats tests/nas-sync.bats \
  --test "fails when the NAS ends up on the wrong branch" \
  --why "same removal, checked from the branch side" \
  --apply 'sed -i "s@^if \[\[ \"\$NAS_SHA\" != \"\$LOCAL_SHA\".*@if false; then@" "$F"'

# Finer than the one above on purpose: verification that checks only the commit
# still passes a NAS sitting on a feature branch, which is the exact state that
# cost 38 hours of dead downloads and was invisible to every health check.
mutation sync-verifies-commit-but-not-branch \
  --file scripts/sync-nas.sh \
  --bats tests/nas-sync.bats \
  --test "fails when the NAS ends up on the wrong branch" \
  --why "half a verification reads as a whole one; the branch is the half that has actually bitten" \
  --apply 'sed -i "s@ || \"\$NAS_BRANCH\" != \"\$BRANCH\"@@" "$F"'

# --- the runner's own restore path ------------------------------------------
# These mutate lib-mutate.sh, which run-mutations.sh has already sourced. That is
# safe for a reason worth stating: `sed -i` writes a temp file and renames it,
# so the running bash keeps its original inode and finishes reading the script
# it started with -- and a sourced file is read once, at source time, so the
# already-loaded function bodies are equally unaffected. The mutation is visible
# only to the child runner the fixture spawns, which is exactly the thing under
# test. These four moved from run-mutations.sh to lib-mutate.sh when the restore
# core was extracted; they are the reason that refactor was caught leaving five
# mutated files in the tree.

mutation runner-restore-failure-not-fatal \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "failed restore is fatal" \
  --why "a run that could not put the tree back exits 0, so a mutated file is left behind looking like an ordinary edit" \
  --apply 'sed -i "s@^        exit 3\$@        : @" "$F"'

mutation runner-deletes-the-backup-it-names \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "failed restore is fatal" \
  --why "cleanup rm -rf's the pristine copy the FATAL message just told the reader to restore from" \
  --apply 'sed -i "s@^    if \[\[ \"\$RESTORE_FAILED\" -eq 1 \]\]; then\$@    if false; then@" "$F"'

mutation sync-nas-requires-gnu-timeout \
  --file scripts/sync-nas.sh \
  --bats tests/nas-sync.bats \
  --test "sync-nas does not require GNU timeout" \
  --why "puts the bare timeout back, which is what shipped: macOS has no such command, so every sync from the maintainer's Mac exited 127 printing nothing at all, and the post-merge hook could only report that the deploy had failed" \
  --apply 'sed -i "s@bounded 20 git ls-remote@timeout 20 git ls-remote@" "$F"'

mutation runner-vanished-backup-is-silent \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "vanished backup is fatal" \
  --why "a backup that disappeared is treated as nothing-to-restore, so the mutated file stays in the tree unreported" \
  --apply 'sed -i "s@^    if \[\[ ! -f \"\$CURRENT_BACKUP\" \]\]; then\$@    if false; then@" "$F"'

mutation runner-backup-name-gains-an-underscore \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "vanished backup is fatal" \
  --why "echo appends a newline that tr turns into a trailing underscore, so every backup is silently named <id>_.orig and nothing that looks it up by name finds it" \
  --apply 'sed -i "s@BACKUP_PATH=\"\$WORK/\$(printf .%s. \"\$tag\" | tr@BACKUP_PATH=\"\$WORK/\$(echo \"\$tag\" | tr@" "$F"'
