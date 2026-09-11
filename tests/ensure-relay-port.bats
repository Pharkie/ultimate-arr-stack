#!/usr/bin/env bats
# scripts/ensure-tailscale-relay-port.sh
#
# This script's whole job is a decision: does node 1's RelayServerPort already
# read 41641, or does `tailscale set` have to run again. Everything else is one
# line either way, so the decision is what these tests pin -- against every JSON
# shape the script's own L43-55 comment claims to survive, in BOTH directions.
#
# One direction is easy to get wrong and impossible to notice: a pattern that
# never matches makes the script re-apply on every timer tick forever, which
# LOOKS fine (the port ends up correct) and means the "already correct" branch
# is dead. So each shape is asserted as either "recognised" or "not recognised",
# never merely "the script exited 0".
#
# Nothing here can reach a live Tailscale. `tailscale set` is on the stub
# harness's denylist, so the re-apply path is observed as a forbid() trip at
# status 99 rather than by letting the call through -- node 1 carries SSH and
# the UGOS admin UI, and it is not a thing to touch from a test.

# `run --separate-stderr` is a 1.5.0 feature, and the stderr test at the bottom
# needs it: `run` on its own merges the two streams, which is what let a `>&2`
# be deleted here without a single test going red.
bats_require_minimum_version 1.5.0

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    SCRIPT="$REPO_ROOT/scripts/ensure-tailscale-relay-port.sh"
    RUNNING="$BATS_TEST_TMPDIR/running"
    PREFS="$BATS_TEST_TMPDIR/prefs"
    export RUNNING PREFS
    echo true > "$RUNNING"

    # One dispatching stub for both docker calls. `docker exec ... tailscale set`
    # is deliberately NOT handled: it trips forbid() before this body ever runs.
    stub_docker '
case "$*" in
    "inspect -f {{.State.Running}} tailscale") cat "$RUNNING" ;;
    "exec tailscale tailscale debug prefs")    cat "$PREFS" ;;
    *) echo "unexpected docker argv: $*" >&2; exit 125 ;;
esac
'
}

# Assert the script READ the given prefs as already-correct: exit 0, the OK
# line, and -- the part that matters -- no attempt to re-apply.
assert_recognised() {
    printf '%s\n' "$1" > "$PREFS"
    run "$SCRIPT"
    assert_success
    assert_output --partial "already 41641"
    assert_nothing_forbidden
    assert_stub_not_called docker "tailscale set"
}

# Assert the script did NOT read it as correct, and went to re-apply.
#
# The assertion is the BREADCRUMB, not the status. forbid() exits 99, but this
# script calls `tailscale set` as an `if` condition, so it catches that 99 and
# turns it into its own exit 1 -- the swallowed-status case stubs.bash warns
# about, met for real here. A bare assert_failure would also pass on the wrong
# path, since exit 1 is this script's genuine "the re-apply failed" answer, so
# the decision is read from the argv that was attempted plus the line printed
# before attempting it.
assert_not_recognised() {
    printf '%s\n' "$1" > "$PREFS"
    run "$SCRIPT"
    assert_output --partial "missing or wrong - re-applying"
    assert_forbidden "tailscale set"
}

@test "ensure-relay-port: the shipped JSON shape is recognised" {
    assert_recognised '    "RelayServerPort": 41641,'
}

@test "ensure-relay-port: no trailing comma is recognised" {
    assert_recognised '    "RelayServerPort": 41641'
}

@test "ensure-relay-port: no space after the colon is recognised" {
    assert_recognised '    "RelayServerPort":41641'
}

@test "ensure-relay-port: space BEFORE the colon is recognised" {
    # Was not, until 2026-09-01. The comment above the pipeline claimed
    # robustness to "extra whitespace" while allowing it on one side only.
    assert_recognised '    "RelayServerPort" : 41641,'
}

@test "ensure-relay-port: a quoted value is recognised" {
    # Also was not. If tailscale ever emitted this as a JSON string the script
    # would have re-applied a value that was already correct, on every tick,
    # forever, while printing "missing or wrong" each time.
    assert_recognised '    "RelayServerPort": "41641",'
}

@test "ensure-relay-port: a wrong port is not recognised" {
    assert_not_recognised '    "RelayServerPort": 3,'
}

@test "ensure-relay-port: a null value is not recognised" {
    assert_not_recognised '    "RelayServerPort": null,'
}

@test "ensure-relay-port: the key absent entirely is not recognised" {
    # The actual state on this NAS after any node-1 restart: the pref lives in
    # tailscaled's memory and never reaches tailscaled.state, so it comes back
    # with the key simply gone.
    assert_not_recognised '    "WantRunning": true,'
}

@test "ensure-relay-port: a different key ENDING in RelayServerPort is not read as this one" {
    # The pattern is unanchored, so the leading quote is the only thing keeping
    # a longer key out. Worth an assertion rather than a reading, because the
    # failure would be a false OK -- the one direction that leaves the port
    # actually wrong while the script reports success.
    assert_not_recognised '    "NoRelayServerPort": 41641,'
}

@test "ensure-relay-port: PINNED - a value on its own line reads as missing" {
    # Not fixed, and deliberately so: grep is line-oriented, and making this
    # work means parsing JSON in a script whose entire value is that it has no
    # dependencies. It fails safe -- an unnecessary re-apply of a value that is
    # already correct is a no-op -- and this test exists so that stays a known
    # limit rather than a surprise.
    printf '  "RelayServerPort":\n    41641,\n' > "$PREFS"
    run "$SCRIPT"
    assert_output --partial "missing or wrong - re-applying"
    assert_forbidden "tailscale set"
}

@test "ensure-relay-port: a stopped container is skipped, not an error" {
    echo false > "$RUNNING"
    run "$SCRIPT"
    assert_success
    assert_output --partial "not running"
    assert_nothing_forbidden
    # The point of the skip: it must not go on to interrogate a container that
    # isn't there. Exit 0 alone would pass even if it had.
    assert_stub_not_called docker "debug prefs"
}

@test "ensure-relay-port: a missing container is skipped, not an error" {
    # docker inspect writes to stderr and prints nothing; the timer retries.
    stub_docker 'exit 1'
    run "$SCRIPT"
    assert_success
    assert_output --partial "not running"
}

@test "ensure-relay-port: it only ever asks for node 1, never the exit node" {
    # The relay-port re-apply is aimed at node 1 only, never the Tailscale
    # exit-node role (now arr-stack-router, previously the decommissioned
    # tailscale-exit container). A stray container name here would be
    # invisible in the exit status.
    printf '%s\n' '    "RelayServerPort": 41641,' > "$PREFS"
    run "$SCRIPT"
    assert_success
    assert_stub_not_called docker "tailscale-exit"
}

@test "ensure-relay-port: a successful re-apply exits 0" {
    # The re-apply tail, evaluated with docker overridden by a shell function so
    # the two exit paths are reachable at all -- the PATH stub cannot get here,
    # forbid() stops it first, which is the correct behaviour for every other
    # test in this file and useless for this one. The fatal stub stays installed
    # underneath: a mutant that escaped the extraction still hits it.
    docker() { return 0; }
    run reapply_tail
    assert_success
    assert_output --partial "re-applied successfully"
}

@test "ensure-relay-port: a failed re-apply exits 1 and says so on stderr" {
    docker() { return 7; }
    run reapply_tail
    [ "$status" -eq 1 ]
    assert_output --partial "FAILED to re-apply"
}

@test "ensure-relay-port: the FAILED line is on stderr and not on stdout" {
    # The test above is named for the stream and cannot see it: `run` merges
    # stdout and stderr into $output, so it passes identically with and without
    # the `>&2` on that echo. Every other line this script prints goes to
    # stdout, so the failure line is the only thing that separates "the timer
    # did its job" from the one failure it can report, for any caller that
    # reads the streams separately -- `out=$(...)`, `2>/dev/null`, or a
    # `| logger` on stdout alone all lose the message if it moves.
    docker() { return 7; }
    run --separate-stderr reapply_tail
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"FAILED to re-apply"* ]]
    [[ "$output" != *"FAILED to re-apply"* ]]
}

reapply_tail() {
    local body
    body=$(awk '/^if docker exec tailscale tailscale set/,/^fi$/' "$SCRIPT")
    [ -n "$body" ] || { echo "extracted an empty re-apply block"; return 1; }
    RELAY_PORT=41641
    eval "$body"
}
