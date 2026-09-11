#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"
LOCK_DIR="${DUC_LOCK_DIR:-/tmp/scan.lock}"
REQUEST_DIR="${DUC_REQUEST_DIR:-/tmp/scan_requested}"

echo "Content-type: text/plain"; echo

# Any abort past this point leaves the response truncated: the headers have
# gone out, nginx cannot add more, and the client shows a blank page instead
# of a reason. The one-at-a-time version of this already exists below
# (`cat ... || echo "(no log yet)"`); the trap covers the call sites nobody
# thought about, starting with the `mkdir -p` that a stale file at the marker
# path turns into an abort under `set -e`.
#
# The flag is set at the very end rather than inside each branch, so a branch
# added later cannot forget it and get the fallback body glued onto a response
# that already finished.
#
# The script exits non-zero and the response is still 200: the headers are out
# by the time a failure can happen, so there is no 500 to send any more, and
# fcgiwrap is left to log the status. A real 500 would mean doing the fallible
# work before the headers.
_completed=false
_finish_response() {
    [[ "$_completed" == true ]] && return 0
    echo "The scan request could not be completed, so nothing was queued."
    echo "See the container log for details."
}
trap _finish_response EXIT

if [ -d "$LOCK_DIR" ]; then
    echo "A scan is already in progress:"; echo
    # Never let a missing log turn a status page into a 500: `set -e` plus a
    # bare `cat` would abort the script AFTER the headers had already gone out.
    cat "$LOG_FILE" 2>/dev/null || echo "(no log yet)"
elif [ -d "$REQUEST_DIR" ]; then
    echo "A manual scan has already been requested and will start within one minute"
else
    mkdir -p "$REQUEST_DIR"
    echo "A scan will be started within one minute"
fi

_completed=true
