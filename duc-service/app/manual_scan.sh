#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"
REQUEST_DIR="/tmp/scan_requested"

if [ -d "$REQUEST_DIR" ]; then
    rm -rf "$REQUEST_DIR"
    /scan.sh || echo "Manual scan failed (exit $?)" >> "$LOG_FILE"
fi
