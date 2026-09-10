#!/usr/bin/env bats
# Every corpus entry must still be able to change its target.
#
# run-mutations.sh treats "the mutation changed nothing" as a hard ERROR, because
# a pattern that stopped matching after a refactor would otherwise score a false
# KILLED. But that check only runs when somebody runs the corpus, and no workflow
# does -- 271 entries, each running its oracle twice. This file performs the same
# ASSERT step for every entry with no oracle at all: source each corpus with a
# recording `mutation()` stub, apply each --apply to a COPY of the target, and
# require the bytes to differ. Seconds instead of hours, and it catches both an
# inert pattern and a target that has been renamed away.
#
# GNU sed is a hard requirement of the corpus itself (see tests/mutation/README.md),
# so this skips on BSD sed -- naming the consequence, so the skip cannot be read as
# a pass.

setup() {
    load helpers/setup
    MUT_DIR="$REPO_ROOT/tests/mutation"
}

# Populate MUTATIONS with "id|file|oracle|apply" for one corpus file.
record_corpus() {
    MUTATIONS=()
    mutation() {
        local id="$1"; shift
        local file="" oracle="" apply=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --file)  file="$2";   shift 2 ;;
                --bats)  oracle="$2"; shift 2 ;;
                --test)  shift 2 ;;
                --why)   shift 2 ;;
                --apply) apply="$2";  shift 2 ;;
                *)       shift ;;
            esac
        done
        MUTATIONS+=("$id|$file|$oracle|$apply")
    }
    # shellcheck disable=SC1090
    source "$1"
    unset -f mutation
}

@test "mutation corpus: every --apply still changes its target" {
    command -v sed >/dev/null 2>&1 || skip "no sed on this host"
    if ! sed --version >/dev/null 2>&1; then
        skip "BSD sed: the corpus is GNU-sed-based (tests/mutation/README.md), so an inert mutation cannot be told apart from a sed that refuses the syntax here"
    fi

    local corpus entry id file oracle apply tmp before after count=0
    local -a inert=() missing=() strayed=()

    for corpus in "$MUT_DIR"/corpus/*.sh; do
        record_corpus "$corpus"
        for entry in "${MUTATIONS[@]}"; do
            IFS='|' read -r id file oracle apply <<<"$entry"
            count=$((count + 1))
            [[ -f "$REPO_ROOT/$file" ]]   || { missing+=("$id (target $file)"); continue; }
            [[ -f "$REPO_ROOT/$oracle" ]] || { missing+=("$id (oracle $oracle)"); continue; }

            tmp="$BATS_TEST_TMPDIR/mutant.$count"
            cp "$REPO_ROOT/$file" "$tmp"
            before=$(cksum < "$REPO_ROOT/$file")
            ( cd "$REPO_ROOT" && F="$tmp" eval "$apply" ) >/dev/null 2>&1 || true
            after=$(cksum < "$tmp")

            [[ "$before" != "$after" ]] || inert+=("$id ($file)")

            # --apply must only ever touch the copy it was handed. Anything else
            # would be the runner mutating the tree outside its restore discipline.
            [[ "$(cksum < "$REPO_ROOT/$file")" == "$before" ]] || strayed+=("$id")
            rm -f "$tmp"
        done
    done

    [[ "$count" -gt 0 ]] || fail "no corpus entries were recorded - the recording stub stopped matching the corpus format"
    [[ ${#missing[@]} -eq 0 ]] || fail "corpus entries point at files that no longer exist: ${missing[*]}"
    [[ ${#strayed[@]} -eq 0 ]] || fail "a mutation wrote outside the copy it was handed: ${strayed[*]}"
    [[ ${#inert[@]} -eq 0 ]] || fail "these mutations no longer change their target, so the runner would score them ERROR: ${inert[*]}"
    echo "checked $count corpus entries"
}
