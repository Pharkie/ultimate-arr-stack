#!/usr/bin/env bats
# The mutation runner is itself a verification tool, so it gets the same
# treatment it imposes: it is only trusted once it has been watched producing
# every verdict it can produce.
#
# This is not paranoia about a shell script. A harness in this project once
# reported five straight passes because its own `cmp` guard inverted its exit
# status -- the mutations were never applied and the tool said they all worked.
# A mutation runner that cannot report SURVIVED is worse than none: it converts
# every vacuous test in the suite into a certificate that the test is sound.

setup() {
    load helpers/setup
    command -v git >/dev/null 2>&1 \
        || skip "no host git binary on this machine (the NAS drives this repo through a containerised alpine/git)"
    RUNNER="$REPO_ROOT/tests/mutation/run-mutations.sh"
    FX="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$FX"

    # A subject with one guarded behaviour ...
    cat > "$FX/target.sh" <<'SUBJ'
#!/bin/bash
if [[ "$1" == "ok" ]]; then echo yes; else echo no; fi
SUBJ

    # ... and two tests: one that inspects the behaviour, one that only checks
    # the exit status and therefore cannot see the behaviour change at all.
    cat > "$FX/fixture.bats" <<'FXB'
setup() { TARGET="${BATS_TEST_FILENAME%/*}/target.sh"; }
@test "fixture asserts the guarded output" {
    run bash "$TARGET" ok
    [ "$output" = "yes" ]
}
@test "fixture asserts only the exit status" {
    run bash "$TARGET" ok
    [ "$status" -eq 0 ]
}
@test "fixture skips for an environment reason" {
    skip "no widget on this machine"
}
FXB
}

write_corpus() { cat > "$FX/corpus.sh"; }

# A repo that is not this one, laid out just enough for run-generated.sh to run
# inside it: the runner and its library, a stub test runner, and an empty file
# at every path TARGETS names.
#
# Every test of the dirty-tree guard needs a dirty tree, and dirtying a tracked
# file HERE means restoring it afterwards -- a restore that any interrupt skips.
# That is not hypothetical: the timeout added on 2026-09-01 killed one of these
# tests mid-run twice, and both times it left its dirt appended to the real
# scripts/lib/check-secrets.sh. A copy has no restore to skip, and the runner
# derives its own ROOT from where its library sits, so everything it writes --
# ledger included -- lands inside the throwaway.
make_throwaway_repo() {
    THROWAWAY="$FX/r"
    mkdir -p "$THROWAWAY/tests/mutation"
    cp "$REPO_ROOT/tests/mutation/run-generated.sh" \
       "$REPO_ROOT/tests/mutation/lib-mutate.sh" "$THROWAWAY/tests/mutation/"
    printf '#!/bin/bash\nexit 0\n' > "$THROWAWAY/tests/run-tests.sh"
    chmod +x "$THROWAWAY/tests/run-tests.sh" \
             "$THROWAWAY/tests/mutation/run-generated.sh"
    # Every TARGETS path must exist and be committed: `git status --porcelain --`
    # errors out on a pathspec matching nothing, which would empty DIRTY and let
    # a mutant pass for the wrong reason.
    local t
    for t in $(sed -n '/^TARGETS=(/,/^)/p' "$REPO_ROOT/tests/mutation/run-generated.sh" \
               | grep -oE '"[^":]+\.sh:' | tr -d '":'); do
        mkdir -p "$THROWAWAY/$(dirname "$t")"
        printf '#!/bin/bash\n:\n' > "$THROWAWAY/$t"
    done
    git -C "$THROWAWAY" init -q .
    git -C "$THROWAWAY" config user.email t@example.com
    git -C "$THROWAWAY" config user.name t
    git -C "$THROWAWAY" add -A && git -C "$THROWAWAY" commit -qm seed
}

@test "reports KILLED when the test detects the mutation" {
    write_corpus <<CORPUS
mutation demo-killed \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"KILLED demo-killed"* ]] || { echo "$output"; return 1; }
}

@test "the dirty-tree guard only considers targets the filter actually selected" {
    # -k exists to sweep ONE target while the rest of the tree is mid-edit, so a
    # guard that reads an unfiltered SELECTED refuses over files the run was
    # never going to touch. That is not merely an inconvenience: two entries in
    # tests/mutation/corpus/generative.sh were scored SURVIVED because of it,
    # their oracle having skipped on a dirty scripts/lib while the run was
    # measuring a fix to scripts/lib. An over-broad precondition launders itself
    # into a false measurement downstream.
    #
    # This runs against a THROWAWAY repo rather than this one, because the only
    # way to exercise a dirty-tree guard is to have a dirty tree, and dirtying a
    # tracked file here would need a restore -- which is exactly the bare-`cp`
    # interrupt window that already cost this repo a corrupted ledger. A copy
    # has no restore to skip.
    command -v git >/dev/null 2>&1 || skip "no host git binary"
    make_throwaway_repo

    # One target dirty; the filter selects none of them.
    echo '# edited' >> "$THROWAWAY/scripts/lib/check-secrets.sh"

    run bash "$THROWAWAY/tests/mutation/run-generated.sh" -k zzz-no-such-target
    # A filter matching nothing has nothing to protect, so the guard must stay
    # quiet about a file the run had already decided to ignore.
    [[ "$output" != *"refusing to start"* ]] || { echo "$output"; return 1; }
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "reports SKIPPED, not SURVIVED, when the whole oracle skipped" {
    # TAP spells a skipped test `ok N name # skip reason`, so to anything
    # reading the exit status it is a PASS. An oracle that skipped therefore
    # looks exactly like one that ran and did not notice the defect, and the
    # mutant gets scored SURVIVED -- a coverage gap invented out of an
    # environment condition, filed against a test that never executed.
    #
    # This is not hypothetical. Two entries in tests/mutation/corpus/generative.sh
    # read as SURVIVED during this work because their oracle skips while
    # scripts/lib is dirty, which it was, because the run was measuring a fix to
    # scripts/lib. The tool reported a coverage regression caused by nothing but
    # its own working tree.
    write_corpus <<CORPUS
mutation demo-skipped \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "skips for an environment reason" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SKIPPED demo-skipped"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"SURVIVED"* ]] || { echo "$output"; return 1; }
    # and it says WHY, so the reader is not left to guess which guard fired
    [[ "$output" == *"no widget on this machine"* ]] || { echo "$output"; return 1; }
}

@test "reports SURVIVED when the test cannot detect the mutation" {
    write_corpus <<CORPUS
mutation demo-survived \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts only the exit status" --why "the test never looks at the output" \
  --apply 'sed -i s@yes@nope@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [[ "$output" == *"SURVIVED demo-survived"* ]] || {
        echo "the runner could not report a vacuous test. Everything it has ever"
        echo "called KILLED would be worthless."
        echo "$output"; return 1
    }
    [ "$status" -ne 0 ] || { echo "a survivor must fail the run, got exit 0"; return 1; }
}

@test "errors instead of scoring a mutation that changed nothing" {
    write_corpus <<CORPUS
mutation demo-noop \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'true'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [[ "$output" == *"ERROR  demo-noop"* && "$output" == *"changed NOTHING"* ]] || {
        echo "a mutation that never applied was scored as a result. This is the"
        echo "exact failure the previous harness had, five times in a row."
        echo "$output"; return 1
    }
    [ "$status" -ne 0 ]
}

@test "errors instead of scoring a filter that matches no tests" {
    write_corpus <<CORPUS
mutation demo-badfilter \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "this test name does not exist anywhere" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [[ "$output" == *"ERROR  demo-badfilter"* && "$output" == *"matched NO tests"* ]] || {
        echo "bats exits 0 after running nothing; that must never read as a pass."
        echo "$output"; return 1
    }
    [ "$status" -ne 0 ]
}

@test "errors instead of scoring a test that was already failing" {
    cat > "$FX/target.sh" <<'BROKEN'
#!/bin/bash
echo definitely-not-yes
BROKEN
    write_corpus <<CORPUS
mutation demo-already-red \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@definitely@surely@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    [[ "$output" == *"ERROR  demo-already-red"* && "$output" == *"already failing"* ]] || {
        echo "a red test failing again proves nothing about the mutation."
        echo "$output"; return 1
    }
    [ "$status" -ne 0 ]
}

@test "restores the target byte-for-byte after every verdict" {
    local before; before=$(sha256sum < "$FX/target.sh")
    write_corpus <<CORPUS
mutation demo-a \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"'
mutation demo-b \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts only the exit status" --why "x" \
  --apply 'sed -i s@no@maybe@ "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    local after; after=$(sha256sum < "$FX/target.sh")
    [ "$before" = "$after" ] || {
        echo "the runner left the tree mutated. A mutated file looks exactly"
        echo "like an ordinary edit, which is the worst way to lose one."
        return 1
    }
}

@test "-k restricts the run to matching mutation ids" {
    write_corpus <<CORPUS
mutation demo-alpha \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"'
mutation demo-beta \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@no@maybe@ "\$F"'
CORPUS
    run "$RUNNER" -k alpha "$FX/corpus.sh"
    [[ "$output" == *"demo-alpha"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"demo-beta"* ]] || { echo "-k did not filter: $output"; return 1; }
    [[ "$output" == *"skipped 1"* ]] || { echo "skips are not accounted for: $output"; return 1; }
}

@test "the NAS-sync corpus is wired to files that still exist" {
    # A corpus entry pointing at a renamed file errors rather than silently
    # covering nothing, but nobody reads a report they assume is green. This
    # asserts the wiring directly so a rename fails the ordinary suite.
    local corpus="$REPO_ROOT/tests/mutation/corpus/nas-sync.sh"
    [ -f "$corpus" ] || { echo "corpus is missing"; return 1; }
    local f
    while read -r f; do
        [ -f "$REPO_ROOT/$f" ] || { echo "corpus targets a missing file: $f"; return 1; }
    done < <(grep -oE -- '--file [^ ]+' "$corpus" | awk '{print $2}' | sort -u)
    while read -r f; do
        [ -f "$REPO_ROOT/$f" ] || { echo "corpus targets a missing bats file: $f"; return 1; }
    done < <(grep -oE -- '--bats [^ ]+' "$corpus" | awk '{print $2}' | sort -u)
}

@test "a failed restore is fatal and keeps the pristine copy" {
    # The runner's own defect class, turned on itself. The first version printed
    # FATAL, carried on, and could still finish with every mutation KILLED and
    # exit 0 while a mutated file sat in the tree -- indistinguishable from an
    # ordinary edit. It then rm -rf'd the backup directory the FATAL message had
    # just told the reader to restore from.
    #
    # cp to an existing unwritable file fails for a non-root user, so chmod 444
    # after mutating is a faithful stand-in for a restore that cannot happen.
    if [ "$(id -u)" -eq 0 ]; then
        skip "root ignores the write bit, so a failed restore cannot be simulated"
    fi
    # Do not assume this platform's `cp` refuses an unwritable destination. If
    # it happily overwrites, the mutation restores cleanly, the runner exits 0,
    # and this test fails for a reason that has nothing to do with the runner.
    # Prove the premise here, and skip honestly if it does not hold -- a test
    # that cannot set up its own scenario must say so, not report a verdict.
    echo probe > "$FX/probe"; echo other > "$FX/probe.src"; chmod 444 "$FX/probe"
    if cp "$FX/probe.src" "$FX/probe" 2>/dev/null; then
        chmod 644 "$FX/probe"
        skip "this platform's cp overwrites an unwritable file; cannot simulate a failed restore"
    fi
    chmod 644 "$FX/probe"
    write_corpus <<CORPUS
mutation demo-unrestorable \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"; chmod 444 "\$F"'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"
    chmod 644 "$FX/target.sh"

    [ "$status" -ne 0 ] || {
        echo "the runner exited 0 having left a mutated file in the tree."
        echo "$output"; return 1
    }
    [[ "$output" == *"FATAL"* && "$output" == *"could not restore"* ]] || {
        echo "a failed restore said nothing identifiable."
        echo "$output"; return 1
    }

    # The message names a path to restore from by hand. It has to still be there.
    local backup_dir
    backup_dir=$(grep -oE '/tmp/[^ ]*\.orig' <<<"$output" | head -1)
    [ -n "$backup_dir" ] || { echo "no backup path was reported: $output"; return 1; }
    [ -f "$backup_dir" ] || {
        echo "the runner deleted the very backup it told the reader to use:"
        echo "  $backup_dir"
        return 1
    }
    grep -q 'echo yes' "$backup_dir" || { echo "the kept backup is not pristine"; return 1; }
}

@test "a vanished backup is fatal, not a silent no-op" {
    # restore_current's guard used to be one condition covering two very
    # different situations: nothing to restore (fine) and the backup is gone
    # (the tree is mutated and unrecoverable). Both returned 0, silently.
    #
    # --apply runs under `bash -c` with only $F exported, so it cannot read
    # $CURRENT_BACKUP. It does not need to: the backup is named after the
    # mutation id, so the fixture can find it.
    write_corpus <<CORPUS
mutation demo-lostbackup \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i s@yes@nope@ "\$F"; find "\${TMPDIR:-/tmp}" -maxdepth 2 -name demo-lostbackup.orig -delete'
CORPUS
    run "$RUNNER" "$FX/corpus.sh"

    [ "$status" -ne 0 ] || {
        echo "the runner exited 0 with a mutated file and no backup of it."
        echo "$output"; return 1
    }
    # Assert on a phrase that appears ONLY in the missing-backup branch. The
    # first version of this checked for "vanished", which also appears in the
    # backup's own filename (it is named after the mutation id) -- so the
    # assertion was satisfied by the fixture's own test data and passed with the
    # guard disabled. An assertion matching an incidental substring of its
    # inputs is exactly the vacuous-test shape this file exists to catch, and it
    # got in here.
    [[ "$output" == *"FATAL"* && "$output" == *"nothing left to restore"* ]] || {
        echo "a missing backup was treated as nothing-to-do."
        echo "$output"; return 1
    }
}

# --- the generative half ------------------------------------------------------

@test "take_backup refuses to arm the restore path from a subshell" {
    # This is not a hypothetical. Extracting the restore core into
    # lib-mutate.sh introduced exactly this bug: take_backup returned the
    # backup path by echoing it, so the caller wrote
    # `backup="$(take_backup ...)"` -- a command substitution, which is a
    # subshell. CURRENT_FILE/CURRENT_BACKUP were set inside it and died with
    # it, restore_current then took its legitimate "nothing to restore" path,
    # and the run finished having left five mutated files in the working tree.
    #
    # Reading the code did not catch it; run-mutations.sh did, on the next run.
    # The guard exists so the next person cannot reintroduce it silently.
    echo pristine > "$FX/subject"
    run bash -c "
        source '$REPO_ROOT/tests/mutation/lib-mutate.sh'
        out=\$(take_backup '$FX/subject' tag)
        echo \"status=\$?\"
        echo \"out=\$out\"
    "
    [[ "$output" == *"status=2"* ]] || {
        echo "take_backup returned success from a subshell, so the caller believes"
        echo "the restore path is armed when it is not:"; echo "$output"; return 1
    }
    [[ "$output" == *"subshell"* ]] || {
        echo "it failed without saying why:"; echo "$output"; return 1
    }
}

@test "take_backup arms the restore path when called plainly" {
    # The other half of the guard above. A refusal that fires unconditionally
    # would pass that test while making the tool useless -- this is the
    # assertion that keeps it honest.
    echo pristine > "$FX/subject"
    run bash -c "
        source '$REPO_ROOT/tests/mutation/lib-mutate.sh'
        take_backup '$FX/subject' tag || { echo REFUSED; exit 1; }
        echo \"backup=\$BACKUP_PATH\"
        echo \"current=\$CURRENT_FILE\"
        cmp -s '$FX/subject' \"\$BACKUP_PATH\" && echo BYTES_MATCH
    "
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"current=$FX/subject"* ]] || {
        echo "CURRENT_FILE was not set, so restore_current would no-op:"
        echo "$output"; return 1
    }
    [[ "$output" == *"BYTES_MATCH"* ]] || {
        echo "the backup is not a byte copy of the target:"; echo "$output"; return 1
    }
}

@test "the generative runner refuses to start on a dirty target" {
    # It overwrites tracked files in place. On a dirty tree a failed restore is
    # indistinguishable from the user's own uncommitted work, and the documented
    # recovery -- `git checkout --` -- would destroy that work.
    #
    # Against a throwaway repo, not this one. In the passing state the runner
    # refuses and touches nothing -- but the corpus entry that proves the guard
    # can fail (gen-dirty-tree-check-removed) deletes the refusal, and the
    # runner then sweeps for real: it appended three unreviewed rows to the
    # tracked survivors.tsv on 2026-09-01, and later, once the oracle had a time
    # budget, was killed mid-run and left its dirt in the real
    # scripts/lib/check-secrets.sh. A test has to be safe in the state its own
    # mutation puts it in, not just the state it normally passes in.
    command -v git >/dev/null 2>&1 || skip "no host git binary"
    make_throwaway_repo
    local target="scripts/lib/check-secrets.sh"
    printf '\n# dirt introduced by %s\n' "$BATS_TEST_NAME" >> "$THROWAWAY/$target"

    run bash "$THROWAWAY/tests/mutation/run-generated.sh" "$target"

    [ "$status" -ne 0 ] || {
        echo "the runner started against a dirty target. A failed restore would"
        echo "then be indistinguishable from the user's own edits:"
        echo "$output"; return 1
    }
    [[ "$output" == *"refusing to start"* && "$output" == *"$target"* ]] || {
        echo "it refused without naming the file that blocked it:"
        echo "$output"; return 1
    }
}

@test "the generative runner reports SKIPPED, not SURVIVED, when the whole oracle skipped" {
    # The corpus runner has refused to judge this since §8 of
    # docs/TEST-HARDENING-LOG.md recorded the trap. The generated half shares
    # run_tests -- which returns the skip count for exactly this reason -- and was
    # not reading it, so an oracle that skipped wholesale exited 0 and every
    # mutant it never examined was scored SURVIVED and written to the ledger: a
    # coverage gap invented out of an environment condition, filed against a test
    # that never executed.
    #
    # No docker is needed to prove this, and that is the point: the refusal
    # happens at the control run, before a single mutant is generated, so a host
    # that cannot judge a target never pays to generate them.
    make_throwaway_repo
    # TAP spells a skip as `ok N name # skip reason`, which the stub runner has
    # no other way to express.
    cat > "$THROWAWAY/tests/run-tests.sh" <<'STUB'
#!/bin/bash
printf '1..1\nok 1 fixture skips for an environment reason # skip no docker on this machine\n'
STUB
    chmod +x "$THROWAWAY/tests/run-tests.sh"
    local ledger="$FX/gen-skip-ledger.tsv"

    MUTATION_LEDGER="$ledger" run bash "$THROWAWAY/tests/mutation/run-generated.sh" -k check-secrets
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"SKIP"* ]] || { echo "no refusal in: $output"; return 1; }
    [[ "$output" != *"SURVIVED"* ]] || { echo "scored SURVIVED against a skipped oracle: $output"; return 1; }
    # It says why, and it files nothing: a skip is not a finding.
    [[ "$output" == *"no docker on this machine"* ]] || { echo "$output"; return 1; }
    if [[ -f "$ledger" ]]; then
        ! grep -q "check-secrets" "$ledger" \
            || { echo "wrote a ledger row for a target it could not judge:"; cat "$ledger"; return 1; }
    fi
}

@test "mutant generation reports an absent docker distinctly, not as success" {
    # 77, not 0. "docker is unavailable" and "the sweep found nothing" must
    # never be the same observable result -- that equivalence is the single
    # defect shape this whole directory exists to remove, and sync-nas.sh
    # already shipped it once (unreachable NAS exited 0, silently).
    # A stub docker that fails, which is the realistic shape of this: the
    # binary is installed and the daemon is not answering. PATH=/nonexistent
    # would remove bash along with docker and prove nothing.
    mkdir -p "$FX/bin"
    printf '#!/bin/sh\nexit 1\n' > "$FX/bin/docker"
    chmod +x "$FX/bin/docker"
    run env PATH="$FX/bin:$PATH" bash "$REPO_ROOT/tests/mutation/mutator.sh" \
        "$REPO_ROOT/scripts/lib/check-secrets.sh" "$FX/out"
    [ "$status" -eq 77 ] || {
        echo "expected 77 (docker unavailable), got $status:"; echo "$output"; return 1
    }
}

@test "the ledger path is overridable so a test never writes to the repo's own" {
    # The seam that makes the test below safe to interrupt. Without it that test
    # has to overwrite the tracked survivors.tsv and copy it back at the end,
    # and anything that kills the sweep in between -- a timeout, a Ctrl-C --
    # leaves the repo holding sentinel rows that look enough like real triage
    # output to be committed by accident. That is not hypothetical: it happened
    # during the session that added this test.
    #
    # A -k that matches no target sweeps nothing, so this needs no docker and
    # costs nothing, while still exercising the one line that decides where the
    # ledger is written.
    local probe="$FX/probe-ledger.tsv"
    local real="$REPO_ROOT/tests/mutation/survivors.tsv"
    cp "$real" "$FX/real.before"

    MUTATION_LEDGER="$probe" run "$REPO_ROOT/tests/mutation/run-generated.sh" -k zzz-no-such-target
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }

    [ -f "$probe" ] || {
        echo "MUTATION_LEDGER was ignored - the runner wrote somewhere else."
        return 1
    }
    diff -q "$FX/real.before" "$real" || {
        echo "the runner wrote the REPO's ledger despite MUTATION_LEDGER being set."
        echo "every test that exercises ledger merging now corrupts tracked state."
        return 1
    }
}

@test "a partial sweep does not delete ledger rows for targets it did not sweep" {
    # The regression this exists for: the ledger used to be rebuilt from the
    # current run's survivors alone. Any run that did not sweep everything -- a
    # -k filter, a positional target, a target that SKIPped for want of docker,
    # a target that ERRORed -- silently deleted every row it had not just
    # regenerated. Five hand-assigned verdicts were lost that way, and the
    # "two consecutive sweeps produce an identical ledger" check could not see
    # it, because both of those sweeps were full ones.
    #
    # Both directions are asserted. A rule that only preserved rows would be
    # satisfied by never rewriting anything, which would strand verdicts for
    # mutations that no longer exist.
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
        || skip "no usable docker daemon to generate mutants in"
    [ -z "$(cd "$REPO_ROOT" && git status --porcelain -- scripts/lib/)" ] \
        || skip "scripts/lib is dirty; the runner refuses to sweep it (by design)"

    # A throwaway ledger, NOT the repo's. This test used to overwrite the
    # tracked survivors.tsv and copy it back at the end; an interrupt between
    # those two points left the sentinel rows committed-ready in the working
    # tree, which is exactly what happened once during this work. $MUTATION_LEDGER
    # is the seam that removes the shared-state mutation altogether, so there is
    # no window to interrupt and no restore that can be skipped.
    local ledger="$FX/survivors.tsv"

    # One row for a target this run will NOT sweep, carrying a hand verdict...
    # ...and one for a target it WILL sweep, describing a mutation that does not
    # exist, which must therefore be dropped.
    {
        printf '#file\tline\tmutation\tverdict\tnote\n'
        printf 'scripts/lib/check-conflicts.sh\t99\tSENTINEL_NOT_SWEPT ==> x\twontfix\tkeep me\n'
        printf 'scripts/lib/check-env-vars.sh\t1\tSENTINEL_STALE ==> x\tequivalent\tdrop me\n'
    } > "$ledger"

    MUTATION_LEDGER="$ledger" run "$REPO_ROOT/tests/mutation/run-generated.sh" -k check-env-vars
    local rc="$status" out="$output"
    local after
    after="$(cat "$ledger")"

    [ "$rc" -eq 0 ] || { echo "the runner must always exit 0:"; echo "$out"; return 1; }

    [[ "$after" == *"SENTINEL_NOT_SWEPT"* ]] || {
        echo "a filtered run deleted the ledger row for a target it never swept."
        echo "every hand-assigned verdict outside the filter is lost this way."
        echo "$after"; return 1
    }
    [[ "$after" == *"wontfix"$'\t'"keep me"* ]] || {
        echo "the carried row lost its verdict or note:"; echo "$after"; return 1
    }
    [[ "$after" != *"SENTINEL_STALE"* ]] || {
        echo "a stale row for a SWEPT target was preserved. Rows for a target the"
        echo "run actually swept must be replaced by what that sweep found:"
        echo "$after"; return 1
    }
}

# Fields whose contents are PROSE and are therefore never allowed to be
# evaluated. --apply is deliberately absent: it is single-quoted shell by
# design and is the one field that is supposed to contain code.
scan_corpus_prose() {
    grep -n '^  --\(why\|test\|file\|bats\) ' "$1"/*.sh \
        | grep -P '(?<!\\)(`|\$\()' || true
}

@test "no corpus prose field can execute anything when the file is sourced" {
    # Corpus files are SOURCED by run-mutations.sh, so a backtick or $( ) left
    # unescaped inside a double-quoted --why or --test runs as a command before
    # any mutation is applied. This was not hypothetical: two entries shipped
    # that way and one of them executed `check-vpn.sh || notify` on every run of
    # the whole corpus. It found neither name on PATH; a prose field that
    # happened to name a real command would not have been so lucky.
    local bad
    bad=$(scan_corpus_prose "$REPO_ROOT/tests/mutation/corpus")
    if [ -n "$bad" ]; then
        fail "$(printf 'a corpus prose field would be evaluated when sourced:\n%s' "$bad")"
    fi
}

@test "the corpus prose scan actually catches an evaluating field" {
    # This guard gets no corpus entry, and not by omission. The only way to
    # mutate it is to reintroduce an unescaped substitution into a real corpus
    # file - and run-mutations.sh SOURCES every corpus file on every run, so the
    # mutation would execute the very thing the guard exists to prevent, in the
    # runner, before any test could observe it. A fixture proves the same thing
    # without arming it.
    local dir="$BATS_TEST_TMPDIR/corpus"
    mkdir -p "$dir"
    cat > "$dir/clean.sh" <<'EOF'
mutation fine \
  --why "a \`quoted\` name and a literal \$(not a substitution)" \
  --apply 'sed -i "s@a@b@" "$F"'
EOF
    run scan_corpus_prose "$dir"
    assert_success
    [ -z "$output" ] || fail "flagged a correctly escaped corpus file: $output"

    printf '%s\n' 'mutation bad \' '  --why "the consumer, `notify`, never fires" \' > "$dir/bad.sh"
    run scan_corpus_prose "$dir"
    assert_output --partial "bad.sh"

    printf '%s\n' 'mutation bad2 \' '  --test "runs $(id -u) at source time" \' > "$dir/bad2.sh"
    run scan_corpus_prose "$dir"
    assert_output --partial "bad2.sh"
}

# --- The oracle's time budget ----------------------------------------------
#
# Added 2026-09-01, after a generative sweep of scripts/lib/configure-helpers.sh
# ran past a 90-minute external cap having scored 3 of its 31 mutants. There was
# no per-mutant bound at all: one mutant that makes the oracle loop stalls the
# whole sweep, and for a tool whose entire job is injecting pathological code
# that is the expected case rather than an edge one.

@test "oracle_budget scales with the control run and floors at a minute" {
    run bash -c "
        source '$REPO_ROOT/tests/mutation/lib-mutate.sh'
        echo \"thirty=\$(oracle_budget 30)\"
        echo \"one=\$(oracle_budget 1)\"
        echo \"zero=\$(oracle_budget 0)\"
    "
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"thirty=300"* ]] || {
        echo "the budget is not derived from the control run:"; echo "$output"; return 1
    }
    # The floor is what stops a sub-second oracle being handed a sub-second
    # budget: on a loaded machine that would score every mutant as a timeout,
    # which reads as a perfect kill rate and measures nothing.
    [[ "$output" == *"one=60"* && "$output" == *"zero=60"* ]] || {
        echo "the floor did not apply:"; echo "$output"; return 1
    }
}

@test "oracle_budget refuses a control time it cannot trust" {
    # (( )) does not merely coerce a non-number to zero -- it EVALUATES it, so
    # an unvalidated argument is an injection surface as well as a wrong-answer
    # risk (bash expands command substitution inside an arithmetic subscript).
    # The control time comes from $SECONDS today, but the validation is what
    # keeps that a local fact rather than a load-bearing one.
    run bash -c "
        source '$REPO_ROOT/tests/mutation/lib-mutate.sh'
        echo \"expr=\$(oracle_budget '59 + 59')\"
        echo \"word=\$(oracle_budget abc)\"
        oracle_budget 'a[\$(touch $FX/evaluated)]' >/dev/null
    "
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"expr=60"* ]] || {
        echo "an expression was evaluated as if it were a measured duration:"
        echo "$output"; return 1
    }
    [[ "$output" == *"word=60"* ]] || { echo "$output"; return 1; }
    [ ! -e "$FX/evaluated" ] || {
        echo "the argument reached an arithmetic context and ran a command from"
        echo "inside an array subscript"; return 1
    }
}

@test "run_tests bounds the oracle at the budget rather than waiting on it" {
    mkdir -p "$FX/fakeroot/tests"
    # The fake runner FORKS its hang rather than exec'ing it, because that is
    # the shape of the real one: tests/run-tests.sh runs bats as a child, and
    # bats runs each test in a further subshell. So the bound is only real if
    # the whole process group dies -- if only the direct child were signalled,
    # the orphaned grandchild would keep the command substitution's stdout pipe
    # open and run_tests would block for the full 30s while reporting 124.
    cat > "$FX/fakeroot/tests/run-tests.sh" <<'RUNNER'
#!/bin/bash
echo "1..1"
bash -c 'sleep 30'
RUNNER
    chmod +x "$FX/fakeroot/tests/run-tests.sh"
    run bash -c "
        source '$REPO_ROOT/tests/mutation/lib-mutate.sh'
        ROOT='$FX/fakeroot'
        start=\$SECONDS
        res=\$(run_tests /dev/null '^x' 1)
        echo \"res=[\$res] elapsed=\$(( SECONDS - start ))\"
    "
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"res=[124 "* ]] || {
        echo "an oracle that never finished did not come back as a timeout:"
        echo "$output"; return 1
    }
    # The status alone is not proof: `timeout` reporting 124 while the caller
    # still waits out the full run is exactly the failure this asserts against.
    local elapsed="${output##*elapsed=}"
    [ "$elapsed" -le 10 ] || {
        echo "it reported 124 after waiting ${elapsed}s, so nothing was actually bounded"
        echo "$output"; return 1
    }
}

@test "run_tests leaves the oracle unbounded when no budget is given" {
    # The other half. A bound that fires unconditionally would pass the test
    # above while scoring every slow-but-passing oracle as a kill.
    mkdir -p "$FX/fakeroot/tests"
    cat > "$FX/fakeroot/tests/run-tests.sh" <<'RUNNER'
#!/bin/bash
echo "1..1"
sleep 2
echo "ok 1 slow but fine"
RUNNER
    chmod +x "$FX/fakeroot/tests/run-tests.sh"
    run bash -c "
        source '$REPO_ROOT/tests/mutation/lib-mutate.sh'
        ROOT='$FX/fakeroot'
        echo \"res=[\$(run_tests /dev/null '^x')]\"
    "
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"res=[0 1 0]"* ]] || {
        echo "an oracle that took longer than nothing was not allowed to finish:"
        echo "$output"; return 1
    }
}

@test "run_tests bounds the oracle's memory, not just its wall clock" {
    # timeout bounds time; it does nothing about memory. On 2026-09-02 a
    # generated mutant of scripts/lib/queue_cleanup.py looped allocating and
    # rebooted this 1.8 GiB host twice, well inside its wall-clock budget --
    # through the containerised pytest.sh, which now carries its own
    # `ulimit -v`. This is the same guard for the native path: every bash-side
    # bats file that run_tests invokes directly, no container involved.
    #
    # Asserting that lib-mutate.sh merely *contains* a `ulimit` line would be
    # the presence-is-not-behaviour trap this repo keeps paying for -- so the
    # fake runner reads its own limit back and reports it, the same way
    # test_oracle_environment.py does for the Python side.
    # run_tests only echoes its own "<status> <count> <skipped>" triple, never
    # the oracle's stdout, so the fake runner reports through a side-channel
    # file rather than through $output.
    mkdir -p "$FX/fakeroot/tests"
    cat > "$FX/fakeroot/tests/run-tests.sh" <<RUNNER
#!/bin/bash
ulimit -v > "$FX/limit.txt"
echo "1..1"
echo "ok 1 recorded"
RUNNER
    chmod +x "$FX/fakeroot/tests/run-tests.sh"
    # This test is itself invoked through run_tests() (run-mutations.sh's own
    # control/scoring calls go through the very function under test), so an
    # ambient ulimit -v from THAT outer call would already be in effect here
    # and inherited straight through to the fake runner below regardless of
    # what the mutated code does -- a false pass with the mutation in place.
    # `ulimit -v unlimited` only raises the soft limit, which is always legal
    # up to the hard ceiling as long as nothing in the chain has lowered that
    # too, so this resets to a clean baseline before the code under test gets
    # a chance to (or fails to) reapply its own cap.
    run bash -c "
        ulimit -v unlimited 2>/dev/null || true
        source '$REPO_ROOT/tests/mutation/lib-mutate.sh'
        ROOT='$FX/fakeroot'
        run_tests /dev/null '^x'
    "
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$FX/limit.txt" ] || {
        echo "the fake oracle never ran, or never reached the ulimit line"
        return 1
    }
    local limit
    limit="$(cat "$FX/limit.txt")"
    [[ "$limit" =~ ^[0-9]+$ ]] || {
        echo "ulimit -v read back as '$limit', not a finite number -- the oracle is unbounded"
        return 1
    }
    # A generous ceiling, not a tuned value: this only has to prove the bound
    # is real and well below host RAM (1.8 GiB here), not pin the exact KB.
    [ "$limit" -le 786432 ] || {
        echo "ulimit -v read back as ${limit}KB, too high to bound a runaway mutant"
        return 1
    }
}

@test "a mutant that hangs the oracle is scored a kill and named as a timeout" {
    # The end of the same story: run_tests reports 124, and the runner has to
    # decide what that means. It is a kill -- the oracle demonstrably did not
    # pass -- but it is not the same event as a clean red, and folding the two
    # together would hide the only thing that explains a sweep's wall-clock.
    #
    # ORACLE_BUDGET_FLOOR is why this takes seconds instead of a minute; it
    # exists for exactly this assertion.
    write_corpus <<CORPUS
mutation demo-hangs \
  --file "$FX/target.sh" --bats "$FX/fixture.bats" \
  --test "asserts the guarded output" --why "x" \
  --apply 'sed -i "1a sleep 300" "\$F"'
CORPUS
    run env ORACLE_BUDGET_FLOOR=2 "$RUNNER" "$FX/corpus.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"KILLED demo-hangs"* ]] || {
        echo "an oracle that never finished was not scored as a kill:"
        echo "$output"; return 1
    }
    [[ "$output" == *"hit the oracle time budget"* ]] || {
        echo "a timeout was tallied as an ordinary failure, so a sweep that got"
        echo "slower would say nothing about why:"; echo "$output"; return 1
    }
    # And the tree still has to come back. A restore that only runs on the
    # paths the author was thinking about is the failure this whole file exists
    # to catch.
    grep -q 'sleep 300' "$FX/target.sh" && {
        echo "the mutated target was left behind after a timeout"; return 1
    }
    return 0
}
