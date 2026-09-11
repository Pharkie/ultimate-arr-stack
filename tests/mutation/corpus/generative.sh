# shellcheck shell=bash
# Corpus: the generative half's own guards.
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
#
# run-generated.sh, mutator.sh and lib-mutate.sh are verification tools, so they
# get the treatment they impose. Every guard below was added because something
# went wrong without it; each entry proves the guard is capable of noticing.
#
# These mutate files that run-mutations.sh has already sourced or will only
# invoke as a child process. `sed -i` writes a temp file and renames it, so the
# running bash keeps its original inode, and a sourced file is read once at
# source time -- the already-loaded function bodies are unaffected. The mutation
# is visible only to the child the fixture spawns, which is the thing under test.

mutation gen-subshell-guard-removed \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "refuses to arm the restore path from a subshell" \
  --why "take_backup called in \$(...) sets CURRENT_FILE in a subshell that discards it, so restore_current no-ops and mutated files are left in the tree - this is the bug the lib-mutate.sh extraction actually shipped" \
  --apply 'sed -i "s@^    if \[\[ \"\$BASHPID\" != \"\$\$\" \]\]; then\$@    if false; then@" "$F"'

mutation gen-backup-does-not-arm-restore \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "arms the restore path when called plainly" \
  --why "take_backup copies the file aside but never sets CURRENT_FILE, so every restore is a silent no-op and the tool reports verdicts over a mutated tree" \
  --apply 'sed -i "s@^    CURRENT_FILE=\"\$file\"; CURRENT_BACKUP=\"\$BACKUP_PATH\"\$@    :@" "$F"'

mutation gen-dirty-tree-check-removed \
  --file tests/mutation/run-generated.sh \
  --bats tests/mutation-framework.bats \
  --test "refuses to start on a dirty target" \
  --why "the sweep overwrites tracked files in place; started on a dirty tree, a failed restore is indistinguishable from the user's own uncommitted work and the documented recovery destroys it" \
  --apply 'sed -i "s@^if \[\[ -n \"\$DIRTY\" \]\]; then\$@if false; then@" "$F"'

mutation gen-absent-docker-looks-like-success \
  --file tests/mutation/mutator.sh \
  --bats tests/mutation-framework.bats \
  --test "reports an absent docker distinctly" \
  --why "exiting 0 when docker is unavailable makes 'could not generate any mutants' identical to 'the sweep found nothing' - the same silent-success shape sync-nas.sh shipped for an unreachable NAS" \
  --apply 'sed -i "0,/^    exit 77\$/s@^    exit 77\$@    exit 0@" "$F"'

mutation gen-partial-sweep-wipes-the-ledger \
  --file tests/mutation/run-generated.sh \
  --bats tests/mutation-framework.bats \
  --test "does not delete ledger rows for targets it did not sweep" \
  --why "rebuilding the ledger from only the current run's survivors deletes every hand-assigned verdict for any target the run did not sweep - this shipped once and cost five triaged verdicts" \
  --apply 'sed -i "s@^        if \[\[ -n \"\${SWEPT\[\$f\]+set}\" \]\]; then\$@        if true; then@" "$F"'

mutation gen-ledger-keeps-stale-rows \
  --file tests/mutation/run-generated.sh \
  --bats tests/mutation-framework.bats \
  --test "does not delete ledger rows for targets it did not sweep" \
  --why "carrying every old row through unconditionally never drops a mutation that no longer exists, so the ledger accretes rows for code that is gone and a reader cannot tell which findings are live" \
  --apply 'sed -i "s@^        if \[\[ -n \"\${SWEPT\[\$f\]+set}\" \]\]; then\$@        if false; then@" "$F"'

mutation gen-mktemp-failure-unchecked \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "arms the restore path when called plainly" \
  --why "an unchecked mktemp -d leaves WORK empty, so every backup path becomes /<tag>.orig at the filesystem root and the real fault (a full /tmp) is reported as 'could not copy the target aside'" \
  --apply 'sed -i "s@^WORK=\"\$(mktemp -d)\"\$@WORK=\"\"@" "$F"'

# --- The runner's own verdict integrity ------------------------------------
#
# Both of these exist because the runner reported a wrong verdict during the
# 2026-09-01 coverage work, and in both cases the wrongness was silent: it
# looked exactly like a real finding.

mutation runner-scores-a-skipped-oracle-as-survived \
  --file tests/mutation/run-mutations.sh \
  --bats tests/mutation-framework.bats \
  --test "reports SKIPPED, not SURVIVED, when the whole oracle skipped" \
  --why "TAP spells a skip as 'ok N name # skip', so an oracle that skipped is indistinguishable from one that passed and the mutant is scored SURVIVED - a coverage gap invented out of an environment condition. Two entries in this very file read that way, because their oracle skips on a dirty scripts/lib and the run was measuring a fix to scripts/lib" \
  --apply 'sed -i "s@^    if \[\[ \"\$skipped\" -eq \"\$count\" \]\]; then\$@    if false; then@" "$F"'

mutation gen-dirty-guard-ignores-the-filter \
  --file tests/mutation/run-generated.sh \
  --bats tests/mutation-framework.bats \
  --test "the dirty-tree guard only considers targets the filter actually selected" \
  --why "the dirty-tree guard reads SELECTED, so building SELECTED before applying -k made it refuse over files the run would never touch - and -k exists precisely to sweep one target while the rest of the tree is mid-edit. An over-broad precondition does not just block a run, it launders itself into false SURVIVED readings downstream" \
  --apply 'perl -0pi -e "s/^if \[\[ -n \\\"\\\$FILTER\\\" \]\]; then\n    _kept=\(\)\n/if false; then\n    _kept=()\n/m" "$F"'

# --- The oracle's time budget ----------------------------------------------
#
# Added with the budget itself (2026-09-01). A bound that cannot be observed
# firing is decorative, and one that fires when it should not turns every slow
# oracle into a fake kill -- so both directions get an entry.

mutation gen-budget-floor-removed \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "oracle_budget scales with the control run and floors at a minute" \
  --why "without the floor a sub-second control run hands the mutant a sub-second budget, so on a loaded machine every mutant times out - which reads as a 100% kill rate while measuring nothing at all" \
  --apply 'sed -i "s@^    if (( budget < floor )); then\$@    if false; then@" "$F"'

mutation gen-budget-takes-an-unvalidated-control \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "oracle_budget refuses a control time it cannot trust" \
  --why "(( )) evaluates rather than coerces, so an unvalidated control time is an injection surface as well as a wrong-answer risk - bash expands command substitution inside an arithmetic subscript" \
  --apply 'sed -i "s@^    \[\[ .* \]\] || control=0\$@    :@" "$F"'

mutation gen-oracle-run-unbounded \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "run_tests bounds the oracle at the budget rather than waiting on it" \
  --why "this is the defect the budget was added for: with no bound, one mutant that makes the oracle loop stalls the entire sweep - measured, a sweep of configure-helpers.sh scored 3 of 31 mutants in 90 minutes and only an external timeout ended it" \
  --apply 'sed -i "s@^            if (( budget > 0 )); then\$@            if false; then@" "$F"'

mutation gen-oracle-bounded-when-it-should-not-be \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "run_tests leaves the oracle unbounded when no budget is given" \
  --why "a default budget applies the bound to callers that never asked for one, so a slow-but-passing oracle comes back 124 and is scored a kill - a fake measurement in the direction nobody checks" \
  --apply 'sed -i "s@^    local batsfile=\"\$1\" regex=\"\$2\" budget=\"\${3:-0}\" out\$@    local batsfile=\"\$1\" regex=\"\$2\" budget=\"\${3:-1}\" out@" "$F"'

mutation gen-timeout-tallied-as-an-ordinary-kill \
  --file tests/mutation/run-mutations.sh \
  --bats tests/mutation-framework.bats \
  --test "hangs the oracle is scored a kill and named as a timeout" \
  --why "a hang and a clean red are the same exit status once the bound fires, so folding them together hides the only thing that explains a sweep getting slower - and a budget nobody can see firing is a budget nobody trusts" \
  --apply 'sed -i "s@^    if \[\[ \"\$st\" -eq 124 \]\]; then\$@    if false; then@" "$F"'

mutation gen-skipped-oracle-scored-as-survivor \
  --file tests/mutation/run-generated.sh \
  --bats tests/mutation-framework.bats \
  --test "the generative runner reports SKIPPED, not SURVIVED, when the whole oracle skipped" \
  --why "drops the refusal, so an oracle that skipped wholesale reads as one that ran and passed: every mutant it never examined is scored SURVIVED and filed in the ledger as a coverage gap. That is the trap §8 of docs/TEST-HARDENING-LOG.md records - closed in run-mutations.sh, and left open in this half because it never read the skip count run_tests returns" \
  --apply 'sed -i "s@^    if \[\[ \"\$skipped\" -eq \"\$count\" \]\] && \[\[ \"\$count\" -gt 0 \]\]; then\$@    if false; then@" "$F"'

