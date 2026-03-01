#!/bin/bash
set -euo pipefail
#
# Fix Radarr movie paths after TRaSH naming reorganize
#
# When TRaSH naming is applied and "Organize" is run, Radarr renames directories
# on disk (e.g., "Avatar The Way of Water" → "Avatar - The Way of Water") but
# sometimes the database paths don't update. This causes "MissingFromDisk" errors.
#
# This script compares Radarr's database paths against actual directories on disk,
# fixes any mismatches via the Radarr API, and triggers a refresh.
#
# Usage:
#   ./scripts/fix-radarr-paths.sh
#
# Prerequisites:
#   - Radarr running and accessible on localhost:7878
#   - RADARR_API_KEY set in .env
#   - python3 available
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env not found at $ENV_FILE"
  exit 1
fi

RADARR_API_KEY=$(grep "^RADARR_API_KEY=" "$ENV_FILE" | cut -d= -f2)
if [ -z "$RADARR_API_KEY" ]; then
  echo "ERROR: RADARR_API_KEY not found in .env"
  exit 1
fi

MEDIA_ROOT=$(grep "^MEDIA_ROOT=" "$ENV_FILE" | cut -d= -f2)
MOVIES_DIR="${MEDIA_ROOT}/media/movies"

if [ ! -d "$MOVIES_DIR" ]; then
  echo "ERROR: Movies directory not found at $MOVIES_DIR"
  exit 1
fi

echo "=== Radarr Path Fixer ==="
echo "Movies dir: $MOVIES_DIR"
echo ""

# Use unique temp files (avoids /tmp sticky-bit issues across users)
TMPDIR=$(mktemp -d /tmp/fix-radarr-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Dump current state
curl -s "http://localhost:7878/api/v3/movie?apikey=${RADARR_API_KEY}" > "$TMPDIR/movies.json"
ls -1 "$MOVIES_DIR" > "$TMPDIR/disk_dirs.txt"

# Run the fix
python3 - "$RADARR_API_KEY" "$TMPDIR" << 'PYEOF'
import json, os, re, sys, subprocess

KEY = sys.argv[1]
TMPDIR = sys.argv[2]

with open(os.path.join(TMPDIR, "movies.json")) as f:
    movies = json.load(f)

with open(os.path.join(TMPDIR, "disk_dirs.txt")) as f:
    disk_dirs = set(line.strip() for line in f if line.strip())

def normalize(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())

def normalize_no_articles(s):
    s = re.sub(r"[^a-z0-9 ]", "", s.lower()).strip()
    s = re.sub(r"^(the|a|an)\s+", "", s)
    s = re.sub(r",?\s*(the|a|an)$", "", s)
    return re.sub(r"\s+", "", s)

fixed = 0
already_ok = 0
no_match = 0

for m in movies:
    path = m.get("path", "")
    dirname = os.path.basename(path)

    if dirname in disk_dirs:
        already_ok += 1
        continue

    if m.get("hasFile", False):
        already_ok += 1
        continue

    year = str(m.get("year", ""))
    candidates = [d for d in disk_dirs if "(%s)" % year in d]

    match = None

    # Exact normalized match
    norm_dirname = normalize(dirname)
    for c in candidates:
        if normalize(c) == norm_dirname:
            match = c
            break

    # Article-agnostic match
    if not match:
        norm_no_art = normalize_no_articles(dirname)
        for c in candidates:
            if normalize_no_articles(c) == norm_no_art:
                match = c
                break

    # Title-only match (strip year)
    if not match:
        title_part = re.sub(r"\s*\(\d{4}\)\s*$", "", dirname)
        norm_title = normalize_no_articles(title_part)
        for c in candidates:
            c_title = re.sub(r"\s*\(\d{4}\)\s*$", "", c)
            if normalize_no_articles(c_title) == norm_title:
                match = c
                break

    if match:
        new_path = "/data/media/movies/%s" % match
        m["path"] = new_path

        update_file = os.path.join(TMPDIR, "update.json")
        with open(update_file, "w") as f:
            json.dump(m, f)

        result = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "-X", "PUT",
             "http://127.0.0.1:7878/api/v3/movie/%s?apikey=%s" % (m["id"], KEY),
             "-H", "Content-Type: application/json",
             "-d", "@%s" % update_file],
            capture_output=True, text=True
        )
        code = result.stdout.strip()
        if code in ("200", "202"):
            print("  Fixed: %s -> %s" % (dirname, match))
            fixed += 1
        else:
            print("  FAILED (%s): %s -> %s" % (code, dirname, match))
    else:
        no_match += 1

print("")
print("Summary: %d fixed, %d already correct, %d no match on disk" % (fixed, already_ok, no_match))

if fixed > 0:
    print("")
    print("Triggering Radarr refresh...")
    subprocess.run(
        ["curl", "-s", "-X", "POST",
         "http://127.0.0.1:7878/api/v3/command?apikey=%s" % KEY,
         "-H", "Content-Type: application/json",
         "-d", '{"name":"RefreshMovie"}'],
        capture_output=True
    )
    print("Done. Wait ~30 seconds for Radarr to rescan, then check the Health page.")
else:
    print("No fixes needed.")
PYEOF

# Cleanup handled by EXIT trap
