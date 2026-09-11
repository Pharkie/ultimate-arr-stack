#!/bin/bash
#
# Shared core for the two mutation runners:
#
#   run-mutations.sh   corpus     - regression, blocking, known defects
#   run-generated.sh   generated  - discovery, non-blocking, unknown gaps
#
# Everything in here is the dangerous half: it overwrites tracked files in
# place and must put them back. That is why it lives in one file. A second
# copy of restore logic is precisely the hazard this directory exists to
# prevent -- the two runners would drift, and the one that drifted would leave
# a mutated file in the tree looking exactly like an ordinary edit.
#
# Sourced, not executed. The sourcing script owns its own counters and its own
# summary; this file owns ROOT, WORK, the restore discipline, and the oracle.

# Sourcing this twice in one process would install a second EXIT trap over the
# first and point WORK at a new directory, orphaning the first one's pristine
# copies -- the backups a FATAL message would tell the reader to restore from.
# `trap` replaces, it does not accumulate. Second source is a no-op.
if [[ -n "${LIB_MUTATE_SOURCED:-}" ]]; then
    return 0 2>/dev/null || true
fi
LIB_MUTATE_SOURCED=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
# Without this the failure is silent and misdirected: WORK is empty, every
# backup path becomes "/<tag>.orig" at the filesystem root, and the caller
# reports "could not copy the target aside" for what is actually a full /tmp.
if [[ -z "$WORK" || ! -d "$WORK" ]]; then
    echo "FATAL: mktemp -d failed - no scratch directory to hold backups in." >&2
    echo "FATAL: refusing to mutate anything without somewhere to restore from." >&2
    exit 3
fi
CURRENT_FILE=""; CURRENT_BACKUP=""
RESTORE_FAILED=0

# Restoring is the one thing that must happen no matter how this exits. A
# mutated file left in the tree is worse than no mutation testing at all: it
# looks like an ordinary edit and there is nothing to distinguish it from one.
restore_current() {
    # Nothing to restore is a legitimate no-op. A backup that has gone missing
    # is NOT -- it means the mutated file is in the tree with nothing left to
    # put back, and the old single-condition guard returned 0 for both, silently.
    [[ -n "$CURRENT_FILE" ]] || return 0
    if [[ ! -f "$CURRENT_BACKUP" ]]; then
        RESTORE_FAILED=1
        echo "FATAL: the backup of $CURRENT_FILE has vanished from under us." >&2
        echo "FATAL:   expected it at $CURRENT_BACKUP" >&2
        echo "FATAL: THE TREE IS MUTATED and there is nothing left to restore" >&2
        echo "FATAL: it from. Recover $CURRENT_FILE from git." >&2
        return 1
    fi
    # `cmp` alone, deliberately. Checking cp's exit status as well reads like
    # belt and braces, but a mutation proved it unfalsifiable: every case where
    # a failed cp matters is a case where the bytes differ, so cmp fires first
    # and the cp branch can never be the thing that catches anything. This
    # repo's own rule -- verify the outcome, not the exit status of the command
    # that was supposed to produce it -- picks the survivor.
    cp "$CURRENT_BACKUP" "$CURRENT_FILE" 2>/dev/null || true
    if ! cmp -s "$CURRENT_BACKUP" "$CURRENT_FILE"; then
        RESTORE_FAILED=1
        echo "FATAL: could not restore $CURRENT_FILE" >&2
        echo "FATAL: THE TREE IS MUTATED RIGHT NOW. The pristine copy is at" >&2
        echo "FATAL:   $CURRENT_BACKUP" >&2
        echo "FATAL: put it back by hand before doing anything else." >&2
        return 1
    fi
    RESTORE_FAILED=0
    CURRENT_FILE=""; CURRENT_BACKUP=""
}

# A failed restore must be fatal in BOTH directions, and the first version of
# this was neither. It printed FATAL and carried on: the run could still finish
# with 24 KILLED and exit 0 while a mutated file sat in the tree, indexed by
# nothing, looking exactly like an ordinary edit. And `rm -rf "$WORK"` ran
# immediately after -- deleting the pristine copy the message had just told the
# reader to restore from. A tool built to catch silent failure, failing silently.
cleanup() {
    restore_current || true
    if [[ "$RESTORE_FAILED" -eq 1 ]]; then
        echo "FATAL: keeping the backups in $WORK - do NOT delete it." >&2
        exit 3
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'echo; echo "interrupted - restoring" >&2; exit 130' INT TERM

# Run bats and report both the exit status and how many tests actually ran.
# The count is what makes a filter typo detectable instead of silently green.
# Echoes: "<status> <count> <skipped>"
# A per-run wall-clock budget for the oracle, in seconds, from the time the
# UNMUTATED oracle took. Ten times that, with a 60-second floor.
#
# Generous on purpose. A mutant that merely makes the code slower must not be
# misread as a hang, and the floor stops a sub-second oracle being handed a
# sub-second budget on a loaded machine.
# The floor is overridable only so that the runners' own timeout-scoring branch
# can be watched firing in under a minute. Nothing outside tests/ sets it, and a
# non-numeric value falls back rather than reaching an arithmetic context.
oracle_budget() {
    local control="${1:-0}" budget floor="${ORACLE_BUDGET_FLOOR:-60}"
    [[ "$control" =~ ^[0-9]+$ ]] || control=0
    [[ "$floor" =~ ^[0-9]+$ ]] || floor=60
    budget=$(( control * 10 ))
    if (( budget < floor )); then
        budget=$floor
    fi
    echo "$budget"
}

# $3, when given and non-zero, bounds the run at that many seconds.
#
# A mutation tool exists to inject pathological code, so "this mutant loops
# forever" is the expected case rather than an edge one -- and an oracle with no
# bound turns one bad mutant into an unbounded sweep. Observed 2026-09-01: a
# sweep of scripts/lib/configure-helpers.sh ran past a 90-minute cap having
# scored 3 of its 31 mutants, and only an external `timeout` ended it.
#
# `timeout` execs its argument, so this wraps the runner script itself; wrapping
# a shell function would do nothing (recorded trap, TEST-HARDENING-LOG section 8).
# A run that hits the budget comes back as status 124, which the caller scores as
# a kill -- the suite demonstrably did not pass -- but reports distinctly,
# because a hang and a clean red are the same number and very different problems.
#
# `timeout` bounds wall clock only. It does not bound memory, and a mutant that
# loops *allocating* -- not just spinning -- can exhaust the host before the
# clock runs out: `run-generated.sh` against scripts/lib/queue_cleanup.py did
# exactly that on 2026-09-02, rebooting this 1.8 GiB host twice. That mutant
# routed through the containerised pytest.sh, which now carries its own
# `ulimit -v`; this native path (every bash-side bats file) had no equivalent
# bound. `ulimit -v` sets RLIMIT_AS, a kernel rlimit -- no cgroup or privilege
# needed, so it applies here exactly as it does inside the container. Measured
# the same day: tests/lib-configure-helpers.bats (55 tests) is the heaviest
# native file checked and passes clean at 32 MB; 256 MB is 8x that floor and
# ~7x below host RAM, so it bounds a runaway mutant without ever touching a
# real run.
#
# `-S`, soft limit only: this process (run-mutations.sh/run-generated.sh)
# calls run_tests() itself, on every mutant, including ones that target this
# very function -- a bare `ulimit -v` sets the hard limit too, which a
# descendant can never raise again. That turned this repo's own mutation
# corpus entry for this guard into an unwinnable test: the harness's own
# unmutated control run had already capped the hard ceiling for the whole
# process tree before the mutated run ever got a chance to prove anything.
# The soft limit alone still stops a runaway allocator -- that is what
# RLIMIT_AS enforcement actually checks -- without leaving that trap behind.
NATIVE_MEM_KB="${MUTATE_NATIVE_ADDRESS_SPACE_KB:-262144}"
[[ "$NATIVE_MEM_KB" =~ ^[0-9]+$ ]] || NATIVE_MEM_KB=262144

# `docker` itself cannot run under this cap. Measured 2026-09-02: `docker
# version`/`docker info` fail at 256 MB, 512 MB and 1 GiB, and only succeed at
# 2 GiB+ -- a Go-runtime quirk (it reserves heap arena address space up front,
# independent of what it actually uses). 2 GiB exceeds this host's entire
# 1.8 GiB of physical RAM, so no single cap value can both bound a runaway
# native mutant and let docker run; the two goals are incompatible for any
# bats file that shells out to a *real* daemon (not a stubbed `docker` on
# PATH -- those still get capped, same as anything else). Every file below
# does that in at least one of its own test bodies (`docker run`, `docker
# image inspect`, `docker pull`, `docker info`), verified by reading each
# file rather than assumed:
#   - tests/python-suite.bats   bridges to pytest.sh, whose oracle already
#     runs under its OWN ulimit -v applied inside the container -- the thing
#     this cap exists to protect against is already covered there.
#   - tests/shellcheck.bats, tests/coverage-tool.bats, tests/mutation-framework.bats
#     invoke docker as a fixed tool call (the linter image, the kcov image,
#     an availability probe) with no mutable target of their own -- there is
#     nothing here for a bash mutant to make loop-and-allocate.
# A hardcoded list rather than a live grep: cheap, and a new docker-shelling
# bats file added later fails loudly (docker exits 2 under the cap) instead
# of silently, which is a safer default than silently exempting it.
NATIVE_MEM_EXEMPT=(
    "tests/python-suite.bats"
    "tests/shellcheck.bats"
    "tests/coverage-tool.bats"
    "tests/mutation-framework.bats"
)

# What bounds an oracle run, resolved once at source time.
#
# `timeout` is GNU coreutils and macOS does not ship it, which used to turn this
# whole harness into a liar there rather than merely an unavailable tool: the
# budget went straight to `timeout`, the command substitution came back 127
# ("command not found"), and both runners read any non-zero status as a failed
# test and scored the mutant KILLED. Measured 2026-09-11: all 19 entries of the
# check-image-versions corpus reported KILLED on macOS, and replaying them with a
# `timeout` shim on PATH turned one back into SURVIVED. A harness that invents
# kills is worse than one that finds nothing, because the ledger it writes is
# believed.
#
# `gtimeout` is coreutils under its macOS name; `perl` is the fallback
# scripts/sync-nas.sh's bounded() already uses for the same reason.
#
# The perl form is deliberately not `perl -e 'alarm shift; exec @ARGV'`. That
# bounds the direct child and nothing else, which is not what `timeout` does and
# not what run_tests needs: tests/run-tests.sh forks bats, bats runs each test in
# a further subshell, and that grandchild inherits the command substitution's
# stdout pipe -- so killing only the direct child leaves run_tests blocked on a
# pipe that stays open and the budget buys nothing. Measured on macOS: the alarm
# fired at 1s and the call still came back after 30. This forks, puts the child
# in its own process group, and kills the GROUP; it also exits 124 itself, so the
# runners' "hit the budget" branch works without translation.
MUTATE_BOUND="${MUTATE_BOUND_OVERRIDE:-}"
if [[ -z "$MUTATE_BOUND" ]]; then
    if command -v timeout >/dev/null 2>&1; then MUTATE_BOUND=timeout
    elif command -v gtimeout >/dev/null 2>&1; then MUTATE_BOUND=gtimeout
    elif command -v perl >/dev/null 2>&1; then MUTATE_BOUND=perl
    fi
fi

MUTATE_PERL_BOUND='
my $t = shift;
my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127; }
$SIG{ALRM} = sub { kill "-KILL", $pid; waitpid($pid, 0); exit 124; };
alarm $t;
waitpid($pid, 0);
exit($? >> 8);
'

# A host with none of the three cannot judge a mutant that hangs, and judging it
# wrongly is the failure mode this whole file is written against. Both runners
# call this before they score anything, so the verdict is never reached.
mutate_require_bound() {
    [[ -n "$MUTATE_BOUND" ]] && return 0
    echo "$1: no timeout, gtimeout or perl on PATH, so an oracle cannot be bounded." >&2
    echo "                Refusing to score mutants: one that hangs would be judged by luck." >&2
    exit 77
}

run_tests() {
    local batsfile="$1" regex="$2" budget="${3:-0}" out
    [[ "$budget" =~ ^[0-9]+$ ]] || budget=0

    local rel="${batsfile#"$ROOT"/}" exempt=0 f
    for f in "${NATIVE_MEM_EXEMPT[@]}"; do
        [[ "$rel" == "$f" ]] && { exempt=1; break; }
    done

    out="$(
        {
            (( exempt )) || ulimit -S -v "$NATIVE_MEM_KB"
            if (( budget > 0 )); then
                case "$MUTATE_BOUND" in
                    timeout|gtimeout) "$MUTATE_BOUND" "$budget" "$ROOT/tests/run-tests.sh" -f "$regex" "$batsfile" ;;
                    perl) perl -e "$MUTATE_PERL_BOUND" "$budget" "$ROOT/tests/run-tests.sh" -f "$regex" "$batsfile" ;;
                    *) echo "run_tests: no way to bound the oracle at ${budget}s" >&2; exit 77 ;;
                esac
            else
                "$ROOT/tests/run-tests.sh" -f "$regex" "$batsfile"
            fi
        } 2>&1
    )"
    local st=$?
    local plan count
    plan="$(grep -m1 -E '^1\.\.[0-9]+$' <<<"$out" || true)"
    count="${plan#1..}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    # TAP reports a skipped test as `ok N name # skip reason` -- a PASS as far as
    # the exit status is concerned. So an oracle whose tests all skip looks
    # exactly like an oracle that ran and passed, and a mutant it never examined
    # gets scored SURVIVED: a coverage gap reported against a test that was
    # never reached. Two corpus entries read that way during this work, both
    # because an environment guard skipped them on a dirty tree. Count skips so
    # the caller can tell "passed" from "did not run".
    local skipped
    skipped="$(grep -cE '^ok [0-9]+ .*# skip' <<<"$out" || true)"
    [[ "$skipped" =~ ^[0-9]+$ ]] || skipped=0
    printf '%s\n' "$out" > "$WORK/last-output.txt"
    echo "$st $count $skipped"
}

# Take the pristine copy and arm the restore path. Callers must pair this with
# `restore_current || exit 3` on every exit path -- the EXIT trap is the
# backstop for a crash, not a substitute for restoring between mutants.
#
# The result comes back in the BACKUP_PATH global rather than on stdout, and
# the guard below enforces that it is never called any other way. The first
# version returned the path by echoing it, so every caller wrote
# `backup="$(take_backup ...)"` -- a command substitution, which is a SUBSHELL.
# The assignments to CURRENT_FILE/CURRENT_BACKUP landed in that subshell and
# died with it, restore_current saw an empty CURRENT_FILE, took its legitimate
# "nothing to restore" path, and the run finished having left five mutated
# files in the working tree. The corpus caught it; nothing about reading the
# code did. A function whose entire purpose is a side effect on globals must
# refuse to run where those globals go nowhere.
BACKUP_PATH=""
take_backup() {
    local file="$1" tag="$2"
    if [[ "$BASHPID" != "$$" ]]; then
        echo "FATAL: take_backup called in a subshell (probably \`\$(take_backup ...)\`)." >&2
        echo "FATAL: it arms the restore path by setting globals, which a subshell" >&2
        echo "FATAL: discards -- the tree would be left mutated. Call it plainly" >&2
        echo "FATAL: and read the BACKUP_PATH variable." >&2
        return 2
    fi
    # printf, not echo: `echo` appends a newline and `tr -c` then turns it into
    # a trailing '_', so every backup was silently named "<id>_.orig".
    BACKUP_PATH="$WORK/$(printf '%s' "$tag" | tr -c 'A-Za-z0-9._-' '_').orig"
    cp "$file" "$BACKUP_PATH" || return 1
    CURRENT_FILE="$file"; CURRENT_BACKUP="$BACKUP_PATH"
}
