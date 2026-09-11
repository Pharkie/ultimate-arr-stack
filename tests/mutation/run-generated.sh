#!/bin/bash
set -uo pipefail
#
# Generative mutation testing: the discovery half.
#
# run-mutations.sh replays a corpus of defects someone already knew about. It
# cannot find a gap nobody has thought of -- every entry in it is a bug that was
# written down after the fact. This script is the other half: universalmutator
# perturbs the source systematically, and any mutant the suite fails to kill is
# a hole in the tests that no one had to think of first.
#
# That is not hypothetical here. `grep -Fxq` -> `grep -Fq` in the backup volume
# resolver survived all 18 tests around it; the exact-match property was
# completely uncovered, and because volume names nest, a substring match
# silently mis-resolves and a volume fails to back up. Review did not find it.
#
# NON-BLOCKING BY DESIGN. This always exits 0. Generated mutants include
# equivalent ones -- mutations that change the text without changing behaviour --
# which can never be killed by any test and are not defects. A discovery tool
# that can wedge the workflow on an irreducible false-positive rate gets
# disabled, and then it finds nothing at all. run-mutations.sh stays the only
# blocking gate.
#
# Usage:
#   ./tests/mutation/run-generated.sh [-k <substring>] [target ...]
#
# With no target argument, every file in the TARGETS map below is swept.
# -k restricts to targets whose path contains <substring>.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/mutation/lib-mutate.sh
source "$ROOT/tests/mutation/lib-mutate.sh"
mutate_require_bound run-generated

# Overridable so a test can exercise the ledger-merge rules without writing to
# the repo's real one. It used to be hardcoded, and tests/mutation-framework.bats
# had to overwrite the tracked file in place and copy it back afterwards. That
# restore is a bare `cp` with nothing guarding it, so an interrupt anywhere in
# the sweep -- a timeout, a Ctrl-C -- left the committed ledger holding the
# test's sentinel rows. Observed, not theorised: a 2-minute timeout during this
# work did exactly that, and the wreckage looked enough like real triage output
# to be committed by accident.
LEDGER="${MUTATION_LEDGER:-$ROOT/tests/mutation/survivors.tsv}"
MUTANT_DIR="$ROOT/tests/mutation/.mutants"

# target file : bats oracle : test-name regex
#
# One table, same shape as the corpus's --file/--bats/--test triple. A target
# with no oracle does not belong here: against an untested file EVERY mutant
# survives by construction, which is not a finding, it is a restatement of
# "this file has no tests" -- and a few hundred guaranteed survivors would bury
# the real signal. The scripts/lib/ files that still have no oracle are recorded
# as a missing-test gap in tests/mutation/README.md instead of being swept.
#
# No count is written down here on purpose. This table IS the list of covered
# files, so a number beside it can only ever disagree with it; the staleness
# test in tests/shellcheck.bats derives the uncovered set from field 1 at run
# time rather than from anything anyone remembered to edit.
TARGETS=(
# The third field is a bats `-f` regex, so it is anchored: an unanchored
# substring would silently widen the oracle as tests are added, and a mutant
# that then survived would have survived for a reason unrelated to coverage.
  "scripts/lib/check-secrets.sh:tests/lib-secrets.bats:^secrets: "
  "scripts/lib/check-env-vars.sh:tests/pre-commit-checks.bats:^check_env_vars "
  "scripts/lib/check-conflicts.sh:tests/pre-commit-checks.bats:^check_conflicts "
  "scripts/lib/check-hardcoded-domain.sh:tests/lib-hardcoded-domain.bats:^hardcoded-domain: "
  "scripts/lib/check-uptime-monitors.sh:tests/lib-uptime-monitors.bats:^uptime-monitors: "
  "scripts/lib/check-image-versions.sh:tests/lib-image-versions.bats:^image-versions: "
  "scripts/lib/configure-helpers.sh:tests/lib-configure-helpers.bats:^configure-helpers: "
  "scripts/lib/check-doc-links.sh:tests/lib-doc-links.bats:^doc-links: "
  "scripts/lib/check-yaml-syntax.sh:tests/lib-yaml-syntax.bats:^yaml-syntax: "
  "scripts/lib/check-env-backup.sh:tests/lib-env-backup.bats:^env-backup: "
  "scripts/lib/check-dns-duplicates.sh:tests/lib-dns-duplicates.bats:^dns-duplicates: "
  # scripts/lib/common.sh IS here now, and the reason it was not is worth
  # keeping: it was swept once on the theory that being sourced by three tested
  # files made it covered, and produced 78 mutants of which 78 survived. Sourced
  # is not covered. It stayed off this list until it had an oracle of its own,
  # because a target with no tests contributes only guaranteed survivors, which
  # say nothing beyond "this file has no tests" - something README.md's derived
  # no-sweep list already says, for free.
  "scripts/lib/common.sh:tests/lib-common.bats:^common: "
  "scripts/lib/check-domains.sh:tests/lib-domains.bats:^domains: "
  "scripts/restart-stack.sh:tests/restart-stack.bats:^restart-stack: "
  "setup-hooks.sh:tests/setup-hooks.bats:^setup-hooks: "
  "scripts/ensure-tailscale-relay-port.sh:tests/ensure-relay-port.bats:^ensure-relay-port: "
  "scripts/check-vpn.sh:tests/check-vpn.bats:^check-vpn: "
  "scripts/boot-compose-up.sh:tests/boot-compose-up.bats:^boot-compose-up: "
  "scripts/check-network.sh:tests/check-network.bats:^check-network: "
  "scripts/configure-apps.sh:tests/configure-apps.bats:^configure-apps: "
  "scripts/lib/env-file.sh:tests/lib-env-file.bats:^env-file: "
  "scripts/queue-cleanup.sh:tests/queue-cleanup.bats:^queue-cleanup: "
  # Both fixers share tests/fix-arr-paths.bats and both anchor on `^fix-`
  # rather than on their own half of it, so the one cross-script test in that
  # file (neither reaches a destructive operation) is part of both oracles
  # instead of belonging to neither.
  "scripts/fix-radarr-paths.sh:tests/fix-arr-paths.bats:^fix-"
  "scripts/fix-sonarr-folders.sh:tests/fix-arr-paths.bats:^fix-"
  # The Python halves of the three fixers. universalmutator's own python.rules
  # applies here, picked by extension in mutator.sh; the oracle is pytest,
  # reached through the one bats test that runs it.
  #
  # The regex names a single test rather than the file's `^python: ` prefix,
  # which is the one place this table deliberately narrows instead of widening.
  # The other three tests in that file assert properties of pytest.sh itself --
  # that it exits 77 without docker, that every module has a test file -- and no
  # mutation of a module can make any of them fail. Including them would only
  # add wall-clock to every one of a few hundred mutants.
  "scripts/lib/queue_cleanup.py:tests/python-suite.bats:^python: the extracted modules pass"
  "scripts/lib/fix_radarr_paths.py:tests/python-suite.bats:^python: the extracted modules pass"
  "scripts/lib/fix_sonarr_folders.py:tests/python-suite.bats:^python: the extracted modules pass"
  # The four duc files share one oracle because they are one protocol: the cgi
  # produces a request marker, the poller consumes it, scan.sh holds the lock
  # both of them branch on. A mutant in any of them is scored against all of it.
  "duc-service/app/scan.sh:tests/duc-service.bats:^duc: "
  "duc-service/app/manual_scan.sh:tests/duc-service.bats:^duc: "
  "duc-service/app/manual_scan.cgi:tests/duc-service.bats:^duc: "
  "duc-service/app/startup.sh:tests/duc-service.bats:^duc: "
)

FILTER=""
while getopts "k:" opt; do
    case "$opt" in
        k) FILTER="$OPTARG" ;;
        *) echo "usage: $0 [-k <substring>] [target ...]" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -gt 0 ]]; then
    SELECTED=("$@")
else
    SELECTED=()
    for t in "${TARGETS[@]}"; do SELECTED+=("${t%%:*}"); done
fi

# Apply -k HERE, not only in the sweep loop below. The dirty-tree guard that
# follows reads SELECTED, so a SELECTED holding every target made the guard
# refuse on files the run was never going to touch -- and `-k` exists precisely
# to narrow a run down to one target while the rest of the tree is mid-edit.
#
# That cost three corpus entries at once, and two of them failed in the shape
# worth remembering: the guard refused identically with and without the defect,
# so the oracle could not distinguish them and they were scored SURVIVED -- a
# coverage gap reported against tests that were in fact never reached. An
# over-broad precondition does not merely block a run, it can launder itself
# into a false measurement downstream.
if [[ -n "$FILTER" ]]; then
    _kept=()
    for t in "${SELECTED[@]}"; do [[ "$t" == *"$FILTER"* ]] && _kept+=("$t"); done
    SELECTED=(${_kept+"${_kept[@]}"})
fi

# This overwrites tracked files in place. On a dirty tree a failed restore is
# indistinguishable from the user's own uncommitted work, and `git checkout --`
# -- the documented recovery -- would destroy that work. Refuse.
cd "$ROOT" || exit 2
# An empty SELECTED must not reach `git status --porcelain --`: with no pathspec
# git reports the ENTIRE tree, so a filter matching no target would trip a guard
# about files the run had already decided to ignore. Empty means nothing to
# sweep, which means nothing to protect.
DIRTY=""
[[ ${#SELECTED[@]} -gt 0 ]] && DIRTY="$(git status --porcelain -- "${SELECTED[@]}" 2>/dev/null)"
if [[ -n "$DIRTY" ]]; then
    echo "run-generated: refusing to start - these targets have uncommitted changes:" >&2
    sed 's/^/  /' <<<"$DIRTY" >&2
    echo "run-generated: this script overwrites them in place. Commit or stash first." >&2
    exit 2
fi

oracle_for() {
    local want="$1" t
    for t in "${TARGETS[@]}"; do
        [[ "${t%%:*}" == "$want" ]] || continue
        local rest="${t#*:}"
        printf '%s\t%s\n' "${rest%%:*}" "${rest#*:}"
        return 0
    done
    return 1
}

# Describe a mutant as `<line>\t<old> ==> <new>`.
#
# The line number is deliberately NOT part of the ledger's identity for a
# survivor -- only the file and the mutation text are. Line numbers shift the
# moment anything is inserted above the mutation, and an identity that includes
# one would silently orphan every hand-assigned verdict on the next edit to the
# source file: the triaged row would reappear as `unreviewed` and the human work
# would be lost with nothing reporting it. The line is carried as its own
# column, where it is useful to a reader and harmless if stale.
#
# ` ==> ` is universalmutator's own rule syntax, reused here so a ledger row
# reads the same way the rule that produced it does.
describe() {
    local orig="$1" mut="$2" out line text
    out="$(diff --unchanged-line-format= --old-line-format='%dn|%L ==> ' \
        --new-line-format='%L' "$orig" "$mut" 2>/dev/null \
        | head -2 | tr -d '\n' \
        | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')"
    line="${out%%|*}"
    text="${out#*|}"
    [[ "$line" =~ ^[0-9]+$ ]] || { line="?"; text="$out"; }
    printf '%s\t%s\n' "$line" "$text"
}

TOTAL=0; KILLED=0; SURVIVED=0; ERRORED=0; SKIPPED=0; TIMEDOUT=0
declare -a NEW_SURVIVORS=()
# Targets this run actually swept to completion. The ledger is rewritten only
# for these; rows belonging to any other target are carried through untouched.
declare -A SWEPT=()

for target in "${SELECTED[@]}"; do
    if [[ -n "$FILTER" && "$target" != *"$FILTER"* ]]; then continue; fi

    map="$(oracle_for "$target")" || {
        echo "ERROR  $target has no oracle in the TARGETS map - skipping" >&2
        ERRORED=$((ERRORED + 1)); continue
    }
    batsfile="${map%%$'\t'*}"; testre="${map#*$'\t'}"

    if [[ ! -f "$ROOT/$target" ]]; then
        echo "ERROR  no such target: $target" >&2
        ERRORED=$((ERRORED + 1)); continue
    fi

    echo "== $target  (oracle: $(basename "$batsfile") -f '$testre')"

    # Control, once per target rather than once per mutant. A suite that is
    # already red would score every mutant KILLED and report a perfect sweep.
    control_start=$SECONDS
    res=$(run_tests "$ROOT/$batsfile" "$testre"); read -r st count skipped <<<"$res"
    budget=$(oracle_budget $(( SECONDS - control_start )))
    if [[ "$count" -eq 0 ]]; then
        echo "   ERROR: -f '$testre' matched NO tests. bats exits 0 having run"
        echo "          nothing, which reads exactly like a pass. Fix the regex."
        ERRORED=$((ERRORED + 1)); continue
    fi
    if [[ "$st" -ne 0 ]]; then
        echo "   ERROR: the oracle is already failing unmutated - every mutant"
        echo "          would score KILLED. Fix the tests first."
        ERRORED=$((ERRORED + 1)); continue
    fi

    # The whole oracle skipping is not a pass. TAP spells a skip as
    # `ok N name # skip reason`, so an oracle that skipped entirely exits 0 and
    # every mutant it never examined would be scored SURVIVED -- a coverage gap
    # invented out of an environment condition and filed against a test that
    # never executed. run-mutations.sh has refused to judge this case since §8 of
    # docs/TEST-HARDENING-LOG.md recorded it; this half shares run_tests, which
    # returns the skip count for exactly this reason, and was not reading it.
    #
    # Refusing here, before generation, also means a host that cannot judge a
    # target never pays to generate its mutants.
    if [[ "$skipped" -eq "$count" ]] && [[ "$count" -gt 0 ]]; then
        echo "   SKIP: all $count oracle test(s) skipped, so it cannot judge any mutant:"
        grep -m1 -E '^ok [0-9]+ .*# skip' "$WORK/last-output.txt" | sed 's/^/        | /'
        SKIPPED=$((SKIPPED + 1)); continue
    fi

    outdir="$MUTANT_DIR/$(printf '%s' "$target" | tr -c 'A-Za-z0-9._-' '_')"
    rm -rf "$outdir"
    gen="$("$ROOT/tests/mutation/mutator.sh" "$ROOT/$target" "$outdir")"
    genst=$?
    if [[ "$genst" -eq 77 ]]; then
        echo "   SKIP: no usable docker daemon to generate mutants in"
        SKIPPED=$((SKIPPED + 1)); continue
    fi
    if [[ "$genst" -ne 0 ]]; then
        echo "   ERROR: mutant generation failed"
        ERRORED=$((ERRORED + 1)); continue
    fi
    echo "   $gen, $count oracle test(s)"
    SWEPT["$target"]=1

    for mutant in "$outdir"/*; do
        [[ -f "$mutant" ]] || continue
        TOTAL=$((TOTAL + 1))

        take_backup "$ROOT/$target" "gen-$(basename "$target")-$(basename "$mutant")" || {
            echo "   ERROR: could not copy $target aside"
            ERRORED=$((ERRORED + 1)); continue
        }
        backup="$BACKUP_PATH"
        desc="$(describe "$backup" "$mutant")"

        cp "$mutant" "$ROOT/$target" 2>/dev/null || true
        # The mutation must actually have landed. A no-op mutant scores KILLED
        # or SURVIVED on the unmutated file either way, and both answers are
        # lies -- this is the same assertion the corpus runner makes, and the
        # reason it exists at all.
        if cmp -s "$backup" "$ROOT/$target"; then
            echo "   ERROR: mutant $(basename "$mutant") changed nothing"
            ERRORED=$((ERRORED + 1)); restore_current || exit 3; continue
        fi

        res=$(run_tests "$ROOT/$batsfile" "$testre" "$budget"); read -r st mcount mskipped <<<"$res"

        # Restore before classifying. Stop the whole run if it failed: mutating
        # the next target on top of a tree we could not put back turns one
        # recoverable problem into an unrecoverable one.
        restore_current || exit 3

        if [[ "$st" -eq 124 ]]; then
            # Counted as a kill -- the oracle demonstrably did not pass -- but
            # named, because a hang and a clean red are the same status here and
            # very different problems. The tally reports them separately so a
            # sweep whose wall-clock quietly went up says why.
            KILLED=$((KILLED + 1)); TIMEDOUT=$((TIMEDOUT + 1))
            echo "   KILLED (oracle hit the ${budget}s budget)  $desc"
        elif [[ "$st" -ne 0 ]]; then
            KILLED=$((KILLED + 1))
        elif [[ "$mskipped" -eq "$mcount" ]] && [[ "$mcount" -gt 0 ]]; then
            # Same reasoning as the control run, per mutant: an oracle whose every
            # test skipped did not judge this mutant, so it is not a finding.
            SKIPPED=$((SKIPPED + 1))
            echo "   SKIPPED (the whole oracle skipped on this mutant)  $desc"
        else
            SURVIVED=$((SURVIVED + 1))
            NEW_SURVIVORS+=("$target"$'\t'"$desc")
            echo "   SURVIVED  $desc"
        fi
    done
done

# --- ledger ------------------------------------------------------------------
#
# Merge, never overwrite -- and merge along BOTH axes.
#
# The first version rebuilt this file from the current run's survivors alone.
# Any run that did not sweep everything -- a `-k` filter, a positional target, a
# target that SKIPped because docker was unavailable, a target that ERRORed --
# silently deleted every row it had not just regenerated, and a run with no
# survivors at all left a header and nothing else. That is how the five
# hand-assigned verdicts in the first ledger were lost, and the "two sweeps
# produce an identical ledger" check could not see it because both sweeps were
# full ones.
#
# So: a row survives unless its target was actually swept this run, and a row
# for a swept target keeps its verdict if the same mutation is still found.
# Identity is (file, mutation text) -- never the line number, see describe().
{
    echo "# Survivors of ./tests/mutation/run-generated.sh -- mutants the suite did NOT kill."
    echo "# verdict: real-gap | equivalent | wontfix | unreviewed"
    echo "# A real-gap gets a test written, and then a corpus entry so the new test is"
    echo "# itself proved capable of failing. An equivalent mutant changes text without"
    echo "# changing behaviour and can never be killed by anything - it is not a defect."
    echo "#"
    echo "# Rows are keyed on (file, mutation); the line number is informational and may"
    echo "# be stale. Only targets swept by the last run are rewritten."
    printf '#file\tline\tmutation\tverdict\tnote\n'
} > "$WORK/ledger.tsv"

declare -A KNOWN=()
declare -a CARRIED=()
if [[ -f "$LEDGER" ]]; then
    while IFS=$'\t' read -r f l m v n; do
        [[ "$f" == \#* || -z "$f" ]] && continue
        if [[ -n "${SWEPT[$f]+set}" ]]; then
            KNOWN["$f"$'\t'"$m"]="$v"$'\t'"$n"
        else
            # Not swept this run: carried through exactly as it was.
            CARRIED+=("$f"$'\t'"$l"$'\t'"$m"$'\t'"$v"$'\t'"$n")
        fi
    done < "$LEDGER"
fi

{
    for c in ${CARRIED+"${CARRIED[@]}"}; do printf '%s\n' "$c"; done
    for s in ${NEW_SURVIVORS+"${NEW_SURVIVORS[@]}"}; do
        # s is already file<TAB>line<TAB>mutation
        f="${s%%$'\t'*}"; rest="${s#*$'\t'}"; m="${rest#*$'\t'}"
        if [[ -n "${KNOWN[$f$'\t'$m]+set}" ]]; then
            printf '%s\t%s\n' "$s" "${KNOWN[$f$'\t'$m]}"
        else
            printf '%s\tunreviewed\t\n' "$s"
        fi
    done
} | sort >> "$WORK/ledger.tsv"

cp "$WORK/ledger.tsv" "$LEDGER"

echo
echo "killed $KILLED / $TOTAL   survived $SURVIVED   errored $ERRORED   skipped $SKIPPED"
if [[ "$TIMEDOUT" -gt 0 ]]; then
    # Not folded into the line above. These are counted as kills, but they are
    # the reason a sweep's wall-clock moves, and a number nobody prints is a
    # number nobody notices.
    echo "  of those, $TIMEDOUT hit the oracle time budget rather than failing outright"
fi
if [[ "$SURVIVED" -gt 0 ]]; then
    echo "ledger: $LEDGER  (survivors are findings to triage, not failures)"
fi
# Always 0 -- see the header. run-mutations.sh is the blocking gate.
exit 0
