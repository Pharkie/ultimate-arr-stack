# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for the command that bounds an oracle run.
#
# The bound is load-bearing twice over. It stops one pathological mutant from
# turning a sweep into an unbounded one (2026-09-01: a sweep ran past a 90-minute
# cap having scored 3 of 31 mutants), and its number is how the runners tell "hit
# the budget" from "went red". Both halves have already been paid for once more,
# in the other direction: a host where the bound command did not exist scored
# EVERY mutant KILLED, because the 127 was read as a failing test (macOS,
# 2026-09-11 - see the resolution block in lib-mutate.sh).
#
# The fallback is not a one-line `alarm` + `exec` for the same reason the GNU
# tool is not a one-line `sleep` + `kill`: what has to die is the process group.

mutation oracle-bound-fallback-loses-the-process-group \
  --file tests/mutation/lib-mutate.sh \
  --bats tests/mutation-framework.bats \
  --test "run_tests still bounds the oracle where GNU timeout is absent" \
  --why "without setpgrp the fallback kills the direct child only. tests/run-tests.sh forks bats, bats runs each test in a further subshell, and that grandchild inherits the command substitution's stdout pipe - so run_tests stays blocked on a pipe that never closes and the budget buys nothing. Measured on macOS with a 1s budget and an oracle that sleeps 30: the alarm fires at 1s and the call still returns after 30" \
  --apply 'python3 -c "import sys;p=sys.argv[1];s=open(p).read();assert \"setpgrp(0, 0); \" in s;s=s.replace(\"setpgrp(0, 0); \",\"\",1);open(p,\"w\").write(s)" "$F"'
