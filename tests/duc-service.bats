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
    : > "$DUC_REQUEST_DIR"
    run "$APP/manual_scan.cgi"
    assert_failure
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
