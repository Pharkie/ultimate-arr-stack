#!/usr/bin/env bats
# Does scripts/pre-commit actually account for its errors, or does it just die?
#
# The hook maintains an ERRORS counter, and ends with a summary that reads
#
#     BLOCKED: $ERRORS error(s) found
#     ... To skip hooks (NOT RECOMMENDED): git commit --no-verify
#
# None of that could ever print. `set -e` is in force (scripts/pre-commit:8),
# and every blocking check does
#
#     if check_x; then ok; else ((ERRORS++)); fi
#
# `((ERRORS++))` is a POST-increment: it evaluates to the value BEFORE the
# increment, which on the first failure is 0, and a `((...))` command whose
# expression evaluates to 0 returns exit status 1. An else-branch is not a
# condition context, so errexit fires and the hook dies on the spot -- at the
# FIRST failing check, before the counter it just tried to raise is ever read.
#
# The same shape appears inside two libraries that the hook calls BARE (checks
# 5 and 7), where errexit is not suppressed either. check-hardcoded-domain.sh
# aborts at `((hostname_errors++))` (:73) partway through building its report,
# so the `ERROR: NAS hostname ...` message and the `return 1` at :81 -- the
# file's only non-zero return, commented at :58 as "BLOCKS" -- are both
# unreachable, and the hook's last line of output is an unrelated SKIP.
#
# The commit is still rejected, so this hides behind a correct-looking exit
# code. What is lost is everything else: the later checks never run (including
# the BLOCKING check 11), no summary prints, no --no-verify hint prints, and
# the count could never exceed 1 even if it did print.
#
# It is also blocking BY ACCIDENT, which makes it fragile in the worst
# direction: initialising ERRORS=1, or the obvious shellcheck-style cleanup to
# `ERRORS=$((ERRORS + 1))`, or appending `|| true`, each SILENTLY REMOVE the
# rejection for the first error. The tidy-up deletes the only thing making it
# work.
#
# So these tests run the real hook against a throwaway repo and assert on what
# it printed and how far it got -- not merely on its exit status, which was
# right for the wrong reason the whole time. Presence-is-not-behaviour is the
# trap this repo has already paid for (docs/TEST-HARDENING-LOG.md §5.1).

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init
    command -v git >/dev/null 2>&1 || skip "no host git binary"

    # Everything the hook reaches for that would otherwise leave this machine.
    # forbid() stays armed on all of them: a pre-commit hook has no business
    # mutating anything, and if one of these checks ever starts to, the harness
    # says so instead of letting it through.
    stub_ssh    'exit 0'
    stub_curl   'exit 0'
    stub_docker 'exit 0'
    stub_tool dig 'exit 0'

    FX="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$FX/.claude"
    git init -q "$FX"
    git -C "$FX" config user.email t@example.com
    git -C "$FX" config user.name t
    git -C "$FX" config commit.gpgsign false
    # Host hooks off, for the fixture only. `core.hooksPath` can be set globally
    # (this machine sets it), and git then reads hooks from there INSTEAD of
    # .git/hooks -- so the seed commit below ran a style gate that has nothing
    # to do with this repository, failed on the copied scripts/, and left six
    # tests in this file red on that machine while CI stayed green. A test
    # fixture that a contributor's global git config can decide the outcome of
    # is not testing what it says.
    git -C "$FX" config core.hooksPath /dev/null
    cp -r "$REPO_ROOT/scripts" "$FX/scripts"

    # `zqxhost` is deliberately a string that appears NOWHERE in scripts/.
    # An earlier draft used "mynas", which common.sh:? carries as an example in
    # a comment -- so the copied scripts/ tree matched the hostname all by
    # itself and every fixture looked "leaky", clean ones included. An
    # assertion a fixture can satisfy on its own is the trap already recorded
    # in tests/mutation/README.md.
    printf '# Local config\n\nHost: zqxhost.local\nSSH: admin@zqxhost.local\n' \
        > "$FX/.claude/config.local.md"
    # ...and .claude/ is untracked, so the config file is not itself scanned.
    printf '.claude/\n' > "$FX/.gitignore"
    echo "seed" > "$FX/seed.txt"
    git -C "$FX" add -A
    git -C "$FX" commit -qm seed
}

# Stage $2 as $1, for each pair given, then run the real hook.
# Sets: $status, $output, and $checks_run (how many of the 11 printed a header).
run_hook() {
    while [[ $# -gt 0 ]]; do
        printf '%s\n' "$2" > "$FX/$1"
        git -C "$FX" add "$1"
        shift 2
    done
    output="$( cd "$FX" && ./scripts/pre-commit 2>&1 )" && status=0 || status=$?
    checks_run="$( grep -cE '^[0-9]+\. ' <<<"$output" || true )"
}

# A WireGuard key in the env-var spelling check-secrets.sh's pattern 1 actually
# matches, staged under an extension that check ACTUALLY SCANS. Its skip list drops
# *.md outright, so a markdown fixture sails through check 1 reporting "OK" and
# the test would be asserting against a check that never ran.
# Its own `.conf` spelling (`PrivateKey = ...`, spaces round the `=`) does NOT
# match that pattern -- worth knowing before writing a fixture for it.
#
# It is read from tests/fixtures/ rather than written inline, because the check
# under test scans this repo too: an inline copy made check_secrets flag THIS
# FILE, so every later commit here would have been blocked by the test for the
# blocking check. That skip list exempts tests/fixtures/* precisely so that
# intentional fake secrets have somewhere to live -- use it, rather than widening
# the exemption to all bats files and blinding the check to a real key pasted
# into some future test.
secret_line() { cat "$REPO_ROOT/tests/fixtures/fake-wireguard-key.env"; }

@test "pre-commit: a clean tree runs every check and reports PASSED" {
    run_hook clean.md 'nothing interesting here'
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASSED"* ]]
    [ "$checks_run" -eq 11 ]
}

@test "pre-commit: a staged secret is reported by the summary, not by dying" {
    run_hook leaky.conf "$(secret_line)"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Possible WireGuard private key"* ]]
    # The point of the test: it got all the way to the end.
    [ "$checks_run" -eq 11 ]
    [[ "$output" == *"BLOCKED"* ]]
    [[ "$output" == *"1 error(s) found"* ]]
    [[ "$output" == *"--no-verify"* ]]
}

@test "pre-commit: a staged NAS hostname prints WHICH file leaked it" {
    run_hook leaky.md 'deploy to zqxhost tonight'
    [ "$status" -eq 1 ]
    # Currently unreachable: the abort happens at ((hostname_errors++)), which
    # is inside the loop that BUILDS this message, before it is ever echoed.
    [[ "$output" == *"NAS hostname"* ]]
    [[ "$output" == *"leaky.md"* ]]
    [ "$checks_run" -eq 11 ]
    [[ "$output" == *"BLOCKED"* ]]
}

@test "pre-commit: checks after the first failure still run" {
    # Check 5 is the one that aborts mid-library. If the hook survives it,
    # checks 6-11 -- including the BLOCKING check 11 -- report as normal.
    run_hook leaky.md 'deploy to zqxhost tonight'
    [[ "$output" == *"6. "* ]]
    [[ "$output" == *"11. "* ]]
}

@test "pre-commit: two independent errors are counted as two" {
    # The accumulation proof, and the one assertion that cannot be satisfied by
    # a hook that dies at its first finding: reaching "2" requires surviving
    # error #1. A secret (check 1) and a hostname (check 5) are independent
    # failures in different checks.
    run_hook secret.conf "$(secret_line)" host.md 'deploy to zqxhost tonight'
    [ "$status" -eq 1 ]
    [[ "$output" == *"2 error(s) found"* ]]
    [ "$checks_run" -eq 11 ]
}

@test "pre-commit: no check fired a forbidden operation" {
    run_hook clean.md 'nothing interesting here'
    assert_nothing_forbidden
}
