#!/usr/bin/env bats
# Shellcheck baseline.
#
# This file was merged as coverage and then never ran once, on any machine in
# this project. It skipped when `shellcheck` was absent, and shellcheck is
# absent on pi1 AND on the NAS -- the only two hosts that run this suite. So it
# reported a green skip forever while checking nothing, which is the same shape
# as the four tests this repo has already had to throw out for being incapable
# of failing. It now runs through `koalaman/shellcheck:stable` when no host
# binary exists, the pattern this repo already uses for tools the host lacks
# (alpine/git for git, the Playwright image for e2e), and skips only when
# neither shellcheck nor Docker is available -- saying which.
#
# The file list is derived from shebangs, not from `scripts/*.sh`. The old glob
# silently excluded `scripts/post-merge` and `scripts/pre-commit` -- both git
# hooks, both load-bearing, both extensionless -- along with the CGI scripts in
# duc-service/ and this suite's own tooling. A file becomes covered the moment
# it declares itself a shell script, rather than whenever someone remembers to
# widen a glob.
#
# Scoped to `-S error` only: the repo carries pre-existing info/warning-level
# findings (SC2086 unquoted vars, SC2012 `ls` usage, SC2034 unused vars) that
# are out of scope here. This check exists to catch genuine bugs -- broken
# syntax, invalid redirections, an unknown dialect -- not to gate on style.
# Widening the severity stays a separate, deliberate decision.

setup() {
    load helpers/setup
}

# Every tracked file that declares itself a shell script, minus the vendored
# bats-core submodule (not ours to fix).
shell_files() {
    local f
    while read -r f; do
        [ -f "$REPO_ROOT/$f" ] || continue
        case "$f" in
            tests/bats-core/*) continue ;;
            *.sh) echo "$f"; continue ;;
            *.bats|*.md|*.yml|*.yaml|*.json) continue ;;
        esac
        # Match the interpreter WORD, not a path fragment. The first version
        # was '^#!.*(bash|/sh)', which misses `#!/usr/bin/env sh` entirely --
        # no `/sh` substring, no `bash` -- so such a file would be silently
        # uncovered. The \b keeps `#!/usr/bin/env fish` and `.../python` out.
        if head -c 64 "$REPO_ROOT/$f" | head -1 \
           | grep -qE '^#!.*\b(ba|da|k|z)?sh([[:space:]]|$)'; then
            echo "$f"
        fi
    done < <(git -C "$REPO_ROOT" ls-files)
}

@test "every tracked shell script is free of shellcheck errors" {
    command -v git >/dev/null 2>&1 \
        || skip "no host git binary (the NAS drives this repo through a containerised alpine/git)"

    local files
    mapfile -t files < <(shell_files)

    # A file list that came back empty would make this pass while checking
    # nothing -- the exact failure this rewrite exists to remove.
    # 10 is a floor, not a count: scripts/lib/ alone holds a dozen check-*.sh,
    # so any real state of this repo is far above it and a result below it means
    # the discovery broke rather than that the scripts went away. Deliberately
    # not pinned to an exact number -- that is how the old "14 tests" claim in
    # CLAUDE.md went stale.
    [ "${#files[@]}" -gt 10 ] || fail "only ${#files[@]} shell scripts found; the discovery is broken, not the repo"

    if command -v shellcheck >/dev/null 2>&1; then
        run shellcheck -S error -- "${files[@]}"
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        # Check the image is actually present before running it. Without this,
        # an offline host or a registry hiccup makes this test FAIL with a pull
        # error -- a red suite for a reason that has nothing to do with the
        # code, which this repo has already been bitten by once in CI.
        if ! docker image inspect koalaman/shellcheck:stable >/dev/null 2>&1 \
           && ! docker pull -q koalaman/shellcheck:stable >/dev/null 2>&1; then
            skip "shellcheck image is not available locally and cannot be pulled"
        fi
        run docker run --rm -v "$REPO_ROOT:/mnt" -w /mnt \
            koalaman/shellcheck:stable -S error -- "${files[@]}"
    else
        skip "no shellcheck binary and no usable docker daemon to run it in"
    fi

    [ "$status" -eq 0 ] || fail "shellcheck errors across ${#files[@]} files:"$'\n'"$output"
}

# Every tracked shell file that is production code -- i.e. not this suite's own
# tooling, whose oracle is the suite itself.
production_shell_files() {
    local f
    while read -r f; do
        case "$f" in tests/*) continue ;; esac
        echo "$f"
    done < <(shell_files)
}

# Field 1 of every TARGETS row in the generative runner. Deliberately parses no
# further: a future fourth field, or a change to the regex convention, must not
# be able to break this.
sweep_targets() {
    sed -n '/^TARGETS=(/,/^)/p' "$REPO_ROOT/tests/mutation/run-generated.sh" \
        | grep -oE '"[^":]+:' | tr -d '":' | sort -u
}

@test "the no-sweep list in tests/mutation/README.md matches what TARGETS actually covers" {
    # WHY THIS IS A TEST AND NOT A PARAGRAPH
    #
    # The claim it replaces was "Ten scripts/lib/ files have no bats test
    # whatsoever", hand-written in three places at once. It was true when
    # written and false the day the first of those tests landed -- the same way
    # CLAUDE.md's old "14 tests" claim went stale, which that file now cites as
    # the reason not to hardcode counts. A list that cannot be wrong is worth
    # more than a list someone has to remember to edit.
    #
    # It fails in BOTH directions on purpose. Naming a file as unswept when it
    # has a target is the stale half; omitting one that has no target is the
    # half that would quietly under-report coverage as the repo grows.
    local expected actual
    expected="$(comm -23 <(production_shell_files | sort) <(sweep_targets))"

    actual="$(sed -n '/<!-- NO-SWEEP-ORACLE:/,/<!-- \/NO-SWEEP-ORACLE -->/p' \
                  "$REPO_ROOT/tests/mutation/README.md" \
              | grep -oE '^- `[^`]+`' | tr -d '`' | sed 's/^- //' | sort)"

    # Neither side may be empty. An empty `expected` would mean the discovery
    # broke; an empty `actual` would mean the markers moved or were renamed.
    # Either way the comparison would pass by matching nothing against nothing.
    [ -n "$expected" ] || fail "derived no-sweep list is empty; the discovery is broken"
    [ -n "$actual" ]   || fail "no NO-SWEEP-ORACLE block found in tests/mutation/README.md"

    if [ "$expected" != "$actual" ]; then
        {
            echo "tests/mutation/README.md's no-sweep list disagrees with TARGETS."
            echo "--- in the README but IS swept (stale, remove the line) ---"
            comm -13 <(echo "$expected") <(echo "$actual")
            echo "--- has no TARGETS entry but is NOT in the README (add the line) ---"
            comm -23 <(echo "$expected") <(echo "$actual")
        } >&2
        fail "no-sweep list is out of date"
    fi
}

# Function names bats-support and bats-assert define -- and therefore depend on
# being callable. Derived from the submodules rather than listed, so a rename or
# an added helper upstream widens this guard for free.
bats_helper_functions() {
    grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' \
        "$REPO_ROOT"/tests/bats-support/src/*.bash \
        "$REPO_ROOT"/tests/bats-assert/src/*.bash 2>/dev/null \
        | tr -d '()' | sort -u
}

# Repo shell files a given .bats sources into the bats shell itself. Only the
# ones a literal path resolves for -- a `source "$SOME_VAR"` is invisible here
# and deliberately not guessed at.
sourced_repo_files() {
    local b="$1" raw p
    grep -hoE '(^|[[:space:]])(source|\.)[[:space:]]+"[^"]+"' "$REPO_ROOT/$b" \
        | grep -oE '"[^"]+"' | tr -d '"' \
    | while read -r raw; do
        p="${raw//\$\{REPO_ROOT\}/$REPO_ROOT}"
        p="${p//\$REPO_ROOT/$REPO_ROOT}"
        p="${p//\$\{BATS_TEST_DIRNAME\}\/../$REPO_ROOT}"
        p="${p//\$BATS_TEST_DIRNAME\/../$REPO_ROOT}"
        case "$p" in
            *'$'*) continue ;;                 # unresolved variable, skip
            "$REPO_ROOT"/tests/*) continue ;;  # test infrastructure, not a unit
        esac
        [ -f "$p" ] && echo "$p"
    done | sort -u
}

@test "no test file sources a unit that shadows a function bats-assert reports through" {
    # WHY THIS EXISTS
    #
    # bats-assert reports every failure by calling bats-support's `fail`, which
    # returns 1. scripts/lib/configure-helpers.sh:34 defines its own `fail` --
    # an output helper that prints a red cross and returns 0.
    # tests/lib-configure-helpers.bats sources that library into the bats shell,
    # so bats-support's `fail` was shadowed and every assert_output in the file
    # became INCAPABLE OF FAILING. Twenty-two tests reported ok against output
    # that plainly contradicted them, and two recorded defects survived the
    # mutation corpus because the tests meant to kill them could not go red.
    #
    # Nothing about that is specific to `fail`, to this library, or to this test
    # file. Any unit under test that happens to define a name bats-assert calls
    # silently disarms an entire file's assertions, and the file still reports
    # green -- so no amount of running the suite reveals it. The collision is
    # statically decidable, so it is decided statically here.
    local helpers b unit collisions=""
    helpers="$(bats_helper_functions)"
    [ -n "$helpers" ] || fail "found no bats-support/bats-assert functions; the discovery is broken"

    # A file is only at risk if it calls one of bats-assert's OWN assertions.
    # A test file's private helper that merely happens to be named assert_curl
    # reports its own failure with `return 1` and is unaffected -- matching on
    # the name prefix would flag exactly the files that already did the right
    # thing.
    # `awk`, not `paste -sd'|'`: macOS's paste wants the delimiter as a separate
    # option argument and reads `|` as a filename, so the assertion list came
    # back empty and this test failed with `usage: paste` on any BSD host. awk
    # joins the same list on every host the suite runs on.
    local assertions_re
    assertions_re="$(grep -hoE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' \
                        "$REPO_ROOT"/tests/bats-assert/src/*.bash 2>/dev/null \
                     | tr -d '()' | sort -u | awk 'NR>1{printf "|"} {printf "%s", $0} END{if (NR) printf "\n"}')"
    [ -n "$assertions_re" ] || fail "found no bats-assert assertions; the discovery is broken"

    for b in $(cd "$REPO_ROOT" && git ls-files 'tests/*.bats'); do
        # Full-line comments are stripped first: the file that discovered this
        # trap documents it by name, and prose about an assertion is not a call
        # to one. A trailing comment cannot hide a real call, which sits to the
        # left of the `#`.
        grep -v '^[[:space:]]*#' "$REPO_ROOT/$b" \
            | grep -qE "(^|[^[:alnum:]_])(${assertions_re})([[:space:]]|\$)" || continue
        for unit in $(sourced_repo_files "$b"); do
            local shadowed
            shadowed="$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$unit" | tr -d '()' \
                        | sort -u | comm -12 - <(echo "$helpers"))"
            if [ -n "$shadowed" ]; then
                collisions+="$b sources ${unit#$REPO_ROOT/} which redefines: $(echo $shadowed)"$'\n'
            fi
        done
    done

    if [ -n "$collisions" ]; then
        {
            echo "A sourced unit redefines a function bats-assert reports failures through."
            echo "Every bats-assert assertion in that test file is incapable of failing."
            echo "$collisions"
            echo "Fix: assert through helpers local to the test file that 'return 1'"
            echo "themselves (see tests/lib-configure-helpers.bats's out_has/out_lacks)."
        } >&2
        fail "assertion-shadowing collision"
    fi
}

# Script files CONTRIBUTING.md's tree is expected to name: everything under
# scripts/ that is a script. Systemd units live there too and are deliberately
# out of scope -- the section is titled "Scripts Structure", and listing a
# .timer beside a .sh would blur what the tree is for.
#
# `sed` prefixes each path rather than `find -printf`: GNU find's -printf is not
# in BSD find, and on macOS the failure is quiet in the worst way -- find exits
# non-zero having printed nothing, so the list comes back empty and this test
# fails reporting every documented script as stale. That is the opposite of the
# truth, and it read as a real mismatch until the `find: -printf: unknown
# primary` line above it was noticed. The suite is meant to give the same
# verdict on the Mac, on pi1 and on the NAS; only the container and GNU-userland
# paths were exercised, so this went unseen.
documented_script_files() {
    { find "$REPO_ROOT/scripts" -maxdepth 1 -type f \
           \( -name '*.sh' -o -name '*.py' \) | sed 's|.*/|scripts/|'
      find "$REPO_ROOT/scripts/lib" -maxdepth 1 -type f \
           \( -name '*.sh' -o -name '*.py' \) | sed 's|.*/|scripts/lib/|'
      printf '%s\n' scripts/pre-commit scripts/post-merge
    } | sort -u
}

@test "the scripts tree in CONTRIBUTING.md names every script that exists" {
    # Same reasoning as the no-sweep list above, applied to the other
    # hand-maintained inventory in this repo. When this was written the tree
    # named 3 of the 16 files in scripts/ and was missing env-file.sh and all
    # three extracted Python modules -- it had been accurate once.
    #
    # Only the NAMES are derived. The descriptions beside them are prose and
    # nobody can generate those, so adding a script fails this test until
    # somebody writes one line about it. That is the intended cost.
    local expected actual
    expected="$(documented_script_files)"

    # Compared as PATHS, not bare names. The first version of this compared
    # basenames across both sections at once, and a corpus entry caught it:
    # a bogus `check-dns-duplicates.sh` under scripts/ was masked by the real
    # one under scripts/lib/, so the tree could name a file in the wrong place
    # and still pass. Indentation is what says which section a line is in.
    actual="$(sed -n '/<!-- SCRIPTS-TREE-ORACLE:/,/<!-- \/SCRIPTS-TREE-ORACLE -->/p' \
                  "$REPO_ROOT/CONTRIBUTING.md" \
              | sed -nE 's/^(├──|└──) ([A-Za-z0-9_.-]+) .*/scripts\/\2/p;
                         s/^    (├──|└──) ([A-Za-z0-9_.-]+) .*/scripts\/lib\/\2/p' \
              | sort -u)"

    # Neither side may be empty, for the same reason as above: an empty
    # `expected` means the discovery broke, an empty `actual` means the markers
    # moved, and either way the comparison would pass by matching nothing.
    [ -n "$expected" ] || fail "found no scripts to document; the discovery is broken"
    [ -n "$actual" ]   || fail "no SCRIPTS-TREE-ORACLE block found in CONTRIBUTING.md"

    if [ "$expected" != "$actual" ]; then
        {
            echo "CONTRIBUTING.md's scripts tree disagrees with scripts/ on disk."
            echo "--- in the tree but not on disk (stale, remove the line) ---"
            comm -13 <(echo "$expected") <(echo "$actual")
            echo "--- on disk but not in the tree (add it, with a description) ---"
            comm -23 <(echo "$expected") <(echo "$actual")
        } >&2
        fail "scripts tree is out of date"
    fi
}
