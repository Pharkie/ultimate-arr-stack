#!/usr/bin/env bats
# scripts/restart-stack.sh, and the proof that the harness guarding it works.
#
# Every path through this script ends in `docker compose ... up -d
# --force-recreate` against the live stack. On the NAS that is Pi-hole, Traefik
# and the VPN tunnel going down and back up. It is the single most destructive
# script in the repo to drive from a test, which makes it the right one to
# prove the safety harness against: if forbid() can stop THIS, the rest of
# Phase 3 is safe to write.
#
# The first five tests are that proof and touch no production code: the harness
# had to be trustworthy BEFORE anything was refactored on the strength of it.
#
# The dispatcher's own behaviour - aliases, the ${1:-all} default, the file
# mapping, the dependency ordering of the `all` arm - cannot be observed through
# those, because forbid() kills the script at its FIRST compose call and `all`
# has five. So the second half extracts the `case` block with awk and evals it
# with restart_compose overridden, which is this repo's existing idiom for
# reaching a unit that a real run would never return from
# (backup-volume-resolution.bats). The docker stub stays installed underneath:
# if the extraction were ever wrong and a real call escaped, the harness is
# still there to make it a loud failure rather than a live restart.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init
    # If this ever runs for real, the test has already failed - but say so
    # loudly rather than silently succeeding at a live restart.
    stub_docker 'echo "STUB RAN A REAL DOCKER COMMAND" >&2; exit 1'

    # Set HERE and not inside dispatch(): every caller below invokes dispatch
    # through `run`, which is a subshell, so an assignment made inside it would
    # die before the assertion could read it.
    CALLS="$BATS_TEST_TMPDIR/calls"
}

@test "restart-stack: the harness stops 'all' before it reaches a live restart" {
    run "$REPO_ROOT/scripts/restart-stack.sh" all
    assert_forbidden "verb: compose up"
    [ "$status" -eq 99 ]
}

@test "restart-stack: the harness stops the default (no argument) invocation" {
    # ${1:-all} means a bare call is the widest possible blast radius.
    run "$REPO_ROOT/scripts/restart-stack.sh"
    assert_forbidden "verb: compose up"
    [ "$status" -eq 99 ]
}

@test "restart-stack: the harness stops each individual stack target" {
    for target in arr traefik cloudflared utilities magnetio; do
        rm -f "$STUB_FORBIDDEN"
        run "$REPO_ROOT/scripts/restart-stack.sh" "$target"
        [ "$status" -eq 99 ] || { echo "target '$target' exited $status, not 99"; return 1; }
        assert_forbidden "verb: compose up" || return 1
    done
}

@test "restart-stack: an unknown target never reaches docker at all" {
    # The usage arm is the one path with no side effect, so it is the one arm
    # that can be asserted positively rather than by interception.
    run "$REPO_ROOT/scripts/restart-stack.sh" nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
    assert_nothing_forbidden
    [ ! -s "$STUB_LOG" ]
}

@test "restart-stack: 'down' is never in the argv on any path" {
    # The script's header states this as its reason to exist: `down` kills
    # Pi-hole and takes the house's DNS with it. Assert it on the argv that was
    # actually built, not on the text of the file - a comment cannot regress,
    # and a grep of the source would pass on a script that never ran.
    for target in all arr traefik cloudflared utilities magnetio; do
        run "$REPO_ROOT/scripts/restart-stack.sh" "$target"
    done
    run grep -c 'down' "$STUB_LOG"
    [ "$output" = "0" ]
}

@test "restart-stack: --remove-orphans is never in the argv, --force-recreate always is" {
    # --remove-orphans is the single most expensive flag anyone can add to this
    # file. The stack's services are split across compose files sharing one
    # project name, so compose treats every container from the OTHER files as an
    # orphan and deletes them -- it took out 11 containers on 2026-08-01.
    #
    # The stub logs the argv before the guard exits, so one forbidden call per
    # run still yields the argv it was about to make.
    for target in all arr traefik cloudflared utilities magnetio; do
        run "$REPO_ROOT/scripts/restart-stack.sh" "$target"
    done
    [ "$(grep -c -- '--remove-orphans' "$STUB_LOG")" -eq 0 ]
    [ "$(grep -c -- '--force-recreate' "$STUB_LOG")" -eq 6 ]
}

@test "restart-stack: each target hands compose its own file, with -f" {
    # `-f` is the flag that makes the path mean anything. `docker compose -e
    # <file>` is not a flag docker has -- measured against docker 29.6.2, the
    # CLI exits 1 with "unknown shorthand flag: 'e' in -e" before it selects
    # anything -- and under `set -e` that aborts the `all` arm at its FIRST
    # file. So a typo here is not a broken restart, it is no restart at all, on
    # the command someone reaches for when the house has no DNS.
    #
    # Nothing looked at the flag before. forbid() stops the script at its first
    # compose call, and every dispatcher test above reads $CALLS from an
    # overridden restart_compose, so the argv docker was actually handed was
    # only ever grepped for --force-recreate, `down` and --remove-orphans. A
    # flag can rot in there unnoticed.
    while read -r target file; do
        : > "$STUB_LOG"
        rm -f "$STUB_FORBIDDEN"
        run "$REPO_ROOT/scripts/restart-stack.sh" "$target"
        [ "$status" -eq 99 ] || { echo "target '$target' exited $status, not 99"; return 1; }
        assert_forbidden "verb: compose up" || return 1
        assert_stub_called docker "-f $file" || return 1
    done <<'MAP'
arr docker-compose.arr-stack.yml
traefik docker-compose.traefik.yml
cloudflared docker-compose.cloudflared.yml
utilities docker-compose.utilities.yml
magnetio docker-compose.magnetio.yml
MAP
}

@test "restart-stack: a failure is reported on stderr, not on stdout" {
    # The FAILED line is the operator-facing signal that a stack did not come
    # back, and it is the one line of this script's output that is not compose's
    # own text. On stdout it is indistinguishable from the output of the command
    # the operator is running, and it disappears into anything that captured the
    # run -- `./scripts/restart-stack.sh all >/tmp/restart.log` would show the
    # failure only if someone reads the log. `run` merges the two streams by
    # default, which is why nothing here noticed: the streams have to be split
    # deliberately to see it.
    local out="$BATS_TEST_TMPDIR/out" err="$BATS_TEST_TMPDIR/err"
    run bash -c '"$1" arr >"$2" 2>"$3"' _ "$REPO_ROOT/scripts/restart-stack.sh" "$out" "$err"
    [ "$status" -eq 99 ]
    grep -q "arr-stack FAILED (exit 99)" "$err" \
        || fail "the failure line is not on stderr; stderr held:"$'\n'"$(cat "$err")"
    ! grep -q "FAILED" "$out" \
        || fail "the failure line is on stdout:"$'\n'"$(cat "$out")"
}

# Evaluate the real `case` block with restart_compose replaced by a logger.
# The extracted text is the file's own, so a change to the dispatcher is
# reflected here without the test being edited - and a change that breaks the
# extraction shows up as a zero-length body, which every test below would fail.
dispatch() {
    : > "$CALLS"
    restart_compose() { printf '%s %s\n' "$1" "$2" >> "$CALLS"; }
    local body
    body=$(awk '/^case /,/^esac$/' "$REPO_ROOT/scripts/restart-stack.sh")
    [ -n "$body" ] || { echo "extracted an empty case block"; return 1; }
    eval "$body"
}

@test "restart-stack: each alias maps to the compose file that defines it" {
    # Not cosmetic. CLAUDE.md's rule is that a service is only ever recreated
    # through the compose file that defines it -- traefik brought up through any
    # other loses its traefik-lan macvlan and every .lan URL in the house dies.
    while read -r target file name; do
        run dispatch "$target"
        assert_success
        assert_equal "$(cat "$CALLS")" "$file $name"
    done <<'MAP'
arr docker-compose.arr-stack.yml arr-stack
arr-stack docker-compose.arr-stack.yml arr-stack
traefik docker-compose.traefik.yml traefik
cloudflared docker-compose.cloudflared.yml cloudflared
tunnel docker-compose.cloudflared.yml cloudflared
utilities docker-compose.utilities.yml utilities
utils docker-compose.utilities.yml utilities
magnetio docker-compose.magnetio.yml magnetio
MAP
}

@test "restart-stack: no argument is the same as 'all'" {
    run dispatch
    assert_success
    local bare; bare=$(cat "$CALLS")
    run dispatch all
    assert_success
    assert_equal "$bare" "$(cat "$CALLS")"
}

@test "restart-stack: the 'all' order matches the compose files' own dependencies" {
    # Derived from the compose files rather than restated, because the version of
    # this test written on 2026-09-01 pinned the order the script happened to
    # ship with and wrote an inverted rationale under it -- "the networks
    # arr-stack attaches to are defined by traefik's file", which is backwards.
    # arr-stack.yml CREATES arr-core; traefik.yml, cloudflared.yml and
    # utilities.yml all declare it `external: true`. A test that reads that off
    # the files cannot get the direction wrong twice.
    run dispatch all
    assert_success

    local creator="docker-compose.arr-stack.yml"
    grep -qE '^  arr-core:' "$REPO_ROOT/$creator" \
        || fail "$creator no longer declares arr-core; this test's premise is stale"

    local creator_line f consumer_line
    creator_line=$(grep -n "^$creator " "$CALLS" | cut -d: -f1)
    [ -n "$creator_line" ] || fail "the all arm never restarted $creator"

    for f in "$REPO_ROOT"/docker-compose.*.yml; do
        f=$(basename "$f")
        [ "$f" = "$creator" ] && continue
        # Only the files that consume arr-core as external.
        awk '/^networks:/,0' "$REPO_ROOT/$f" | grep -A1 '^  arr-core:' \
            | grep -q 'external: true' || continue
        consumer_line=$(grep -n "^$f " "$CALLS" | cut -d: -f1)
        [ -n "$consumer_line" ] || continue   # not in the all arm at all
        [ "$consumer_line" -gt "$creator_line" ] \
            || fail "$f declares arr-core external but is restarted before $creator, which creates it"
    done
}

@test "restart-stack: magnetio comes up before arr-stack" {
    # docker-compose.arr-stack.yml declares magnetio-net `external: true` and
    # says so in a comment: gluetun joins it, and recreating gluetun without it
    # fails with "network not found". Under set -e that aborts the run before
    # anything else, so the file that owns DNS never comes up.
    run dispatch all
    assert_success
    grep -qE '^  magnetio-net:' "$REPO_ROOT/docker-compose.arr-stack.yml" \
        || skip "arr-stack.yml no longer references magnetio-net"
    local m a
    m=$(grep -n '^docker-compose.magnetio.yml ' "$CALLS" | cut -d: -f1)
    a=$(grep -n '^docker-compose.arr-stack.yml ' "$CALLS" | cut -d: -f1)
    [ -n "$m" ] && [ -n "$a" ] || fail "the all arm is missing magnetio or arr-stack"
    [ "$m" -lt "$a" ] || fail "magnetio (line $m) must precede arr-stack (line $a)"
}

@test "restart-stack: 'all' covers every compose file except the ones it names" {
    # Derived from the filesystem, not restated. A new docker-compose.*.yml
    # fails this test until someone decides whether `all` should bring it up --
    # which is the decision that was silently skipped when magnetio was added
    # and `all` went on claiming to restart "all compose files" while covering
    # four of six.
    #
    # docker-compose.tailscale.yml is excluded on purpose and the reason is the
    # sharpest one in this repo: recreating Tailscale node 1 severs SSH and the
    # UGOS UI at the same instant, because both ride its own subnet route. The
    # command that would undo it arrives over the link it just cut.
    local -a excluded=(docker-compose.tailscale.yml)
    run dispatch all
    assert_success

    local f base
    for f in "$REPO_ROOT"/docker-compose*.yml; do
        base=$(basename "$f")
        case " ${excluded[*]} " in *" $base "*) continue ;; esac
        grep -qF "$base" "$CALLS" || {
            echo "'all' never restarts $base, and it is not on the excluded list"
            cat "$CALLS"
            return 1
        }
    done
}

@test "restart-stack: 'all' does not restart tailscale" {
    # The positive half of the rule above. Without it, the excluded list could
    # be emptied and the coverage test would still pass.
    run dispatch all
    assert_success
    refute_output --partial "tailscale"
    ! grep -qF "docker-compose.tailscale.yml" "$CALLS"
}

@test "restart-stack: an unknown target prints usage and restarts nothing" {
    run dispatch nonsense
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
    [ ! -s "$CALLS" ]
}

@test "restart-stack: the usage line names every target the dispatcher accepts" {
    # A usage string is documentation that sits inside the code it documents,
    # which is exactly the kind that goes stale silently -- magnetio was added
    # to this file and the usage line was not updated in the same edit.
    run dispatch nonsense
    for target in arr traefik cloudflared utilities magnetio all; do
        [[ "$output" == *"$target"* ]] || {
            echo "usage line never mentions '$target': $output"; return 1
        }
    done
}

# restart_compose itself, extracted from the file and eval'd with docker
# replaced by a shell function. Same idiom as dispatch() above, for the other
# half of the function: forbid() kills the script at its FIRST compose call, so
# every test that runs the real script sees only the argv that was refused and
# nothing downstream of it -- which is where the captured output is printed and
# where the success line is written. The PATH stub stays installed underneath,
# so an extraction that went wrong still cannot reach a live daemon.
restart_one() {
    local body
    body=$(awk '/^restart_compose\(\) \{/,/^\}$/' "$REPO_ROOT/scripts/restart-stack.sh")
    [ -n "$body" ] || { echo "extracted an empty restart_compose"; return 1; }
    eval "$body"
    restart_compose "$@"
}

@test "restart-stack: compose's own output is printed when there is any" {
    # The output is captured rather than streamed so the "restarted" line can be
    # conditional on what compose said, and printing it is the whole point of
    # holding it. The guard on that print is `[ -n "$out" ]`; inverted, a stack
    # that fails reports "FAILED (exit 1)" with no cause anywhere in the run's
    # output, and the script prints a blank line instead on the stacks that
    # produced nothing to say.
    #
    # Both of compose's streams matter here: the call captures 2>&1, so what
    # reaches the operator is whatever docker wrote, warning or error alike.
    docker() { printf 'Container pihole  Started\n'; printf 'compose wrote this to stderr\n' >&2; return 0; }
    run restart_one docker-compose.arr-stack.yml arr-stack
    assert_success
    assert_output --partial "Container pihole  Started"
    assert_output --partial "compose wrote this to stderr"
}

@test "restart-stack: a stack with no service selected is skipped, not reported as restarted" {
    # The branch nothing drove until now. compose exits 0 having selected nothing
    # when every service in the file sits behind a profile an operator has not
    # enabled, which is cloudflared's state until they do; restart_compose's own
    # comment says why reporting that as a restart is the false-success shape this
    # repo keeps finding in its guards. Every other test in this file either
    # stops at forbid() or replaces restart_compose with the dispatcher's logger,
    # so deleting the branch was invisible to the suite.
    #
    # The second half is the negative control, and it is not decoration: a branch
    # that fired unconditionally would print "skipped" for every stack, restart
    # nothing, and pass the assertions above. One test asserts both directions so
    # that a green run cannot mean either.
    docker() { printf 'no service selected\n'; return 0; }
    run restart_one docker-compose.cloudflared.yml cloudflared
    assert_success
    assert_output --partial "skipped - opt-in profile not enabled"
    refute_output --partial "restarted"

    docker() { printf 'Container pihole  Started\n'; return 0; }
    run restart_one docker-compose.arr-stack.yml arr-stack
    assert_success
    assert_output --partial "restarted"
    refute_output --partial "skipped"
}
