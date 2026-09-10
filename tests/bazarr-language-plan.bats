#!/usr/bin/env bats
# Unit tests for scripts/lib/bazarr-language-plan.py — the decision behind
# configure-apps.sh's Bazarr subtitle-profile step.
#
# Each test is a Bazarr state the earlier code got wrong: it created a
# profile only when the list was empty and then pointed the defaults at a
# hard-coded id 1; it pruned every profile, not just its own; and it treated
# "nothing to remove" as "already configured" even with no profile at all.
# The plan is pure — two JSON bodies in, two lines out — so these run
# anywhere with python3.

setup() {
    load helpers/setup
    PLAN="$REPO_ROOT/scripts/lib/bazarr-language-plan.py"
    # Bazarr's languages list: every language a row, enabled per state.
    LANGS_NONE='[{"code2":"en","enabled":false},{"code2":"fr","enabled":false},{"code2":"lv","enabled":false}]'
    LANGS_EN='[{"code2":"en","enabled":true},{"code2":"fr","enabled":false},{"code2":"lv","enabled":false}]'
    LANGS_EN_LV='[{"code2":"en","enabled":true},{"code2":"fr","enabled":false},{"code2":"lv","enabled":true}]'
    LANGS_EN_FR='[{"code2":"en","enabled":true},{"code2":"fr","enabled":true},{"code2":"lv","enabled":false}]'
}

profile() {  # id name lang...
    local id="$1" name="$2"; shift 2
    local items="" i=1 c
    for c in "$@"; do
        [[ -n "$items" ]] && items+=","
        items+="{\"id\":$i,\"language\":\"$c\",\"audio_exclude\":\"False\",\"audio_only_include\":\"False\",\"hi\":\"False\",\"forced\":\"False\"}"
        i=$((i+1))
    done
    echo "{\"profileId\":$id,\"name\":\"$name\",\"cutoff\":null,\"items\":[$items],\"mustContain\":[],\"mustNotContain\":[],\"originalFormat\":0,\"tag\":null}"
}

# Line 1 columns: ACTION|PROFILE_ID|NAME|ADDED|REMOVED|TICK_ADD|TICK_REMOVE|ENABLED
head1() { python3 "$PLAN" "$@" | head -1; }
line2() { python3 "$PLAN" "$@" | sed -n 2p; }

@test "fresh Bazarr: creates English as id 1 and ticks only en" {
    run head1 '[]' "$LANGS_NONE" en English
    assert_success
    assert_output "CREATE|1|English|en||en||en"
}

@test "French-only profile at id 1: creates English at id 2, leaves French alone, keeps fr ticked" {
    local before; before="[$(profile 1 French fr)]"
    run head1 "$before" "$LANGS_EN_FR" en English
    assert_output "CREATE|2|English|en||||en fr"
    # The French profile is sent back unchanged (compared as JSON, not text);
    # English is appended after it.
    run python3 -c '
import json, sys
before = json.loads(sys.argv[1]); after = json.loads(sys.argv[2])
assert after[0] == before[0], ("French profile was modified", before[0], after[0])
assert after[1]["profileId"] == 2 and after[1]["name"] == "English", after[1]
assert [i["language"] for i in after[1]["items"]] == ["en"], after[1]["items"]
' "$before" "$(line2 "$before" "$LANGS_EN_FR" en English)"
    assert_success
}

@test "English profile containing Latvian: removes lv from the profile and unticks it" {
    run head1 "[$(profile 1 English en lv)]" "$LANGS_EN_LV" en English
    assert_output "UPDATE|1|English||lv||lv|en"
    run line2 "[$(profile 1 English en lv)]" "$LANGS_EN_LV" en English
    refute_output --partial '"language": "lv"'
}

@test "profile with the right languages under another name is adopted, not duplicated" {
    run head1 "[$(profile 1 'Moose Languages' en)]" "$LANGS_EN" en English
    assert_output "MATCH|1|Moose Languages|||||en"
}

@test "stray tick with nothing using it is cleared; a tick another profile uses is kept" {
    # English [en] managed; French [fr] belongs to the user; lv ticked by nobody.
    local profiles; profiles="[$(profile 1 English en),$(profile 2 French fr)]"
    run head1 "$profiles" "$LANGS_EN_LV" en English
    assert_output "UPDATE|1|English|||fr|lv|en fr"
}

@test "missing wanted language is ADDED — the knob is not remove-only" {
    run head1 "[$(profile 1 English en)]" "$LANGS_EN" "en fr" English
    assert_output "UPDATE|1|English|fr||fr||en fr"
    run line2 "[$(profile 1 English en)]" "$LANGS_EN" "en fr" English
    assert_output --partial '"language": "fr"'
}

@test "already correct: MATCH, and the returned list is unchanged" {
    local profiles; profiles="[$(profile 1 English en),$(profile 2 French fr)]"
    run head1 "$profiles" "$LANGS_EN_FR" en English
    assert_output "MATCH|1|English|||||en fr"
}

@test "deleted-and-recreated ids: next id is max+1, never a reused 1" {
    run head1 "[$(profile 3 French fr)]" "$LANGS_EN_FR" en English
    assert_output "CREATE|4|English|en||||en fr"
}

@test "not the list Bazarr returns: exits non-zero and prints nothing" {
    run python3 "$PLAN" '{"error":"unauthorized"}' "$LANGS_NONE" en English
    assert_failure
    assert_output ''
    run python3 "$PLAN" '' "$LANGS_NONE" en English
    assert_failure
    assert_output ''
}
