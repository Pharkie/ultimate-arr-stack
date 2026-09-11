#!/usr/bin/env bats
# scripts/boot-compose-up.sh
#
# The @reboot job that reconciles every deployed stack. It exists because a UGOS
# update once left every container running with no published ports -- Pi-hole
# reported healthy while nothing outside could reach it and the whole house lost
# DNS. So the failure mode that matters here is the one where this script runs,
# reports success, and has silently not covered something.
#
# Two things are therefore derived from the repo rather than restated: which
# compose files it brings up, and in what order. Both were wrong in a sibling
# script, and neither is visible in an exit status.
#
# POSIX sh, not bash. The loop is extracted and eval'd for the tests that need a
# clean run -- `docker compose up` is on the stub denylist, so a subprocess run
# can never reach the success path, which is exactly the guarantee wanted for
# every other test in this file.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    SCRIPT="$REPO_ROOT/scripts/boot-compose-up.sh"
    BOOT_LOG="$BATS_TEST_TMPDIR/boot.log"
    BOOT_DOCKER_ROOT="$BATS_TEST_TMPDIR/docker"
    export BOOT_LOG BOOT_DOCKER_ROOT

    # A deploy tree holding exactly the repo's own compose files, so "is every
    # stack reached" is a question about this repo and not about the NAS.
    mkdir -p "$BOOT_DOCKER_ROOT/arr-stack"
    local f
    for f in "$REPO_ROOT"/docker-compose.*.yml; do
        : > "$BOOT_DOCKER_ROOT/arr-stack/$(basename "$f")"
    done

    stub_tool sleep 'exit 0'
    stub_docker 'exit 0'
}

# The stack list, evaluated out of the script itself. A copy here would drift.
stacks() {
    local body
    body=$(awk '/^STACKS="/,/^"$/' "$SCRIPT")
    [ -n "$body" ] || { echo "extracted an empty STACKS block"; return 1; }
    local DOCKER_ROOT="$BOOT_DOCKER_ROOT"
    eval "$body"
    printf '%s\n' $STACKS
}

# The bring-up loop, with docker replaced by a shell function. Used only where
# the success path matters; the PATH stub stays installed underneath, so a
# mutant that escaped the extraction still hits it.
bringup() {
    local body
    body=$(awk '/^failed=""$/,0' "$SCRIPT")
    [ -n "$body" ] || { echo "extracted an empty bring-up block"; return 1; }
    local DOCKER_ROOT="$BOOT_DOCKER_ROOT"
    local STACKS; STACKS=$(stacks)
    eval "$body"
}

@test "boot-compose-up: it writes to the log, not to stdout" {
    run "$SCRIPT"
    [ -z "$output" ] || fail "expected nothing on stdout, got: $output"
    [ -s "$BOOT_LOG" ] || fail "nothing was written to $BOOT_LOG"
    grep -q "boot bring-up" "$BOOT_LOG"
}

@test "boot-compose-up: it waits for docker and records how long" {
    # Cron fires @reboot before dockerd is accepting connections, so this loop
    # is the difference between reconciling the stacks and doing nothing at all.
    local n="$BATS_TEST_TMPDIR/n"
    echo 0 > "$n"
    export N_FILE="$n"
    stub_docker '
if [ "$1" = info ]; then
    n=$(cat "$N_FILE"); n=$((n + 1)); echo "$n" > "$N_FILE"
    [ "$n" -ge 3 ] || exit 1
fi
exit 0
'
    run "$SCRIPT"
    grep -q "docker ready after 10s" "$BOOT_LOG" \
        || fail "expected two 5s waits before ready; log says:"$'\n'"$(cat "$BOOT_LOG")"
}

@test "boot-compose-up: it gives up rather than looping forever" {
    stub_docker '[ "$1" = info ] && exit 1; exit 0'
    run "$SCRIPT"
    assert_failure
    grep -q "docker never became ready" "$BOOT_LOG"
    # And it stopped before touching any stack -- an unreachable daemon must not
    # produce a run that reports every stack as failed.
    assert_stub_not_called docker "compose"
}

@test "boot-compose-up: the give-up budget is the 5 minutes its message claims" {
    # The loop sleeps 5s per attempt and gives up once the counter EXCEEDS 60,
    # so the budget is 61 attempts and 60 sleeps -- the 300s the give-up line
    # names. `-ge 60` is one attempt and 5 seconds short of that, and the window
    # it removes is not hypothetical: cron fires this at @reboot precisely
    # because dockerd is not up yet, so a daemon that becomes ready at 296s gets
    # every stack reconciled by the real script and none by the mutant, with a
    # log line still claiming 5 minutes.
    stub_docker '[ "$1" = info ] && exit 1; exit 0'
    run "$SCRIPT"
    assert_failure
    local attempts sleeps
    attempts=$(grep -c '^docker'$'\t''info' "$STUB_LOG")
    sleeps=$(grep -c '^sleep'$'\t' "$STUB_LOG")
    [ "$attempts" -eq 61 ] || fail "docker info was tried $attempts times, not 61"
    [ "$sleeps" -eq 60 ] || fail "the wait loop slept $sleeps times, not 60"
}

@test "boot-compose-up: an oversized log is trimmed to its last 500 lines" {
    # No logrotate on this NAS, so an untrimmed log grows until the volume does
    # not. The trim must also not leave its own .tmp behind on every run.
    local i
    for i in $(seq 1 2000); do
        printf '%d %s\n' "$i" "$(head -c 600 < /dev/zero | tr '\0' 'x')"
    done > "$BOOT_LOG"
    [ "$(wc -c < "$BOOT_LOG")" -gt 1000000 ] || skip "fixture is not big enough to trigger the trim"

    run "$SCRIPT"
    [ "$(head -1 "$BOOT_LOG" | cut -d' ' -f1)" = "1501" ] \
        || fail "expected the trim to keep lines 1501-2000, log starts: $(head -1 "$BOOT_LOG" | cut -c1-20)"
    [ ! -e "$BOOT_LOG.tmp" ] || fail "the trim left $BOOT_LOG.tmp behind"
}

@test "boot-compose-up: a log of exactly the limit is left alone" {
    # `-gt 1000000`, not `-ge`: the trim is for a log that has outgrown its
    # bound, and a file sitting exactly on the bound has not. Bend it to `-ge`
    # and this fixture is rewritten to its last 500 lines -- the oldest entries
    # dropped by an inclusive comparison, in a file whose entire purpose is to
    # still hold the reboot someone is asking about.
    local i
    { printf 'ANCIENT FIRST LINE\n'
      for i in $(seq 1 998); do
          printf '%s %s\n' "$i" "$(head -c 900 < /dev/zero | tr '\0' 'x')"
      done
    } > "$BOOT_LOG"
    local pad
    pad=$((1000000 - $(wc -c < "$BOOT_LOG") - 1))
    [ "$pad" -gt 0 ] || skip "the fixture overshot the limit before padding"
    { head -c "$pad" < /dev/zero | tr '\0' 'x'; printf '\n'; } >> "$BOOT_LOG"
    [ "$(wc -c < "$BOOT_LOG")" -eq 1000000 ] || skip "could not build a 1000000-byte fixture"

    run "$SCRIPT"
    [ "$(head -1 "$BOOT_LOG")" = "ANCIENT FIRST LINE" ] \
        || fail "a log of exactly 1000000 bytes was trimmed; the guard is -gt, not -ge"
}

@test "boot-compose-up: a log under the limit is left alone" {
    printf 'keep me\n' > "$BOOT_LOG"
    run "$SCRIPT"
    [ "$(head -1 "$BOOT_LOG")" = "keep me" ] || fail "a small log was trimmed"
}

@test "boot-compose-up: every compose file in this repo is in STACKS" {
    # Derived, because this is the failure the script cannot report: a stack it
    # never brings up produces no error, no FAILED line, and a log that ends
    # "finished clean". docker-compose.magnetio.yml was missing from this list
    # from the day it was added until 2026-09-01 for exactly that reason.
    local f
    for f in "$REPO_ROOT"/docker-compose.*.yml; do
        f=$(basename "$f")
        stacks | grep -qxF -- "$BOOT_DOCKER_ROOT/arr-stack/$f" \
            || fail "$f is not in STACKS; boot would never bring it up"
    done
}

@test "boot-compose-up: STACKS orders network owners before their consumers" {
    # Same dependency order as restart-stack.sh's `all` arm, and derived the same
    # way: arr-stack.yml CREATES arr-core, everything else declares it external.
    local list creator_line f consumer_line
    list=$(stacks)
    creator_line=$(printf '%s\n' "$list" | grep -n 'docker-compose.arr-stack.yml$' | cut -d: -f1)
    [ -n "$creator_line" ] || fail "arr-stack is not in STACKS at all"

    for f in "$REPO_ROOT"/docker-compose.*.yml; do
        f=$(basename "$f")
        awk '/^networks:/,0' "$REPO_ROOT/$f" | grep -A1 '^  arr-core:' \
            | grep -q 'external: true' || continue
        consumer_line=$(printf '%s\n' "$list" | grep -n "$f\$" | cut -d: -f1)
        [ -n "$consumer_line" ] || continue
        [ "$consumer_line" -gt "$creator_line" ] \
            || fail "$f declares arr-core external but boot brings it up before arr-stack, which creates it"
    done
}

@test "boot-compose-up: magnetio comes up before arr-stack" {
    # arr-stack.yml declares magnetio-net external and gluetun joins it.
    grep -qE '^  magnetio-net:' "$REPO_ROOT/docker-compose.arr-stack.yml" \
        || skip "arr-stack.yml no longer references magnetio-net"
    local list m a
    list=$(stacks)
    m=$(printf '%s\n' "$list" | grep -n 'docker-compose.magnetio.yml$' | cut -d: -f1)
    a=$(printf '%s\n' "$list" | grep -n 'docker-compose.arr-stack.yml$' | cut -d: -f1)
    [ -n "$m" ] && [ -n "$a" ] || fail "STACKS is missing magnetio or arr-stack"
    [ "$m" -lt "$a" ] || fail "magnetio (position $m) must precede arr-stack (position $a)"
}

@test "boot-compose-up: it reaches every stack that exists, in list order" {
    run "$SCRIPT"
    local expected actual
    expected=$(stacks | while read -r f; do
        # `if`, not `[ ] &&` -- a false test on the LAST line makes the whole
        # command substitution exit non-zero, and bats runs with set -e.
        if [ -f "$f" ]; then printf 'compose -f %s up -d\n' "$(basename "$f")"; fi
    done)
    actual=$(grep '^docker'$'\t' "$STUB_LOG" | cut -f2- | grep '^compose ')
    [ "$expected" = "$actual" ] || fail "wrong stacks or wrong order:"$'\n'"--- expected ---"$'\n'"$expected"$'\n'"--- actual ---"$'\n'"$actual"
}

@test "boot-compose-up: a missing stack is skipped, not fatal" {
    # frigate/immich/therapy-stack are other deployments that may not be on this
    # NAS at all. CLAUDE.md records therapy-stack as verified absent.
    docker() { return 0; }
    run bringup
    assert_success
    assert_output --partial "SKIP (missing):"
    assert_output --partial "finished clean"
}

@test "boot-compose-up: one failing stack does not stop the rest" {
    # DNS matters more than Immich. If a failure aborted the loop, a single bad
    # stack early in the list would leave the whole NAS unreconciled after a
    # reboot -- the exact condition this script was written to fix.
    docker() { case "$*" in *arr-stack*) return 1 ;; *) return 0 ;; esac; }
    run bringup
    assert_failure
    assert_output --partial "FAILED:"
    assert_output --partial "docker-compose.arr-stack.yml"
    assert_output --partial "finished WITH FAILURES"
    # The stacks after the failing one still ran.
    assert_output --partial "docker-compose.cloudflared.yml"
}

@test "boot-compose-up: a clean run says so and exits 0" {
    docker() { return 0; }
    run bringup
    assert_success
    assert_output --partial "finished clean"
    refute_output --partial "FAILED"
}

@test "boot-compose-up: --remove-orphans and 'down' never appear in any argv" {
    # The stack's services are split across compose files sharing one project
    # name, so every container from the other files looks like an orphan to each
    # individual file. --remove-orphans took out 11 containers on 2026-08-01.
    run "$SCRIPT"
    # Two arguments, not three. As `assert_stub_not_called docker -- "--remove-orphans"`
    # this passed `--` as the pattern and dropped the flag it names: the helper
    # takes (tool, pattern), so the search was for a bare `--` and would have
    # fired on any legitimate one. It still went red against its corpus entry,
    # because `--` is a substring of `--remove-orphans` -- a wrong-reason
    # assertion hiding inside a right-reason failure.
    assert_stub_not_called docker "--remove-orphans"
    assert_stub_not_called docker "down"
}
