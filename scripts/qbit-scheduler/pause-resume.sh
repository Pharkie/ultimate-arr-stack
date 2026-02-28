#!/bin/sh
# Pause or resume all qBittorrent torrents via Web API
# Usage: pause-resume.sh pause|resume
#
# Note: A shared qbit_auth() helper exists in scripts/lib/configure-helpers.sh
# but cannot be used here because this script runs inside an Alpine container
# with /bin/sh (not bash). Auth is implemented inline below.

set -e

ACTION="${1:-}"
QBIT_URL="http://${QBIT_HOST:-localhost}:${QBIT_PORT:-8085}"
COOKIE_FILE="/tmp/qbit_cookie.txt"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

if [ -z "$ACTION" ] || { [ "$ACTION" != "pause" ] && [ "$ACTION" != "resume" ]; }; then
    echo "Usage: $0 pause|resume"
    exit 1
fi

# Authenticate and get session cookie
log "Authenticating to qBittorrent at $QBIT_URL..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -c "$COOKIE_FILE" \
    --data-urlencode "username=${QBIT_USER}" \
    --data-urlencode "password=${QBIT_PASS}" \
    "${QBIT_URL}/api/v2/auth/login")

if [ "$HTTP_CODE" != "200" ]; then
    log "ERROR: Authentication failed (HTTP $HTTP_CODE)"
    exit 1
fi

log "Authenticated successfully"

# Pause or resume all torrents
# qBittorrent 5.0+ uses 'stop'/'start' instead of 'pause'/'resume'
if [ "$ACTION" = "pause" ]; then
    log "Pausing all torrents..."
    ENDPOINT="/api/v2/torrents/stop"
else
    log "Resuming all torrents..."
    ENDPOINT="/api/v2/torrents/start"
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -b "$COOKIE_FILE" \
    --data "hashes=all" \
    "${QBIT_URL}${ENDPOINT}")

if [ "$HTTP_CODE" = "200" ]; then
    log "SUCCESS: All torrents ${ACTION}d"
else
    log "ERROR: Failed to $ACTION torrents (HTTP $HTTP_CODE)"
    exit 1
fi

# Cleanup
rm -f "$COOKIE_FILE"
