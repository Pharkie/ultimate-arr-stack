#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"

echo "Content-type: text/plain"; echo
cat "$LOG_FILE"
