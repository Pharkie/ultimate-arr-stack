#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"
LOCK_DIR="/tmp/scan.lock"

# Acquire lock atomically using mkdir (portable). If it exists, just exit silently.
if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'rm -rf "$LOCK_DIR"' EXIT

    {
        echo "Start of scan: $(date)"
        /usr/local/bin/duc index --progress /scan
        status=$?
        echo "End of scan: $(date) (exit code: $status)"
        # Propagate exit status of duc from this subshell to pipeline.
        exit $status
    } 2>&1 | tee -a "$LOG_FILE"

    # Retrieve exit status of the block (first element) from PIPESTATUS.
    scan_status=${PIPESTATUS[0]}
    exit $scan_status
fi
