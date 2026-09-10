#!/bin/bash
set -euo pipefail
#
# Report executable files sitting in the media and download trees.
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. It only inspects and reports —
#     it changes nothing.
#
# THE FAILURE IT LOOKS FOR
#
# Public torrent indexers have no upload vetting, and the standard abuse of that
# is a dropper wearing a release's name: a ~1GB Windows executable padded to
# episode size, called something like
# "Reacher S04E08 1080p WEB H264-CAKES.exe", uploaded under a real release
# group's tag so it ranks against every new-episode search.
#
# Two layers already stand against this and neither is sufficient alone:
#
#   1. qBittorrent's exclusion list (configure-apps.sh, `excluded_file_names`)
#      drops the matching files before any bytes transfer. It only protects
#      torrents added AFTER it was set, and only on this client — anything
#      already on disk, hand-added, or arriving via usenet bypasses it.
#
#   2. Sonarr/Radarr refuse to import a release containing an executable
#      ("Caution: Found executable file"). That check fires only at import,
#      i.e. after the full download has landed, and a refused import leaves
#      the payload sitting in the download directory indefinitely.
#
# So the steady state this catches is: a dropper that was downloaded, correctly
# refused by the *arr, and then simply left on disk — inert on the NAS, which is
# Linux, but one SMB browse away from a Windows machine where it is not inert.
#
# On 2026-09-10 that was three files totalling ~2.9GB, found only because
# someone happened to look.
#
# Patterns are kept in step with the qBittorrent exclusion list set by
# scripts/configure-apps.sh. Changing one without the other leaves a gap.
#
# Usage:
#   ./scripts/scan-executables.sh            # scan, report, exit non-zero on findings
#   ./scripts/scan-executables.sh --quiet    # print only findings (for cron)
#
# Exit codes:
#   0 = no executables found
#   1 = at least one found, or the scan could not be completed
#
# Reasonable to run on a timer:
#   0 4 * * 0 /path/to/arr-stack/scripts/scan-executables.sh --quiet || notify "executable in media tree"

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

# Extensions must mirror `excluded_names` in scripts/configure-apps.sh.
PATTERNS=(exe scr bat cmd com msi lnk vbs ps1 jar)

log() { $QUIET || echo "$@"; }

# Scan from inside a container rather than against a host path: the /data mount
# is the same tree for every service, so this works regardless of where the
# volume actually lives on the host. Sonarr is on the bridge and does not depend
# on the VPN being up, which makes it the most reliable entry point.
CONTAINER=""
for c in sonarr radarr qbittorrent; do
    if docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
        CONTAINER="$c"
        break
    fi
done

if [[ -z "$CONTAINER" ]]; then
    echo "ERROR: no running container with /data mounted (tried sonarr, radarr, qbittorrent)." >&2
    echo "       Cannot scan. This is a failure, not a clean result." >&2
    exit 1
fi

log "Scanning /data via $CONTAINER for: ${PATTERNS[*]}"

# Build a single find expression: -iname '*.exe' -o -iname '*.scr' -o ...
find_args=()
for i in "${!PATTERNS[@]}"; do
    [[ $i -gt 0 ]] && find_args+=(-o)
    find_args+=(-iname "*.${PATTERNS[$i]}")
done

# find exits non-zero on unreadable subdirectories, which must not be mistaken
# for "found nothing" — capture status separately from output.
set +e
hits=$(docker exec "$CONTAINER" find /data \( "${find_args[@]}" \) -type f -printf '%s\t%p\n' 2>/dev/null)
find_status=$?
set -e

if [[ $find_status -ne 0 && -z "$hits" ]]; then
    echo "ERROR: find failed inside $CONTAINER (exit $find_status). Scan result is unknown." >&2
    exit 1
fi

if [[ -z "$hits" ]]; then
    log "Clean: no executables under /data."
    exit 0
fi

count=$(echo "$hits" | wc -l | tr -d ' ')
echo "FOUND $count executable file(s) under /data:" >&2
echo "$hits" | awk -F'\t' '{ printf "  %6.1f MB  %s\n", $1/1048576, $2 }' >&2
echo >&2
echo "These should not be here. Verify each, then delete it and blocklist the" >&2
echo "release in Sonarr/Radarr so the same grab is not repeated." >&2
exit 1
