#!/usr/bin/env bats
# duc-service/app/{scan,manual_scan,startup}.sh and manual_scan.cgi.
#
# These four files are a single protocol, not four scripts, and testing any one
# of them alone leaves the interesting half unobserved:
#
#   manual_scan.cgi  PRODUCES a request marker (or declines to)
#   manual_scan.sh   CONSUMES it, once a minute, from cron
#   scan.sh          holds the lock the other two branch on
#   startup.sh       writes the crontab that runs the poller at all
#
# The race that used to lose a user's manual scan request lives in the seam
# between the producer and the consumer, so both halves are driven here.
#
# Everything runs against a throwaway tree via the DUC_* seams. They exist only
# for this file: the image sets none of them, so the container runs the same
# absolute paths that used to be hardcoded.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    APP="$REPO_ROOT/duc-service/app"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"

    export DUC_LOG_FILE="$WORK/duc.log"
    export DUC_LOCK_DIR="$WORK/scan.lock"
    export DUC_REQUEST_DIR="$WORK/scan_requested"
    export DUC_SCAN_ROOT="$WORK/scan"
    export DUC_SCAN_SH="$APP/scan.sh"
    export DUC_CRON_FILE="$WORK/duc-index.cron"
    export DUC_MANUAL_SCAN_SH="/manual_scan.sh"
    mkdir -p "$DUC_SCAN_ROOT"

    # `duc` resolved through PATH rather than by absolute path, so the stub is
    # reachable at all. DUC_RC is how a test decides whether the index succeeds.
    export DUC_BIN=duc
    export DUC_RC_FILE="$WORK/duc.rc"
    echo 0 > "$DUC_RC_FILE"
    stub_tool duc '
        echo "duc stub: $*"
        exit "$(cat "$DUC_RC_FILE")"
    '
}

duc_fails_with() { echo "$1" > "$DUC_RC_FILE"; }

# --- scan.sh ---------------------------------------------------------------

@test "duc: scan.sh indexes the scan root and logs both ends" {
    run "$APP/scan.sh"
    assert_success
    assert_output --partial "Start of scan:"
    assert_output --partial "duc stub: index --progress $DUC_SCAN_ROOT"
    assert_output --partial "End of scan:"
    assert_output --partial "(exit code: 0)"
}

@test "duc: scan.sh appends to the log rather than replacing it" {
    echo "an earlier run" > "$DUC_LOG_FILE"
    run "$APP/scan.sh"
    assert_success
    run cat "$DUC_LOG_FILE"
    assert_output --partial "an earlier run"
    assert_output --partial "End of scan:"
}

@test "duc: scan.sh releases the lock when it finishes" {
    run "$APP/scan.sh"
    assert_success
    [ ! -d "$DUC_LOCK_DIR" ] || fail "the lock survived a completed scan"
}

@test "duc: scan.sh does not index while another scan holds the lock" {
    mkdir -p "$DUC_LOCK_DIR"
    run "$APP/scan.sh"
    [ "$status" -eq 75 ] || fail "expected the reserved already-running status 75, got $status"
    assert_stub_not_called duc "index"
}

@test "duc: a held lock is left alone, not removed by the run that could not take it" {
    # The EXIT trap removes the lock dir. If it were armed before the mkdir
    # succeeded, a second invocation would delete a running scan's lock on its
    # way out and let a third one start concurrently.
    mkdir -p "$DUC_LOCK_DIR"
    run "$APP/scan.sh"
    [ "$status" -eq 75 ]
    [ -d "$DUC_LOCK_DIR" ] || fail "a rejected invocation deleted the running scan's lock"
}

@test "duc: a failing index still logs the end of the scan and its exit code" {
    # The defect this pins: the block runs in a pipeline subshell that inherits
    # set -e, so a failing duc used to kill it on the spot. The status still
    # propagated via PIPESTATUS - which is exactly why nobody noticed that the
    # log just stopped, with no indication anything had gone wrong.
    duc_fails_with 3
    run "$APP/scan.sh"
    [ "$status" -eq 3 ] || fail "expected duc's own status 3, got $status"
    assert_output --partial "End of scan:"
    assert_output --partial "(exit code: 3)"
}

@test "duc: a failing index is recorded in the log file, not only on stdout" {
    duc_fails_with 4
    run "$APP/scan.sh"
    [ "$status" -eq 4 ]
    run cat "$DUC_LOG_FILE"
    assert_output --partial "(exit code: 4)"
}

@test "duc: a scan whose log cannot be written is not reported as a success" {
    # The log is the only record a scan leaves behind, and tee failing means
    # there is none. errexit is what turns that into a non-zero exit: pipefail
    # carries tee's failure out of the pipeline and errexit exits on it, before
    # the script reaches the explicit `exit "${PIPESTATUS[0]}"` below - which
    # reads the INDEX's status, 0 here, and would report a scan that recorded
    # nothing as a success. That pipeline is the only unguarded command in the
    # file, so a tee that cannot open its log is the one way this shows.
    #
    # A directory at the log path provokes it without depending on the uid the
    # suite runs as: tee cannot open a directory for appending, whoever it is.
    rm -f "$DUC_LOG_FILE"
    mkdir -p "$DUC_LOG_FILE"
    run "$APP/scan.sh"
    assert_stub_called duc "index"
    assert_failure
}

@test "duc: scan.sh reports the index's status, not tee's" {
    duc_fails_with 1
    run "$APP/scan.sh"
    [ "$status" -eq 1 ] || fail "tee's success masked the index failure (status $status)"
}

@test "duc: scan.sh releases the lock even when the index fails" {
    duc_fails_with 2
    run "$APP/scan.sh"
    [ "$status" -eq 2 ]
    [ ! -d "$DUC_LOCK_DIR" ] || fail "a failed scan left the lock behind, blocking every later scan"
}

# --- manual_scan.sh (the consumer) -----------------------------------------

@test "duc: the poller does nothing when no scan has been requested" {
    run "$APP/manual_scan.sh"
    assert_success
    assert_stub_not_called duc "index"
}

@test "duc: a requested scan runs and clears the request" {
    mkdir -p "$DUC_REQUEST_DIR"
    run "$APP/manual_scan.sh"
    assert_success
    assert_stub_called duc "index"
    [ ! -d "$DUC_REQUEST_DIR" ] || fail "the request survived a completed scan and would run again"
}

@test "duc: a request arriving mid-scan is kept, not silently dropped" {
    # The race. The poller used to delete the marker BEFORE calling scan.sh; if
    # a scheduled scan happened to hold the lock at that moment, scan.sh exited
    # 0 without scanning and the request was gone. No error was produced
    # anywhere in that sequence, which is why it could sit unnoticed - the user
    # just never got their scan.
    mkdir -p "$DUC_REQUEST_DIR" "$DUC_LOCK_DIR"
    run "$APP/manual_scan.sh"
    assert_success
    [ -d "$DUC_REQUEST_DIR" ] || fail "the request was discarded while a scan held the lock"
    assert_stub_not_called duc "index"
    run cat "$DUC_LOG_FILE"
    assert_output --partial "deferred"
}

@test "duc: the kept request is picked up on the next tick once the lock clears" {
    mkdir -p "$DUC_REQUEST_DIR" "$DUC_LOCK_DIR"
    run "$APP/manual_scan.sh"
    assert_success
    rmdir "$DUC_LOCK_DIR"
    run "$APP/manual_scan.sh"
    assert_success
    assert_stub_called duc "index"
    [ ! -d "$DUC_REQUEST_DIR" ]
}

@test "duc: a failed manual scan clears the request instead of retrying forever" {
    duc_fails_with 5
    mkdir -p "$DUC_REQUEST_DIR"
    run "$APP/manual_scan.sh"
    assert_success
    [ ! -d "$DUC_REQUEST_DIR" ] || fail "a broken scan would be retried every minute forever"
    run cat "$DUC_LOG_FILE"
    assert_output --partial "Manual scan failed (exit 5)"
}

# --- manual_scan.cgi (the producer) ----------------------------------------

@test "duc: the cgi queues a request when nothing is running" {
    run "$APP/manual_scan.cgi"
    assert_success
    assert_output --partial "Content-type: text/plain"
    assert_output --partial "A scan will be started within one minute"
    [ -d "$DUC_REQUEST_DIR" ] || fail "the cgi reported a queued scan without queueing one"
}

@test "duc: the cgi does not queue a second request on top of a pending one" {
    mkdir -p "$DUC_REQUEST_DIR"
    run "$APP/manual_scan.cgi"
    assert_success
    assert_output --partial "already been requested"
}

@test "duc: the cgi shows the running scan's log instead of queueing" {
    mkdir -p "$DUC_LOCK_DIR"
    echo "half a scan" > "$DUC_LOG_FILE"
    run "$APP/manual_scan.cgi"
    assert_success
    assert_output --partial "A scan is already in progress"
    assert_output --partial "half a scan"
    [ ! -d "$DUC_REQUEST_DIR" ] || fail "the in-progress branch queued a request as well"
}

@test "duc: the cgi still returns a body when the log file does not exist yet" {
    # set -e plus a bare `cat` would abort AFTER the headers had gone out,
    # turning a status page into a truncated 500 on a fresh container.
    mkdir -p "$DUC_LOCK_DIR"
    rm -f "$DUC_LOG_FILE"
    run "$APP/manual_scan.cgi"
    assert_success
    assert_output --partial "A scan is already in progress"
    assert_output --partial "(no log yet)"
}

@test "duc: the cgi does not report a queued scan when the marker cannot be created" {
    # Dropping errexit from this file is invisible until the mkdir fails, and
    # then the cgi answers "A scan will be started within one minute" for a
    # request that was never queued. Nothing consumes a missing marker - the
    # poller branches on it - so the user is told a scan is coming and no scan
    # ever runs.
    #
    # A regular file at the marker path is the one state `mkdir -p` cannot
    # resolve, which makes this hermetic and independent of the uid the suite
    # runs as; it stands in for any mkdir failure, a full /tmp or a read-only
    # mount among them.
    #
    # All four assertions are load-bearing. The absent success message and the
    # non-zero status are both satisfied by a response that stopped after the
    # headers, which is exactly what the bare `mkdir` under `set -e` produced:
    # the client is told the response is text and then gets nothing to read. So
    # the content type and the body have to be asserted too, and the body has to
    # be the one that says nothing was queued.
    #
    # The status is the script's, not the response's: the headers are already
    # out when the mkdir fails, so there is no 500 left to send and the reply
    # the client sees is a 200 carrying this body. Moving the fallible work
    # above the headers would buy a real 500 at the cost of the errexit entry
    # in tests/mutation/corpus/duc-service.sh, which is a separate decision.
    : > "$DUC_REQUEST_DIR"
    run "$APP/manual_scan.cgi"
    assert_failure
    assert_output --partial "Content-type: text/plain"
    assert_output --partial "The scan request could not be completed"
    refute_output --partial "A scan will be started within one minute"
}

@test "duc: the log cgi serves the log with a content type" {
    echo "some history" > "$DUC_LOG_FILE"
    run "$APP/log.cgi"
    assert_success
    assert_output --partial "Content-type: text/plain"
    assert_output --partial "some history"
}

@test "duc: the duc cgi hands the request straight to duc's own cgi mode" {
    run "$APP/duc.cgi"
    assert_success
    assert_output --partial "duc stub: cgi"
}

# --- startup.sh ------------------------------------------------------------

# Source startup.sh (its main guard keeps main() from running) and call one of
# its functions.
startup() {
    run bash -c 'source "$1"; shift; "$@"' _ "$APP/startup.sh" "$@"
}

@test "duc: valid_schedule accepts a five-field schedule" {
    startup valid_schedule "0 4 * * *"
    assert_success
}

@test "duc: valid_schedule rejects the values that used to reach cron unchecked" {
    # The old check was `echo "$SCHEDULE" | awk 'NF==5'` - a print filter, not a
    # predicate. It exited 0 for every one of these, so the fallback below it
    # was unreachable code and cron silently ignored whatever landed in the file.
    local bad
    for bad in "" "0 4 * *" "0 4 * * * *" "notacron"; do
        startup valid_schedule "$bad"
        [ "$status" -ne 0 ] || fail "accepted an invalid schedule: '$bad'"
    done
}

@test "duc: valid_schedule rejects a multi-line schedule" {
    # /etc/cron.d is newline-delimited, so a value whose first line looks valid
    # would otherwise append extra crontab lines that run as root.
    startup valid_schedule "$(printf '0 4 * * *\n* * * * * root /bin/sh -c id')"
    assert_failure
}

@test "duc: the cron file runs the poller every minute and the scan on schedule" {
    startup write_cron_file "0 4 * * *" "$DUC_CRON_FILE"
    assert_success
    run cat "$DUC_CRON_FILE"
    assert_output --partial "* * * * * root /manual_scan.sh"
    assert_output --partial "0 4 * * * root $DUC_SCAN_SH"
}

@test "duc: the cron file is world-readable, which cron requires" {
    startup write_cron_file "0 4 * * *" "$DUC_CRON_FILE"
    run stat -c '%a' "$DUC_CRON_FILE"
    assert_output "644"
}

# start_webserver, driven directly through DUC_FCGI_SOCKET. That seam is the
# reason these two tests exist at all: the shipped path is
# /var/run/fcgiwrap.socket, which is root-owned on every host the suite runs on,
# and every test that drives main() overrides start_webserver instead - so
# before the seam the wait loop was unreachable and its condition could be
# inverted with nothing going red (tests/mutation/survivors.tsv, startup.sh:51).
#
# fcgiwrap and nginx are stubbed for both, because neither is installed here.
# The fcgiwrap stub is what can bind the socket, as the real one does; `sleep`
# is the loop's own body and is the only place a test can act from while the
# function is inside it.

@test "duc: start_webserver returns as soon as the socket is up" {
    # Nothing here waits: the fcgiwrap stub binds a real unix socket at the seam
    # path, so the loop's check passes and the function carries on to nginx. It
    # has to be a socket and not a file, because the loop tests `[ -S ]`.
    #
    # The `sleep` stub is what makes an inverted condition fail instead of hang.
    # Entered with the socket already up, nothing else ends that loop, so after
    # 100 calls the stub takes the socket away: the loop leaves, the chmod finds
    # nothing, and errexit kills the function before nginx. A hang would be
    # scored by the oracle's time budget rather than by an assertion, and 100 is
    # far more calls than the real form needs for a bind that takes milliseconds.
    export DUC_FCGI_SOCKET="$BATS_TEST_TMPDIR/fcgiwrap.socket"
    export SLEEP_COUNT="$BATS_TEST_TMPDIR/sleep-count"
    stub_tool fcgiwrap '
        python3 -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$DUC_FCGI_SOCKET"
        echo "fcgiwrap stub: $*"
    '
    stub_tool nginx 'echo "nginx stub"'
    stub_tool sleep '
        n=$(( $(cat "$SLEEP_COUNT" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "$SLEEP_COUNT"
        [ "$n" -lt 100 ] || rm -f "$DUC_FCGI_SOCKET"
    '
    startup start_webserver
    assert_success
    assert_output --partial "Launching webserver"
    assert_stub_called nginx ""
    [ "$(cat "$SLEEP_COUNT" 2>/dev/null || echo 0)" -lt 100 ] \
        || fail "the wait never saw the socket the fcgiwrap stub bound"
}

@test "duc: start_webserver waits for the socket rather than assuming it is there" {
    # The socket is absent when the function starts, and the fcgiwrap stub is
    # not going to bind one - that is the case the loop is for. `sleep` is the
    # loop's body, so the stub binds the socket itself on its first call and
    # records that it ran. The assertion is on that behaviour, that the loop
    # body ran and nginx started afterwards, rather than on how long the wait
    # took. An inverted condition skips the loop entirely, so the chmod finds no
    # socket, errexit kills the function, and nginx never runs.
    export DUC_FCGI_SOCKET="$BATS_TEST_TMPDIR/fcgiwrap.socket"
    export SLEEP_WAITED="$BATS_TEST_TMPDIR/sleep-called"
    stub_tool fcgiwrap 'echo "fcgiwrap stub: $*"'
    stub_tool nginx 'echo "nginx stub"'
    stub_tool sleep '
        : > "$SLEEP_WAITED"
        python3 -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$DUC_FCGI_SOCKET"
    '
    startup start_webserver
    assert_success
    [ -f "$SLEEP_WAITED" ] || fail "the function never waited for the socket"
    assert_stub_called nginx ""
}

# main() end to end, with the two process-level steps replaced. SCHEDULE and
# DUC_CRON_BIN are EXPORTED, not prefixed onto the call: a `VAR=x func` prefix
# sets the variable in this shell, and the `bash -c` below is a child process
# that would never see it - the test would then silently exercise whatever
# SCHEDULE the environment happened to hold.
run_main() {
    export DUC_CRON_BIN="${DUC_CRON_BIN:-true}"
    run bash -c '
        source "$1"
        start_webserver() { echo "webserver started"; }
        main
    ' _ "$APP/startup.sh"
}

@test "duc: startup falls back to midnight when SCHEDULE is invalid" {
    export SCHEDULE="every day please"
    run_main
    assert_success
    assert_output --partial "falling back to '0 0 * * *'"
    run cat "$DUC_CRON_FILE"
    assert_output --partial "0 0 * * * root $DUC_SCAN_SH"
}

@test "duc: startup keeps a valid SCHEDULE" {
    export SCHEDULE="30 2 * * 0"
    run_main
    assert_success
    refute_output --partial "falling back"
    run cat "$DUC_CRON_FILE"
    assert_output --partial "30 2 * * 0 root $DUC_SCAN_SH"
}

@test "duc: startup runs the initial scan before writing the crontab" {
    export SCHEDULE="0 4 * * *"
    run_main
    assert_success
    assert_output --partial "Starting initial recursive scan"
    assert_stub_called duc "index --progress $DUC_SCAN_ROOT"
}

@test "duc: a failed initial scan does not stop the container coming up" {
    # The webserver and the crontab matter more than the first index. If this
    # aborted, a duc that failed once would never serve its UI again.
    export SCHEDULE="0 4 * * *"
    duc_fails_with 7
    run_main
    assert_success
    assert_output --partial "Initial scan failed (exit 7)"
    assert_output --partial "webserver started"
}

@test "duc: startup does not come up when the cron daemon cannot start" {
    # Every scan this container runs is a crontab entry, so a cron that will not
    # start leaves a UI whose button queues requests nothing will ever consume.
    # errexit is what makes that fatal: the bare "$CRON_BIN" call aborts main()
    # before start_webserver, the container exits, and restart: always turns it
    # into a visible crash loop. The line before it in main() is the assertion
    # that the abort happened at the cron step and not somewhere earlier.
    #
    # The initial scan directly above is deliberately tolerant of failure; this
    # one is deliberately not, and dropping -e erases the difference.
    export SCHEDULE="0 4 * * *"
    export DUC_CRON_BIN=false
    run_main
    assert_failure
    assert_output --partial "Creating cron schedule: 0 4 * * *"
    refute_output --partial "webserver started"
}
