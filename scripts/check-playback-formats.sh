#!/bin/bash
set -euo pipefail
#
# Find library files in a format the Jellyfin Android TV client can't play
#
# The custom formats configure-apps.sh sets up judge a release by its title,
# once, when it is grabbed. They never look at files already on disk, and they
# can't see a format the title doesn't name. In November 2026 one library
# held twelve Dolby Vision Profile 5 episodes (green and magenta on a Fire TV,
# the whole episode) grabbed before the Profile 5 format existed, and a
# Simpsons episode whose release was titled `1080p.web.h264` but held 2160p
# Profile 5. The same week X-Men: The Last Stand, a DTS-HD MA 6.1 remux,
# stopped at 0 ms in the Jellyfin client every time. This check reads what
# Sonarr and Radarr's own mediainfo says each file is, and posts one notice to
# the Home Assistant panel naming the files to replace.
#
# Usage:
#   ./scripts/check-playback-formats.sh                 # dry run (default): report only
#   ./scripts/check-playback-formats.sh --post          # post the notice to Home Assistant
#   ./scripts/check-playback-formats.sh --apply         # queue a search for Profile 5 files
#   ./scripts/check-playback-formats.sh --post --apply -v
#   ./scripts/check-playback-formats.sh --test          # post a test notice, whatever it finds
#
# Cron (weekly, Sunday 09:00):
#   0 9 * * 0 $NAS_STACK_DIR/scripts/check-playback-formats.sh --post --apply >> $NAS_STACK_DIR/logs/check-playback-formats.log 2>&1
#
# Prerequisites:
#   - Sonarr and/or Radarr running, with their ports published on localhost
#   - python3 and curl available
#   - HA_WEBHOOK_URL in .env (see docs/HOME-ASSISTANT.md) for --post
#
# What it reports, from each file's mediainfo:
#   - Dolby Vision Profile 5 (VideoDynamicRangeType "DV": Dolby Vision with
#     no HDR10 base layer). Its picture is green and magenta in any player
#     that doesn't apply the Dolby Vision metadata. The file scores -1000 on
#     the DV (Profile 5) format, so any release of the same quality without it
#     is an upgrade: --apply queues the search that finds one. When the only
#     other releases are a lower resolution (Netflix and Disney+ publish 4K as
#     Profile 5 only), the search takes nothing and the file is reported again
#     next week: replace it by hand from the interactive search.
#   - DTS with a 6.1 track (DTS-ES, DTS-HD MA 6.1). The Jellyfin client on a
#     Fire TV passes DTS through as the core, and a 6.1 core stopped at once.
#     The DTS 6.1 format reads release titles only, so the file itself scores
#     0 and a search would take nothing: replace it by hand.
# Files Sonarr or Radarr have no mediainfo for are not judged.
#
# One notice, level "info" (panel only), tag "playback-formats" so each
# week's notice replaces the last. Nothing is posted when nothing is found.
# Without --apply the check changes nothing in any app.
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. It reads from Sonarr's and Radarr's
#     APIs; --apply queues their searches; --post sends one HTTP POST to your
#     own Home Assistant.
#

# Derive stack directory from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"

# Cron hands the script no environment and nothing else loads .env, so read
# the webhook from it here, the way check-stuck-requests.sh does.
if [ -z "${HA_WEBHOOK_URL:-}" ] && [ -f "$NAS_STACK_DIR/.env" ]; then
  HA_WEBHOOK_URL=$(sed -n 's/^HA_WEBHOOK_URL=//p' "$NAS_STACK_DIR/.env" | tail -n 1 | tr -d "\"'")
fi
LOG_FILE="$NAS_STACK_DIR/logs/check-playback-formats.log"
MAX_LOG_LINES=2000

# --- Parse arguments ---
POST=false
APPLY=false
TEST=false
VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --post) POST=true ;;
    --apply) APPLY=true ;;
    --test) TEST=true; POST=true ;;
    --verbose|-v) VERBOSE=true ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#//; p }' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

log() { echo "[check-playback-formats] $1"; }

echo ""
echo "========================================"
echo "Playback Format Check — $(date '+%Y-%m-%d %H:%M:%S')"
if $TEST; then
  echo "Mode: TEST (a test notice goes to Home Assistant whatever is found)"
elif $POST; then
  echo "Mode: POSTING (a notice goes to Home Assistant if anything is found)"
else
  echo "Mode: DRY RUN (use --post to notify Home Assistant)"
fi
if $APPLY; then
  echo "Searches: QUEUED for Profile 5 files (--apply)"
else
  echo "Searches: reported only (use --apply to queue them)"
fi
echo "========================================"

if $POST && [[ -z "${HA_WEBHOOK_URL:-}" ]]; then
  log "ERROR: --post needs HA_WEBHOOK_URL, in the environment or in $NAS_STACK_DIR/.env"
  exit 1
fi

# --- Discover API keys from running containers (never printed) ---
container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${1}$"
}

get_arr_api_key() {
  local container="$1"
  container_running "$container" || return 1
  # sed rather than grep -P, which BSD grep lacks, so the tests run on macOS.
  docker exec "$container" cat /config/config.xml 2>/dev/null \
    | sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' || return 1
}

SONARR_KEY=$(get_arr_api_key sonarr) || true
RADARR_KEY=$(get_arr_api_key radarr) || true

if [[ -z "$SONARR_KEY" ]] && [[ -z "$RADARR_KEY" ]]; then
  log "ERROR: Could not read Sonarr's or Radarr's API key. Are the containers running?"
  exit 1
fi

# The python below writes the Home Assistant notice here, since only it knows
# what the run found. An empty file means nothing to post.
NOTICE_FILE=$(mktemp)
trap 'rm -f "$NOTICE_FILE"' EXIT

# --- Main check (python3 for JSON processing) ---
python3 - "$VERBOSE" "$TEST" "$APPLY" "$SONARR_KEY" "$RADARR_KEY" "$NOTICE_FILE" "$NAS_STACK_DIR" << 'PYEOF'
import json, subprocess, sys

VERBOSE = sys.argv[1] == "true"
TEST = sys.argv[2] == "true"
APPLY = sys.argv[3] == "true"
SONARR_KEY, RADARR_KEY = sys.argv[4:6]
NOTICE_FILE = sys.argv[6]
NAS_STACK_DIR = sys.argv[7]

SONARR = ("http://localhost:8989", SONARR_KEY)
RADARR = ("http://localhost:7878", RADARR_KEY)

def verbose(msg):
    if VERBOSE:
        print(f"  [verbose] {msg}")

def api_get(base, path, timeout=60):
    """GET JSON with the app's API key in a header, so it never lands in a
    log line. None on any failure (HTTP >= 400 included)."""
    url, key = base[0] + path, base[1]
    result = subprocess.run(
        ["curl", "-s", "-f", "-m", str(timeout), "-H", f"X-Api-Key: {key}", url],
        capture_output=True, text=True, timeout=timeout + 10)
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except ValueError:
        return None

def api_post_json(base, path, data):
    url, key = base[0] + path, base[1]
    result = subprocess.run(
        ["curl", "-s", "-f", "-m", "30", "-X", "POST", "-H", f"X-Api-Key: {key}",
         "-H", "Content-Type: application/json", "-d", json.dumps(data), url],
        capture_output=True, text=True, timeout=40)
    return result.returncode == 0

def plural(n, word):
    return f"{n} {word}" if n == 1 else f"{n} {word}s"

# Each problem: what mediainfo shows, what a viewer sees, and whether the
# app's own search can replace the file (only when its score drops for it).
PROFILE5 = "Dolby Vision Profile 5"
DTS61 = "DTS 6.1"
EFFECT = {
    PROFILE5: "no HDR10 fallback, so the picture is green and magenta",
    DTS61: "the Jellyfin client on a Fire TV stops at once",
}

def problems(media):
    """The problems in one file's mediainfo, [] when it has none."""
    found = []
    if (media.get("videoDynamicRangeType") or "").strip() == "DV":
        found.append(PROFILE5)
    codec = (media.get("audioCodec") or "").upper()
    try:
        channels = float(media.get("audioChannels") or 0)
    except (TypeError, ValueError):
        channels = 0
    if codec.startswith("DTS") and abs(channels - 6.1) < 0.01:
        found.append(DTS61)
    return found

findings = []        # {app, title, what, problems, scene}
searches_queued = []

# --------------------------------------------------------------- Sonarr ---
if SONARR_KEY:
    print("\n--- Sonarr ---")
    series_all = api_get(SONARR, "/api/v3/series")
    if series_all is None:
        print("  ✗ Failed to fetch Sonarr's series; TV not checked")
        series_all = []
    files_judged = no_media = 0
    for s in sorted(series_all, key=lambda s: s.get("sortTitle") or s.get("title") or ""):
        if not (s.get("statistics") or {}).get("episodeFileCount", 1):
            continue
        files = api_get(SONARR, f"/api/v3/episodefile?seriesId={s['id']}")
        if files is None:
            print(f"  ✗ Failed to fetch {s.get('title', '?')}'s files")
            continue
        bad = []
        for f in files:
            media = f.get("mediaInfo")
            if not media:
                no_media += 1
                continue
            files_judged += 1
            found = problems(media)
            if found:
                bad.append((f, found))
        if not bad:
            continue
        # The file's episodes, for the line and for the search.
        eps_by_file = {}
        for e in api_get(SONARR, f"/api/v3/episode?seriesId={s['id']}") or []:
            if e.get("episodeFileId"):
                eps_by_file.setdefault(e["episodeFileId"], []).append(e)
        for f, found in bad:
            eps = sorted(eps_by_file.get(f["id"], []), key=lambda e: e.get("episodeNumber", 0))
            code = "-".join(f"S{e.get('seasonNumber', 0):02d}E{e.get('episodeNumber', 0):02d}" for e in eps) \
                or f"season {f.get('seasonNumber', '?')}"
            finding = {"app": "Sonarr", "title": f"{s.get('title', '?')} {code}", "problems": found,
                       "scene": f.get("sceneName") or f.get("relativePath") or "?", "searched": False}
            if APPLY and PROFILE5 in found and eps:
                if api_post_json(SONARR, "/api/v3/command",
                                 {"name": "EpisodeSearch", "episodeIds": [e["id"] for e in eps]}):
                    finding["searched"] = True
                    searches_queued.append(finding["title"])
                else:
                    print(f"  ✗ Could not queue a search for {finding['title']}")
            findings.append(finding)
            print(f"  ⚠ {finding['title']}: {', '.join(found)} ({finding['scene'][:80]})")
    sonarr_found = sum(1 for f in findings if f["app"] == "Sonarr")
    print(f"  - {plural(files_judged, 'file')} judged, {sonarr_found} to replace"
          + (f"; {no_media} with no mediainfo, not judged" if no_media else ""))

# --------------------------------------------------------------- Radarr ---
if RADARR_KEY:
    print("\n--- Radarr ---")
    movies = api_get(RADARR, "/api/v3/movie", timeout=120)
    if movies is None:
        print("  ✗ Failed to fetch Radarr's movies; films not checked")
        movies = []
    files_judged = no_media = 0
    radarr_before = len(findings)
    for m in sorted(movies, key=lambda m: m.get("sortTitle") or m.get("title") or ""):
        f = m.get("movieFile")
        if not f:
            continue
        media = f.get("mediaInfo")
        if not media:
            no_media += 1
            continue
        files_judged += 1
        found = problems(media)
        if not found:
            continue
        title = m.get("title", "?") + (f" ({m['year']})" if m.get("year") else "")
        finding = {"app": "Radarr", "title": title, "problems": found,
                   "scene": f.get("sceneName") or f.get("relativePath") or "?", "searched": False}
        if APPLY and PROFILE5 in found:
            if api_post_json(RADARR, "/api/v3/command", {"name": "MoviesSearch", "movieIds": [m["id"]]}):
                finding["searched"] = True
                searches_queued.append(title)
            else:
                print(f"  ✗ Could not queue a search for {title}")
        findings.append(finding)
        print(f"  ⚠ {title}: {', '.join(found)} ({finding['scene'][:80]})")
    print(f"  - {plural(files_judged, 'file')} judged, {len(findings) - radarr_before} to replace"
          + (f"; {no_media} with no mediainfo, not judged" if no_media else ""))

# -------------------------------------------------------------- Summary ---
print(f"\n{'=' * 40}")
print(f"Summary: {plural(len(findings), 'file')} to replace")
if searches_queued:
    print(f"Searches queued: {len(searches_queued)} ({', '.join(searches_queued)})")

def advice(f):
    effect = "; ".join(f"{p}: {EFFECT[p]}" for p in f["problems"])
    if f["searched"]:
        todo = "Search queued for a release without it; if it is still here next week, only a lower resolution exists, so pick one by hand."
    elif PROFILE5 in f["problems"]:
        todo = "Search for it in the app (--apply queues that); if nothing comes, pick a lower resolution by hand."
    else:
        todo = "Replace it by hand from the interactive search; the app's own search won't, as the file still scores 0."
    return f"{effect}. {todo}"

def notice_for(findings):
    """One notice for the panel: a line per file, title first, then what is
    wrong and what to do. Capped so a bad week still reads."""
    lines = [f"• {f['title']} ({f['app']}): {advice(f)}" for f in findings[:8]]
    if len(findings) > 8:
        lines.append(f"…and {len(findings) - 8} more in {NAS_STACK_DIR}/logs/check-playback-formats.log")
    return {
        "title": f"Unplayable files: {plural(len(findings), 'file')} to replace",
        "message": "\n".join(lines),
        "level": "info",
        "tag": "playback-formats",
    }

if TEST:
    notice = {
        "title": "Playback-format check: test",
        "message": (f"The weekly playback-format check can reach Home Assistant. Nothing to do. "
                    f"(This run found {plural(len(findings), 'file')} to replace.)"),
        "level": "info",
        "tag": "playback-formats",
    }
elif findings:
    notice = notice_for(findings)
else:
    notice = None

if notice is not None:
    with open(NOTICE_FILE, "w") as fh:
        json.dump(notice, fh, ensure_ascii=False)
PYEOF

# --- Home Assistant notice ---
if [[ ! -s "$NOTICE_FILE" ]]; then
  echo "Notice: nothing to post"
elif $POST; then
  if curl -s -m 10 -f -X POST "$HA_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      --data-binary "@$NOTICE_FILE" > /dev/null; then
    # HA answers 200 to any webhook id, so this proves the POST reached HA,
    # not that the automation rendered it. Check the panel.
    echo "Notice: posted to Home Assistant at $(date '+%Y-%m-%d %H:%M:%S %Z') (check the panel)"
  else
    echo "Notice: POST to Home Assistant FAILED"
    exit 1
  fi
else
  echo "Notice: would post (dry run; use --post):"
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print("  " + d["title"]); print("  " + d["message"].replace("\n", "\n  "))' "$NOTICE_FILE"
fi

# --- Trim log file ---
if [[ -f "$LOG_FILE" ]]; then
  LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$LINES" -gt "$MAX_LOG_LINES" ]]; then
    TMPLOG=$(mktemp)
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$TMPLOG" && mv "$TMPLOG" "$LOG_FILE"
  fi
fi
