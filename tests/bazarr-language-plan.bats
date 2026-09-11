#!/usr/bin/env bats
# Unit tests for scripts/lib/bazarr-language-plan.py — the decision behind
# configure-apps.sh's Bazarr subtitle-profile step.
#
# Each test is a Bazarr state the earlier code got wrong: it created a
# profile only when the list was empty and then pointed the defaults at a
# hard-coded id 1; it pruned every profile, not just its own; it treated
# "nothing to remove" as "already configured" even with no profile at all;
# and it re-sent the full profile list (which makes Bazarr rescan the whole
# library) for a change that only touched the Languages Filter. The plan is
# pure — two JSON bodies in, one JSON line out — so these run anywhere with
# python3.

setup() {
    load helpers/setup
    PLAN="$REPO_ROOT/scripts/lib/bazarr-language-plan.py"
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

# field KEY -- prints one field of the plan's JSON line (lists/dicts as compact JSON).
field() {
    local key="$1"; shift
    python3 "$PLAN" "$@" | python3 -c '
import json, sys
v = json.load(sys.stdin)[sys.argv[1]]
print(v if isinstance(v, (str, int)) and not isinstance(v, bool) else json.dumps(v, separators=(",", ":")))
' "$key"
}

@test "fresh Bazarr: creates English as id 1, sends the profile, ticks only en" {
    local args=('[]' "$LANGS_NONE" en English)
    run field action "${args[@]}";        assert_output "CREATE"
    run field profile_id "${args[@]}";    assert_output "1"
    run field send_profiles "${args[@]}"; assert_output "true"
    run field enabled "${args[@]}";       assert_output '["en"]'
}

@test "French-only profile at id 1: creates English at id 2, leaves French untouched, keeps fr ticked" {
    local before; before="[$(profile 1 French fr)]"
    local args=("$before" "$LANGS_EN_FR" en English)
    run field action "${args[@]}";     assert_output "CREATE"
    run field profile_id "${args[@]}"; assert_output "2"
    run field enabled "${args[@]}";    assert_output '["en","fr"]'
    run field send_ticks "${args[@]}"; assert_output "false"
    run python3 -c '
import json, sys
before = json.loads(sys.argv[1]); plan = json.loads(sys.argv[2])
after = plan["profiles"]
assert after[0] == before[0], ("French profile was modified", before[0], after[0])
assert after[1]["profileId"] == 2 and after[1]["name"] == "English", after[1]
assert [i["language"] for i in after[1]["items"]] == ["en"], after[1]["items"]
' "$before" "$(python3 "$PLAN" "${args[@]}")"
    assert_success
}

@test "English profile containing Latvian: removes lv from the profile and unticks it" {
    local args=("[$(profile 1 English en lv)]" "$LANGS_EN_LV" en English)
    run field action "${args[@]}";        assert_output "UPDATE"
    run field summary "${args[@]}";       assert_output "languages -lv, ticks -lv"
    run field send_profiles "${args[@]}"; assert_output "true"
    run field profiles "${args[@]}";      refute_output --partial '"language":"lv"'
}

@test "profile with the right languages under another name is adopted, not duplicated" {
    local args=("[$(profile 1 'Moose Languages' en)]" "$LANGS_EN" en English)
    run field action "${args[@]}";     assert_output "MATCH"
    run field profile_id "${args[@]}"; assert_output "1"
    run field name "${args[@]}";       assert_output "Moose Languages"
}

@test "stray tick with nothing using it is cleared WITHOUT re-sending the profiles (no library rescan)" {
    # English [en] managed; French [fr] belongs to the user; lv ticked by nobody.
    local args=("[$(profile 1 English en),$(profile 2 French fr)]" "$LANGS_EN_LV" en English)
    run field action "${args[@]}";        assert_output "UPDATE"
    run field send_profiles "${args[@]}"; assert_output "false"
    run field send_ticks "${args[@]}";    assert_output "true"
    run field enabled "${args[@]}";       assert_output '["en","fr"]'
    run field summary "${args[@]}";       assert_output "ticks +fr -lv"
}

@test "missing wanted language is ADDED — the knob is not remove-only" {
    local args=("[$(profile 1 English en)]" "$LANGS_EN" "en fr" English)
    run field action "${args[@]}";   assert_output "UPDATE"
    run field summary "${args[@]}";  assert_output "languages +fr, ticks +fr"
    run field profiles "${args[@]}"; assert_output --partial '"language":"fr"'
}

@test "already correct: MATCH, nothing to send" {
    local args=("[$(profile 1 English en),$(profile 2 French fr)]" "$LANGS_EN_FR" en English)
    run field action "${args[@]}";        assert_output "MATCH"
    run field send_profiles "${args[@]}"; assert_output "false"
    run field send_ticks "${args[@]}";    assert_output "false"
}

@test "deleted-and-recreated ids: next id is max+1, never a reused 1" {
    run field profile_id "[$(profile 3 French fr)]" "$LANGS_EN_FR" en English
    assert_output "4"
}

@test "a profile name containing '|' or a quote survives the round trip" {
    local args=("[$(profile 1 'English | Forced' en)]" "$LANGS_EN" en English)
    run field name "${args[@]}"; assert_output 'English | Forced'
    run field action "${args[@]}"; assert_output "MATCH"
}

@test "not the list Bazarr returns, or no wanted languages: exits non-zero and prints nothing" {
    run python3 "$PLAN" '{"error":"unauthorized"}' "$LANGS_NONE" en English
    assert_failure; assert_output ''
    run python3 "$PLAN" '' "$LANGS_NONE" en English
    assert_failure; assert_output ''
    run python3 "$PLAN" "[$(profile 1 English en)]" "$LANGS_EN" "" English
    assert_failure; assert_output ''
}
