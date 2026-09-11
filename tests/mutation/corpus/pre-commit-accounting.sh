# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for the pre-commit hook's error accounting.
#
# The hook kept an ERRORS counter and ended with a "BLOCKED: $ERRORS error(s)
# found" summary that could never print. Under `set -e`, `((ERRORS++))` in an
# else-branch returns status 1 on the FIRST failure (post-increment evaluates
# to the pre-increment value, 0, and `((0))` is exit 1), so the hook died at
# its first finding -- before reading the counter, before the summary, before
# checks 6-11, and inside check 5's library before that check's own error
# message was ever echoed.
#
# It still exited 1, which is why nothing noticed for so long: the verdict was
# right and everything explaining the verdict was missing.
#
# These entries exist because the fix is a shape that looks like a no-op. Anyone
# tidying `ERRORS=$((ERRORS + 1))` back into the terser `((ERRORS++))` is making
# what reads as a pure style edit, and would silently restore the bug. The whole
# hazard here is that the correct code and the broken code look interchangeable.
#
# Safe to run: the mutations touch only the hook and its libraries, and the
# tests drive them against a throwaway git repo in $BATS_TEST_TMPDIR.

mutation errors-accounting-aborts-hook \
  --file scripts/pre-commit \
  --bats tests/pre-commit-blocking.bats \
  --test "pre-commit: two independent errors are counted as two" \
  --why "restores the post-increment in the hook's else-branches; under set -e the first failing blocking check kills the hook, so the counter is never read and the summary that reports it is unreachable" \
  --apply 'sed -i "s@ERRORS=\$((ERRORS + 1))@((ERRORS++))@g" "$F"'

mutation warnings-counter-aborts-bare-caller \
  --file scripts/lib/check-hardcoded-domain.sh \
  --bats tests/lib-hardcoded-domain.bats \
  --test "hardcoded-domain: a domain warning does not kill a caller under set -e" \
  --why "restores the post-increment in the domain half; harmless to a caller that wraps the check in \`if\` and fatal to one that does not, which is a correctness property no reader of this file can see, because it lives entirely at the call site" \
  --apply 'sed -i "s@warnings=\$((warnings + 1))@((warnings++))@" "$F"'

mutation hardcoded-domain-count-absorbs-fallback \
  --file scripts/lib/check-hardcoded-domain.sh \
  --bats tests/lib-hardcoded-domain.bats \
  --test "hardcoded-domain: the leak report counts the hostname occurrences" \
  --why "the report line then carries grep's count AND the fallback's 0, so a leak in a tracked file is named as \`docs/NOTES.md (2\` newline \`0 occurrences)\`. The ERROR header, the file name and the return 1 are all unchanged, so the two existing tests over that half still pass and the corruption is only in the count" \
  --apply 'perl -pi -e '\''s@nas_hostname" 2>/dev/null \|\| echo 0\)@nas_hostname" 2>/dev/null && echo 0)@'\'' "$F"'

mutation hardcoded-domain-called-bare \
  --file scripts/pre-commit \
  --bats tests/pre-commit-blocking.bats \
  --test "pre-commit: checks after the first failure still run" \
  --why "reverts check 5 to a bare call; the function's return 1 is then discarded by the accounting AND fatal to the hook under set -e, which is how a check documented as blocking came to block only by accident" \
  --apply 'perl -0pi -e "s/if check_hardcoded_domain; then\n    :\nelse\n    ERRORS=\\\$\\(\\(ERRORS \+ 1\\)\\)\nfi/check_hardcoded_domain/" "$F"'
