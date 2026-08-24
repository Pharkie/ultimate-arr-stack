#!/bin/bash
set -euo pipefail
#
# Remove stuck/stalled items from Sonarr and Radarr download queues
#
# Torrents frequently stall (dead seeders, stuck metadata, failed imports)
# and sit in queues indefinitely. This script identifies stuck items,
# removes them (with blocklist to prevent re-grabbing the same release),
# and triggers fresh searches for better alternatives.
#
# Usage:
#   ./scripts/queue-cleanup.sh                # dry run (default)
#   ./scripts/queue-cleanup.sh --apply        # actually remove stuck items
#   ./scripts/queue-cleanup.sh --apply -v     # remove with verbose output
#
# Cron (Thursday 2am):
#   0 2 * * 4 $NAS_STACK_DIR/scripts/queue-cleanup.sh --apply >> $NAS_STACK_DIR/logs/queue-cleanup.log 2>&1
#
# Prerequisites:
#   - Sonarr and Radarr running and accessible on localhost
#   - python3 and curl available
#
# What gets removed:
#   - Downloads stalled with no connections
#   - Torrents stuck downloading metadata
#   - Failed imports (completed but can't import)
#   - Downloads with errors (missing files, not available, etc.)
#   - Items at 0% progress for more than 24 hours
#
# What is NEVER removed:
#   - Items with any download progress (even if slow)
#   - Healthy downloads (trackedDownloadStatus == "ok" with progress)
#
# After removal, a fresh search is triggered for each affected
# series (Sonarr) or movie (Radarr) to find better-seeded releases.
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. Dry run (no --apply) is the default
#     so you can inspect what it would do first.
#

# Derive stack directory from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$NAS_STACK_DIR/logs/queue-cleanup.log"
MAX_LOG_LINES=1000

# --- Parse arguments ---
APPLY=false
VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --verbose|-v) VERBOSE=true ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
      exit 0
      ;;
  esac
done

# --- Output helpers ---
log()  { echo "[queue-cleanup] $1"; }
ok()   { echo "  ✓ $1"; }
skip() { echo "  - $1"; }
fail() { echo "  ✗ $1"; }
info() { echo "  $1"; }
verbose() { $VERBOSE && echo "  [verbose] $1" || true; }

# --- Timestamp ---
echo ""
echo "========================================"
echo "Queue Cleanup — $(date '+%Y-%m-%d %H:%M:%S')"
if $APPLY; then
  echo "Mode: APPLYING (removing stuck items)"
else
  echo "Mode: DRY RUN (use --apply to remove)"
fi
echo "========================================"

# --- Discover API keys from running containers ---
get_api_key() {
  local container="$1"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container}$"; then
    return 1
  fi
  docker exec "$container" cat /config/config.xml 2>/dev/null \
    | grep -oP '(?<=<ApiKey>)[^<]+' || return 1
}

SONARR_KEY=$(get_api_key sonarr) || true
RADARR_KEY=$(get_api_key radarr) || true

if [[ -z "$SONARR_KEY" ]] && [[ -z "$RADARR_KEY" ]]; then
  log "ERROR: Could not get API keys for Sonarr or Radarr. Are the containers running?"
  exit 1
fi

# --- Main cleanup logic (python3 for JSON processing) ---
python3 - "$APPLY" "$VERBOSE" "$SONARR_KEY" "$RADARR_KEY" << 'PYEOF'
import json, sys, subprocess, time
from datetime import datetime, timezone

APPLY = sys.argv[1] == "true"
VERBOSE = sys.argv[2] == "true"
SONARR_KEY = sys.argv[3]
RADARR_KEY = sys.argv[4]

SERVICES = []
if SONARR_KEY:
    SERVICES.append({
        "name": "Sonarr",
        "port": 8989,
        "key": SONARR_KEY,
        "id_field": "seriesId",
        "search_cmd": "SeriesSearch",
        "search_key": "seriesId",
    })
if RADARR_KEY:
    SERVICES.append({
        "name": "Radarr",
        "port": 7878,
        "key": RADARR_KEY,
        "id_field": "movieId",
        "search_cmd": "MoviesSearch",
        "search_key": "movieIds",
    })

total_removed = 0
total_searches = 0

def api_get(port, path, key):
    url = f"http://localhost:{port}{path}"
    if "?" in url:
        url += f"&apikey={key}"
    else:
        url += f"?apikey={key}"
    result = subprocess.run(
        ["curl", "-s", "-f", url],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)

def api_delete(port, path, key):
    url = f"http://localhost:{port}{path}"
    if "?" in url:
        url += f"&apikey={key}"
    else:
        url += f"?apikey={key}"
    result = subprocess.run(
        ["curl", "-s", "-f", "-X", "DELETE", url],
        capture_output=True, text=True, timeout=30
    )
    return result.returncode == 0

def api_post_json(port, path, key, data):
    url = f"http://localhost:{port}{path}?apikey={key}"
    result = subprocess.run(
        ["curl", "-s", "-f", "-X", "POST",
         "-H", "Content-Type: application/json",
         "-d", json.dumps(data), url],
        capture_output=True, text=True, timeout=30
    )
    return result.returncode == 0

# How long a download may sit stalled before the sweep removes it. Long enough
# that a torrent briefly losing its peers is left alone, short enough that a
# dead one does not survive to the next weekly run.
STALL_GRACE_HOURS = 24

def item_age_hours(record):
    """Hours since the item was added, or None if it carries no timestamp."""
    added_str = record.get("added", "")
    if not added_str:
        return None
    try:
        added = datetime.fromisoformat(added_str.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - added).total_seconds() / 3600
    except (ValueError, TypeError):
        return None

def is_stuck(record):
    """Determine if a queue record is stuck and should be removed."""
    status = record.get("status", "")
    tracked_status = record.get("trackedDownloadStatus", "")
    tracked_state = record.get("trackedDownloadState", "")
    error_msg = (record.get("errorMessage", "") or "").lower()
    size = record.get("size", 0)
    sizeleft = record.get("sizeleft", 0)

    # Error-based: stalled, unavailable, missing, etc.
    #
    # Sonarr surfaces a stalled torrent as status="warning" with
    # trackedDownloadStatus="ok" -- gating this on tracked_status alone meant the
    # keyword test never ran for the single most common stall. Check both fields.
    # "not on your server" covers usenet grabs whose articles are past retention;
    # those arrive as status="failed" and carry no `added` timestamp, so no
    # age-based rule below can ever reach them.
    if tracked_status == "warning" or status in ("warning", "failed"):
        error_keywords = ["stall", "no connections", "not available",
                          "no files found", "import failed", "missing",
                          "not on your server"]
        if any(kw in error_msg for kw in error_keywords):
            age = item_age_hours(record)
            # A torrent can stall briefly and recover. Only cull one that has
            # been stalled long enough to be genuinely dead -- except usenet
            # failures, which are terminal immediately and have no timestamp.
            if status == "failed" or age is None or age > STALL_GRACE_HOURS:
                suffix = f" for {age:.0f}h" if age is not None else ""
                return "error", f"{error_msg.strip()}{suffix}"

    # Stuck imports (completed download but can't import)
    if tracked_state == "importing" and tracked_status == "warning":
        return "import_stuck", "completed but stuck importing"

    # Import blocked (already imported, not an upgrade, etc.)
    if tracked_state == "importBlocked":
        msgs = []
        for sm in record.get("statusMessages", []):
            msgs.extend(sm.get("messages", []))
        reason = "; ".join(msgs[:2]) if msgs else "import blocked"
        return "import_blocked", reason

    # Import pending with warnings (e.g. executable files, not an upgrade)
    if tracked_state == "importPending" and tracked_status == "warning":
        msgs = []
        for sm in record.get("statusMessages", []):
            msgs.extend(sm.get("messages", []))
        all_msgs = " ".join(msgs).lower()
        # "potentially dangerous" covers .scr/.lnk padding, which Sonarr words
        # differently from the ".exe" case ("Found potentially dangerous file
        # with extension: .scr"). Without it those releases download to 100%,
        # refuse to import, and sit in the queue forever -- several had been
        # stuck for over a month.
        # "upgrade for existing" rather than "not an upgrade": Sonarr's actual
        # wording is "Not a quality revision upgrade for existing episode
        # file(s)", which the narrower phrase never matched -- one completed
        # 2160p grab sat in the queue for 49 days because of it, holding disk
        # in /data/usenet/complete for a file Sonarr already had as good.
        if ("executable" in all_msgs or "upgrade for existing" in all_msgs
                or "not an upgrade" in all_msgs
                or "potentially dangerous" in all_msgs):
            reason = "; ".join(msgs[:2]) if msgs else "import pending with warnings"
            return "import_warning", reason

    # Stuck downloading metadata (no peers at all)
    if "downloading metadata" in error_msg:
        return "metadata", "stuck downloading metadata"

    # Age-based: 0% progress for 24+ hours
    if size > 0 and sizeleft == size:
        added_str = record.get("added", "")
        if added_str:
            try:
                added = datetime.fromisoformat(added_str.replace("Z", "+00:00"))
                age_hours = (datetime.now(timezone.utc) - added).total_seconds() / 3600
                if age_hours > 24:
                    return "stale", f"0% progress for {age_hours:.0f}h"
            except (ValueError, TypeError):
                pass
    elif size == 0:
        # No size info at all — likely metadata-only, check age
        added_str = record.get("added", "")
        if added_str:
            try:
                added = datetime.fromisoformat(added_str.replace("Z", "+00:00"))
                age_hours = (datetime.now(timezone.utc) - added).total_seconds() / 3600
                if age_hours > 24:
                    return "stale", f"no size info for {age_hours:.0f}h"
            except (ValueError, TypeError):
                pass

    # Partially-downloaded stalls. The age rules above only fire at exactly 0%
    # (sizeleft == size) or with no size at all, so anything that grabbed a few
    # percent and then lost every peer matched no branch and survived every
    # weekly sweep indefinitely -- one title sat at 32% for 45 days this way.
    if 0 < sizeleft < size:
        age = item_age_hours(record)
        if age is not None and age > STALL_GRACE_HOURS:
            pct = (1 - sizeleft / size) * 100
            if record.get("status") == "warning" or "stall" in error_msg:
                return "stalled", f"stalled at {pct:.0f}% for {age:.0f}h"

    return None, None

for svc in SERVICES:
    print(f"\n--- {svc['name']} (port {svc['port']}) ---")

    # Paginate through queue
    all_records = []
    page = 1
    while True:
        data = api_get(svc["port"], f"/api/v3/queue?page={page}&pageSize=50", svc["key"])
        if data is None:
            print(f"  ✗ Failed to fetch queue")
            break
        records = data.get("records", [])
        all_records.extend(records)
        total_records = data.get("totalRecords", 0)
        if page * 50 >= total_records:
            break
        page += 1

    print(f"  Queue size: {len(all_records)} items")

    stuck_items = []
    for record in all_records:
        reason_type, reason_msg = is_stuck(record)
        if reason_type:
            stuck_items.append((record, reason_type, reason_msg))

    if not stuck_items:
        print(f"  - No stuck items found")
        continue

    print(f"  Found {len(stuck_items)} stuck item(s):")

    removed_ids = set()   # queue IDs successfully removed
    search_targets = set()  # unique series/movie IDs to re-search
    removed_count = 0

    for record, reason_type, reason_msg in stuck_items:
        title = record.get("title", "unknown")[:70]
        qid = record.get("id")
        target_id = record.get(svc["id_field"])

        if APPLY:
            success = api_delete(
                svc["port"],
                f"/api/v3/queue/{qid}?removeFromClient=true&blocklist=true",
                svc["key"]
            )
            if success:
                print(f"  ✓ Removed: {title}")
                print(f"    Reason: {reason_msg}")
                removed_ids.add(qid)
                removed_count += 1
                if target_id:
                    search_targets.add(target_id)
                time.sleep(0.5)
            else:
                print(f"  ✗ Failed to remove: {title}")
        else:
            print(f"  [dry-run] Would remove: {title}")
            print(f"    Reason: {reason_msg}")
            removed_count += 1
            if target_id:
                search_targets.add(target_id)

        if VERBOSE:
            pct = 0
            if record.get("size", 0) > 0:
                pct = round((1 - record.get("sizeleft", 0) / record["size"]) * 100, 1)
            print(f"    [verbose] Status: {record.get('status')} | "
                  f"Tracked: {record.get('trackedDownloadStatus')} | "
                  f"State: {record.get('trackedDownloadState')} | "
                  f"Progress: {pct}% | Type: {reason_type}")

    # Trigger re-searches
    if search_targets:
        action = "Triggering" if APPLY else "Would trigger"
        print(f"\n  {action} searches for {len(search_targets)} {svc['name'].lower()} item(s):")
        for target_id in sorted(search_targets):
            if svc["search_key"] == "movieIds":
                payload = {"name": svc["search_cmd"], svc["search_key"]: [target_id]}
            else:
                payload = {"name": svc["search_cmd"], svc["search_key"]: target_id}

            if APPLY:
                success = api_post_json(svc["port"], "/api/v3/command", svc["key"], payload)
                status = "queued" if success else "FAILED"
                print(f"    ✓ Search {svc['id_field']}={target_id}: {status}")
            else:
                print(f"    [dry-run] Search {svc['id_field']}={target_id}")

    total_removed += removed_count
    total_searches += len(search_targets)

# --- Summary ---
print(f"\n{'=' * 40}")
mode = "APPLIED" if APPLY else "DRY RUN"
print(f"Summary ({mode}): {total_removed} items removed, {total_searches} searches triggered")
if not APPLY and total_removed > 0:
    print("Run with --apply to actually remove stuck items")
PYEOF

# --- Optional: HA webhook notification ---
if $APPLY && [[ -n "${HA_WEBHOOK_URL:-}" ]]; then
  curl -s -m 10 -X POST "$HA_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"Queue Cleanup\",\"message\":\"Weekly queue cleanup completed. Check $NAS_STACK_DIR/logs/queue-cleanup.log for details.\"}" || true
fi

# --- Trim log file ---
if [[ -f "$LOG_FILE" ]]; then
  LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$LINES" -gt "$MAX_LOG_LINES" ]]; then
    TMPLOG=$(mktemp)
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$TMPLOG" && mv "$TMPLOG" "$LOG_FILE"
  fi
fi
