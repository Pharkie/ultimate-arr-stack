#!/usr/bin/env bash
# Replaces /scan.sh in mkoestler/duc-service (mounted read-only by
# docker-compose.utilities.yml). startup.sh, the 04:00 cron job and the UI's
# manual-scan button all call /scan.sh, so all three use this.
#
# Generated with LLM assistance and human-reviewed. Read and understand it
# before running it.
#
# duc's tokyocabinet index has no journal. A duc killed mid-write leaves
# duc.db corrupt, and every later `duc index` into it dies a few seconds in
# with "fatal error: out of memory". The image's startup.sh ignores SIGTERM,
# so `docker stop` during a scan always ends that way (the index here stopped
# updating on 2026-03-30). So: index into a scratch file and rename it over
# the live index only when duc succeeds. A killed run costs the scratch file,
# never the index the UI reads.
set -euo pipefail

LOG_FILE="${DUC_LOG_FILE:-/var/log/duc.log}"
DB="/database/duc.db"   # /etc/ducrc points the web UI here
TMP_DB="${DB}.new"

# flock, not the upstream mkdir lock: a lock directory outlives a killed scan,
# and every scan after it exits 0 without indexing until the container is
# recreated. The kernel drops a flock when its holder dies.
exec 9>/tmp/scan.lock
flock -n 9 || exit 0

{
    echo "Start of scan: $(date)"
    status=0
    # -f truncates whatever an interrupted run left in the scratch file
    /usr/local/bin/duc index -f --progress -d "$TMP_DB" /scan || status=$?
    if [ "$status" -eq 0 ]; then mv -f "$TMP_DB" "$DB"; fi
    echo "End of scan: $(date) (exit code: $status)"
    exit "$status"
} 2>&1 | tee -a "$LOG_FILE"
