#!/usr/bin/env bash

set -euo pipefail

# Overridable so tests/duc-service.bats can drive this against a throwaway tree.
# Nothing in the image sets any of them - the defaults are what the container
# runs, and each one is the value that was hardcoded here before.
LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"
CRON_FILE="${DUC_CRON_FILE:-/etc/cron.d/duc-index}"
CRON_BIN="${DUC_CRON_BIN:-cron}"
SCAN_SH="${DUC_SCAN_SH:-/scan.sh}"
MANUAL_SCAN_SH="${DUC_MANUAL_SCAN_SH:-/manual_scan.sh}"
# The fifth seam, and the one that makes the wait in start_webserver reachable
# at all: /var/run/fcgiwrap.socket is root-owned on both hosts the suite runs on,
# so a test that drives that loop has to point it at a path it can bind a socket
# in. The default is the path the image uses.
FCGI_SOCKET="${DUC_FCGI_SOCKET:-/var/run/fcgiwrap.socket}"
FALLBACK_SCHEDULE="0 0 * * *"

# A cron schedule is exactly five whitespace-separated fields on exactly one
# line.
#
# This used to be `echo "$SCHEDULE" | awk 'NF==5'`, which is a PRINT FILTER and
# not a test: awk with a pattern and no action prints the matching lines and
# exits 0 whatever it matched. The negation could therefore never be true and
# the fallback below was unreachable code - any value at all, including an empty
# one, went straight into /etc/cron.d, where cron ignores a malformed line
# without comment and the daily scan simply never runs.
#
# NR==1 matters as much as NF==5: /etc/cron.d entries are newline-delimited, so
# a multi-line SCHEDULE whose first line happens to carry five fields would
# otherwise append arbitrary extra crontab lines, running as root.
valid_schedule() {
    printf '%s' "${1-}" | awk 'NF == 5 { ok = 1 } END { exit !(ok && NR == 1) }'
}

write_cron_file() {
    local schedule="$1" dest="$2"
    {
        echo "# Auto-generated Duc cron tasks"
        echo "# Manual scan request poller"
        echo "* * * * * root $MANUAL_SCAN_SH"
        echo "# Scheduled full scan"
        echo "$schedule root $SCAN_SH"
    } > "$dest"
    chmod 0644 "$dest"
}

# A seam. Everything in here is process-level setup that a test has no business
# performing - and tests/duc-service.bats overrides it so main() can be driven
# end to end without fcgiwrap or nginx being installed. The socket path it waits
# on is a seam of its own (DUC_FCGI_SOCKET) so that the wait loop itself can be
# driven directly, since no test that overrides this function ever reaches it.
start_webserver() {
    echo "Launching webserver"
    rm -f "$FCGI_SOCKET"
    nohup fcgiwrap -s unix:"$FCGI_SOCKET" &
    while ! [ -S "$FCGI_SOCKET" ]; do sleep .2; done
    chmod 777 "$FCGI_SOCKET"
    test -f nohup.out && rm -f ./nohup.out

    nginx
}

main() {
    touch "$LOG_FILE"

    echo "Starting initial recursive scan"
    echo "This may take a while..."
    echo "Now: $(date)"
    "$SCAN_SH" || echo "Initial scan failed (exit $?)" | tee -a "$LOG_FILE"
    echo "Now: $(date)"
    echo "Scan complete"

    local schedule="${SCHEDULE:-}"
    if ! valid_schedule "$schedule"; then
        echo "Invalid SCHEDULE '$schedule' - falling back to '$FALLBACK_SCHEDULE'" | tee -a "$LOG_FILE"
        schedule="$FALLBACK_SCHEDULE"
    fi

    echo "Creating cron schedule: $schedule"
    write_cron_file "$schedule" "$CRON_FILE"
    "$CRON_BIN"

    start_webserver
}

# Sourced by tests/duc-service.bats, executed by the image's CMD.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
