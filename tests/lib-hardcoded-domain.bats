#!/usr/bin/env bats
# scripts/lib/check-hardcoded-domain.sh
#
# This check has two halves with DIFFERENT severities, and the difference is the
# whole point of the file:
#
#   * the domain half WARNS - a domain in a Traefik dynamic config is often
#     unavoidable, so it prints and returns 0.
#   * the hostname half BLOCKS - the NAS's hostname is private, and the file
#     says so at L58: "BLOCKS - this should never be committed". It is the only
#     `return 1` in the file.
#
# Every test below names which half it is exercising, because a test that
# conflates them would pass while the blocking half was doing nothing.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/common.sh"
    source "$REPO_ROOT/scripts/lib/check-hardcoded-domain.sh"

    # common.sh caches its config in globals and short-circuits on a _LOADED
    # flag. Left alone, whichever test ran first would decide the answer for
    # every test after it, and the file would appear to pass in one order and
    # fail in another.
    _NAS_CONFIG_LOADED=true
    _DOMAIN_LOADED=true

    FILES="$BATS_TEST_TMPDIR/files"
    mkdir -p "$FILES"

    # The two seams every check in scripts/lib/ reads the world through.
    get_files_to_scan() { (cd "$FILES" && find . -type f | sed 's|^\./||' | sort); }
    read_file_content() { cat "$FILES/$1" 2>/dev/null; }
}

fixture() { mkdir -p "$FILES/$(dirname "$1")"; printf '%s\n' "$2" > "$FILES/$1"; }

# A repo with a domain configured and a NAS hostname known.
configured() {
    get_domain()        { echo "example.com"; }
    has_custom_domain() { return 0; }
    get_nas_hostname()  { echo "mynas"; }
}

# --- The blocking half ------------------------------------------------------

@test "hardcoded-domain: BLOCKS when the NAS hostname appears in a tracked file" {
    configured
    fixture docs/NOTES.md "ssh admin@mynas.local to get in"
    run check_hardcoded_domain
    assert_failure
    assert_output --partial "ERROR: NAS hostname 'mynas' found"
    assert_output --partial "docs/NOTES.md"
}

@test "hardcoded-domain: the hostname match is case-insensitive" {
    configured
    fixture docs/NOTES.md "The MyNAS box"
    run check_hardcoded_domain
    assert_failure
}

@test "hardcoded-domain: the leak report counts the hostname occurrences" {
    # The half of this file that BLOCKS builds its report line from a `grep -ci`
    # count, and the two tests above assert only the ERROR header and the file
    # name -- both of which survive a broken count. `|| echo 0` -> `&& echo 0`
    # makes the substitution capture grep's number AND the `0`, so the report
    # reads "(2" newline "0 occurrences)".
    #
    # Measured under that mutation, with this fixture: the header, the file name
    # and the exit status 1 are all unchanged, and only the count breaks. The
    # `|| echo 0` fallback itself is unreachable here, because :74 has already
    # matched the same pattern against the same variable.
    configured
    fixture docs/NOTES.md "$(printf 'mynas\nmynas')"
    run check_hardcoded_domain
    assert_failure
    assert_output --partial "docs/NOTES.md (2 occurrences)"
}

@test "hardcoded-domain: passes when no tracked file names the NAS hostname" {
    configured
    fixture docs/NOTES.md "nothing private in here"
    run check_hardcoded_domain
    assert_success
    assert_output --partial "OK: No hardcoded domain/hostname found"
}

@test "hardcoded-domain: an unset NAS hostname cannot block" {
    # get_nas_hostname is empty on any machine without .claude/config.local.md.
    # The guard must skip rather than match the empty string against every file,
    # which grep would treat as "matches everything" and fail every commit.
    get_domain()        { echo "example.com"; }
    has_custom_domain() { return 0; }
    get_nas_hostname()  { echo ""; }
    fixture docs/NOTES.md "anything at all"
    run check_hardcoded_domain
    assert_success
}

# --- The warning half -------------------------------------------------------

@test "hardcoded-domain: WARNS but does not block when the domain is hardcoded" {
    # The severity difference is the reason this file exists. If a domain hit
    # ever started returning 1, every commit touching a Traefik dynamic config
    # would be refused.
    configured
    fixture traefik/dynamic/app.yml "Host(\`app.example.com\`)"
    run check_hardcoded_domain
    assert_success
    assert_output --partial "WARNING: Your domain 'example.com' is hardcoded"
    assert_output --partial "traefik/dynamic/app.yml"
}

@test "hardcoded-domain: reports the occurrence count per file" {
    configured
    fixture traefik/dynamic/app.yml "$(printf 'a.example.com\nb.example.com\nc.example.com')"
    run check_hardcoded_domain
    assert_output --partial "(3 occurrences)"
}

@test "hardcoded-domain: a domain hit suppresses the OK line" {
    # `warnings` gates the OK message. A file that both warns and prints OK is
    # telling the committer two contradictory things at once.
    configured
    fixture traefik/dynamic/app.yml "app.example.com"
    run check_hardcoded_domain
    refute_output --partial "OK: No hardcoded"
}

# --- Skips and early returns ------------------------------------------------

@test "hardcoded-domain: returns early when there is nothing to scan" {
    configured
    get_files_to_scan() { echo ""; }
    run check_hardcoded_domain
    assert_success
    [ -z "$output" ]
}

@test "hardcoded-domain: binary files are never read" {
    # is_binary_file is by EXTENSION, not by content - so a .svg holding the
    # hostname as text is skipped by design. Pinning it stops someone "fixing"
    # the extension list without realising it changes what the check can see.
    configured
    fixture assets/logo.svg "mynas"
    run check_hardcoded_domain
    assert_success
}

@test "hardcoded-domain: says WHY it skipped when no domain is configured" {
    get_nas_hostname()  { echo ""; }
    has_custom_domain() { return 1; }
    get_domain()        { echo ""; }
    get_repo_root()     { echo "$BATS_TEST_TMPDIR/empty-repo"; }
    mkdir -p "$BATS_TEST_TMPDIR/empty-repo"
    fixture README.md "something to scan"
    run check_hardcoded_domain
    assert_success
    assert_output --partial "can't determine domain"
}

@test "hardcoded-domain: distinguishes 'no .env at all' from 'no custom domain'" {
    # Two different skips with two different fixes. Collapsing them into one
    # message sends the reader to the wrong remedy.
    get_nas_hostname()  { echo ""; }
    has_custom_domain() { return 1; }
    get_domain()        { echo "yourdomain.com"; }
    get_repo_root()     { echo "$BATS_TEST_TMPDIR/has-env"; }
    mkdir -p "$BATS_TEST_TMPDIR/has-env"
    : > "$BATS_TEST_TMPDIR/has-env/.env"
    fixture README.md "something to scan"
    run check_hardcoded_domain
    assert_success
    assert_output --partial "No custom domain configured"
    refute_output --partial "can't determine domain"
}

# --- The errexit contract ---------------------------------------------------
#
# scripts/pre-commit runs under `set -e` and sources this file into itself, so
# the check's behaviour depends on something invisible at its own call site:
# whether the caller wrapped it in `if`. Inside an `if` condition bash suppresses
# errexit for the whole callee, so a mid-function command returning 1 is
# harmless; called bare, the same command kills the hook where it stands.
#
# That is exactly how this file used to fail. `((hostname_errors++))` sat inside
# the loop that builds the leak report, post-increment on a counter starting at
# 0, so it returned 1 on the first hit -- and check 5 called the function bare.
# The hook died mid-loop: no ERROR message, no file list, the `return 1` at :81
# never reached, and its last line of output an unrelated SKIP from check 5's
# own preamble. The commit was still rejected, by the abort rather than by the
# check, which is why a correct-looking exit code hid it.
#
# So these pin the contract the library owes ANY caller, rather than the one it
# happens to get from today's.

# Run a check the way a caller with errexit armed and no `if` wrapper would.
#
# This cannot be done in-process, and the reason is worth stating because every
# obvious attempt silently passes: `run` clears errexit, an `if` condition
# suppresses it inside the callee, and even `( set -e; f ) || rc=$?` suppresses
# it -- a subshell that is the left operand of `||` runs with errexit disabled
# no matter what `set -e` appears inside it. Each idiom bats offers to CATCH the
# abort is also an idiom that PREVENTS it. Only a separate process sees it.
bare_call_under_errexit() {
    cat > "$BATS_TEST_TMPDIR/driver.sh" <<DRIVER
set -e
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/$1"
_NAS_CONFIG_LOADED=true
_DOMAIN_LOADED=true
get_files_to_scan() { (cd "$FILES" && find . -type f | sed 's|^\./||' | sort); }
read_file_content() { cat "$FILES/\$1" 2>/dev/null; }
get_domain()        { echo "example.com"; }
has_custom_domain() { return 0; }
get_nas_hostname()  { echo "mynas"; }
$2
echo "REACHED-END"
DRIVER
    run bash "$BATS_TEST_TMPDIR/driver.sh"
}

@test "hardcoded-domain: a domain warning does not kill a caller under set -e" {
    fixture traefik/dynamic/app.yml "Host(\`app.example.com\`)"
    bare_call_under_errexit check-hardcoded-domain.sh check_hardcoded_domain
    [ "$status" -eq 0 ]
    [[ "$output" == *"REACHED-END"* ]]
}

@test "hardcoded-domain: BLOCKS by returning, having printed the report first" {
    fixture docs/NOTES.md "ssh admin@mynas.local to get in"
    bare_call_under_errexit check-hardcoded-domain.sh check_hardcoded_domain
    # Returning 1 to a bare caller under errexit is correct and expected. What
    # must NOT happen is dying before saying why: the whole value of a blocking
    # check is the message naming the file, not the exit code.
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: NAS hostname"* ]]
    [[ "$output" == *"NOTES.md"* ]]
    [[ "$output" != *"REACHED-END"* ]]
}
