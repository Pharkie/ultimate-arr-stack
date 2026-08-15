#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"
touch "$LOG_FILE"

echo "Starting initial recursive scan"
echo "This may take a while..."
echo "Now: $(date)"
/scan.sh || echo "Initial scan failed (exit $?)" | tee -a "$LOG_FILE"
echo "Now: $(date)"
echo "Scan complete"

# Basic validation for SCHEDULE (5 fields). If invalid, fallback to midnight.
if ! echo "$SCHEDULE" | awk 'NF==5' >/dev/null 2>&1; then
	echo "Invalid SCHEDULE '$SCHEDULE' - falling back to '0 0 * * *'" | tee -a "$LOG_FILE"
	SCHEDULE="0 0 * * *"
fi

echo "Creating cron schedule: $SCHEDULE"
CRON_FILE=/etc/cron.d/duc-index
{
	echo "# Auto-generated Duc cron tasks"
	echo "# Manual scan request poller"
	echo "* * * * * root /manual_scan.sh"
	echo "# Scheduled full scan"
	echo "$SCHEDULE root /scan.sh"
} > "$CRON_FILE"
chmod 0644 "$CRON_FILE"
cron

echo "Launching webserver"
rm -f /var/run/fcgiwrap.socket
nohup fcgiwrap -s unix:/var/run/fcgiwrap.socket &
while ! [ -S /var/run/fcgiwrap.socket ]; do sleep .2; done
chmod 777 /var/run/fcgiwrap.socket
test -f nohup.out && rm -f ./nohup.out

nginx