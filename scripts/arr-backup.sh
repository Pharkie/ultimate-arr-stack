#!/bin/bash
set -euo pipefail
#
# Backup essential Docker named volumes for arr-stack, plus consistent copies
# of the Sonarr, Radarr and Jellyfin databases
#
# Usage:
#   ./scripts/arr-backup.sh [OPTIONS] [BACKUP_DIR]
#
# Options:
#   --tar           Create a .tar.gz archive (recommended for off-NAS transfer)
#   --encrypt       Encrypt tarball with GPG symmetric encryption (requires --tar).
#                   The archive is then named .tar.gz.gpg, wherever it ends up.
#   --prefix NAME   Volume prefix (default: auto-detect from running containers)
#   --usb DIR_NAME  Dynamically find USB device under /mnt/@usb/sd*/ containing DIR_NAME
#                   (device letters change on reboot, so never hardcode e.g. /mnt/@usb/sdd1)
#
# Environment:
#   ARR_BACKUP_STAGING_ROOT  Where the working copy is built (default: /tmp).
#                            Tests point it at a throwaway directory.
#   ARR_BACKUP_API_TIMEOUT   Seconds to wait for Sonarr's or Radarr's Backup
#                            command to finish (default: 300).
#
# Exit status: non-zero if anything failed to back up. The archive is still
# written with everything that succeeded, so a bad volume never costs the rest.
#
# Examples:
#   ./scripts/arr-backup.sh --tar                     # Backup to /tmp, create tarball
#   ./scripts/arr-backup.sh --tar --encrypt           # Backup + GPG encrypt
#   ./scripts/arr-backup.sh --tar ~/backups           # Backup to custom dir with tarball
#   ./scripts/arr-backup.sh --tar --usb arr-backups   # Auto-find USB, save to arr-backups/
#   ./scripts/arr-backup.sh --prefix media-stack      # Use custom volume prefix
#
# Pulling backup to another machine:
#   # Ugreen NAS (scp doesn't work with /tmp, use cat pipe):
#   ssh user@nas "cat /tmp/arr-stack-backup-*.tar.gz" > ./backup.tar.gz
#
#   # Other systems (scp works normally):
#   scp user@nas:/tmp/arr-stack-backup-*.tar.gz ./backup.tar.gz
#
# Restoring a volume:
#   docker run --rm -v ./backup/gluetun-config:/source:ro \
#     -v PREFIX_gluetun-config:/dest alpine cp -a /source/. /dest/
#   Sonarr, Radarr and Jellyfin restore differently: see docs/RESTORE.md.
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. It reads Docker volumes (read-only),
#     asks Sonarr and Radarr through their API to make a backup and deletes
#     that backup through the same API once it has a copy, writes the backup,
#     and deletes its own backups older than 7 days at the destination.
#

# --- Failure notifications via Home Assistant webhook ---
notify_failure() {
  local msg="${1:-Backup failed}"
  echo "ERROR: ${msg}"
  if [ -n "${HA_WEBHOOK_URL:-}" ]; then
    curl -s -m 10 -X POST "$HA_WEBHOOK_URL" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"Arr Stack: Backup Failed\",\"message\":\"${msg}\",\"level\":\"critical\"}" || true
  fi
}
STEP="initialising"
trap 'notify_failure "Failed during: ${STEP}. Check /var/log/arr-backup.log"' ERR

# Derive stack directory from script location (scripts/ is one level below stack root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAS_STACK_DIR="$(dirname "$SCRIPT_DIR")"

# Cron hands the script no environment and nothing else loads .env, so read
# the alert webhook from it here. Without this, alerts never went anywhere.
if [ -z "${HA_WEBHOOK_URL:-}" ] && [ -f "$NAS_STACK_DIR/.env" ]; then
  HA_WEBHOOK_URL=$(sed -n 's/^HA_WEBHOOK_URL=//p' "$NAS_STACK_DIR/.env" | tail -n 1 | tr -d "\"'")
fi

# Ensure critical services are running on ANY exit (normal, error, or interrupt)
ensure_services_running() {
  COMPOSE_FILE="$NAS_STACK_DIR/docker-compose.arr-stack.yml"
  [ -f "$COMPOSE_FILE" ] || return 0

  CRITICAL="gluetun pihole sonarr radarr prowlarr qbittorrent jellyfin sabnzbd"
  STOPPED=""

  for svc in $CRITICAL; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${svc}$"; then
      STOPPED="$STOPPED $svc"
    fi
  done

  if [ -n "$STOPPED" ]; then
    echo ""
    echo "SAFETY: Ensuring services are running:$STOPPED"
    docker compose -f "$COMPOSE_FILE" up -d $STOPPED 2>/dev/null
  fi
}
trap 'ensure_services_running' EXIT

# Find USB backup directory dynamically (device letters change on reboot)
# Searches /mnt/@usb/sd*/ for a subdirectory matching the given name,
# falling back to the first non-empty mounted device.
find_usb_dir() {
  local dir_name="$1"
  local usb_base="/mnt/@usb"

  # First: look for an existing backup directory by name
  for dev in "$usb_base"/sd*/; do
    [ -d "$dev" ] || continue
    if [ -d "$dev$dir_name" ]; then
      echo "$dev$dir_name"
      return 0
    fi
  done

  # Fallback: first non-empty mounted USB device
  for dev in "$usb_base"/sd*/; do
    [ -d "$dev" ] || continue
    # Check it's actually mounted (not just an empty mount point)
    if [ "$(ls -A "$dev" 2>/dev/null)" ]; then
      echo "$dev$dir_name"
      return 0
    fi
  done

  echo "ERROR: No USB device found under $usb_base" >&2
  return 1
}

# --- Databases that are written while the stack runs ---
#
# Sonarr, Radarr and Jellyfin keep live SQLite databases in WAL mode. A file
# copy taken while they write can pair a half-checkpointed .db with the wrong
# -wal: on a throwaway volume under a busy writer, 26 of 30 slowed file copies
# came out torn (2026-09-29). So none of the three is copied as files:
#   - Sonarr/Radarr: the app's own Backup command, which writes config.xml and
#     the database (via SQLite's online backup API) into a zip.
#   - Jellyfin: SQLite's online backup API run here, from a read-only mount.
#     Jellyfin 12's own /Backup/Create needs an admin API key the stack does
#     not hold, has no delete endpoint (its zips would pile up in the volume)
#     and dumps tables as JSON that only its own restore can read.
# Every database copy is then checked with PRAGMA integrity_check.

# The helper runs in this image: python3's sqlite3 module, since none of the
# app images ships an sqlite3 binary. Official image, pulled once and cached.
DB_IMAGE="python:3.13-alpine"
ARR_API_TIMEOUT="${ARR_BACKUP_API_TIMEOUT:-300}"

#   tree SRC DST UID:GID  copy a Jellyfin config volume, less what Jellyfin
#                         rebuilds; every SQLite database goes through the
#                         online backup API and is integrity-checked
#   zip FILE              check an *arr backup zip: config.xml, and a database
#                         that passes integrity_check
IFS= read -r -d '' DB_HELPER <<'PY' || true
import os, shutil, sqlite3, sys, tempfile, time, urllib.parse, zipfile

MAGIC = b"SQLite format 3\x00"
# Jellyfin rebuilds these: images, caches, logs, extracted subtitles and fonts,
# and its own pre-migration and backup copies.
SKIP = {
    "": {"metadata", "log", "cache", "transcodes"},
    "data": {"subtitles", "attachments", "trickplay", "keyframes",
             "SQLiteBackups", "backups", "splashscreen.png"},
}


def fail(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(1)


def is_sqlite(path):
    try:
        with open(path, "rb") as f:
            return f.read(16) == MAGIC
    except OSError:
        return False


def check(path, label):
    try:
        con = sqlite3.connect(path)
        try:
            rows = con.execute("PRAGMA integrity_check").fetchall()
        finally:
            con.close()
    except sqlite3.DatabaseError as e:
        rows = [(str(e),)]
    if rows != [("ok",)]:
        fail("%s: integrity_check: %s" % (label, "; ".join(r[0] for r in rows[:3])))


def snapshot(src, dst):
    # One backup step is one read transaction, so one consistent snapshot while
    # the app keeps writing. A read-only mount can open a WAL database only
    # while its -wal exists, i.e. while the app has it open. With no -wal
    # nothing has it open and the file is already complete: read it immutable.
    for attempt in range(1, 6):
        mode = "ro" if os.path.exists(src + "-wal") else "ro&immutable=1"
        uri = "file:%s?mode=%s" % (urllib.parse.quote(src), mode)
        try:
            s = sqlite3.connect(uri, uri=True, timeout=30)
            d = sqlite3.connect(dst)
            try:
                s.backup(d)
            finally:
                d.close()
                s.close()
            return
        except sqlite3.DatabaseError as e:
            if os.path.exists(dst):
                os.remove(dst)
            # Busy or locked can pass; anything else will not
            if attempt == 5 or not isinstance(e, sqlite3.OperationalError):
                fail("%s: %s" % (src, e))
            time.sleep(2)


def tree(src, dst, owner):
    dbs = []

    def ignore(d, names):
        rel = os.path.relpath(d, src)
        rel = "" if rel == "." else rel
        out = SKIP.get(rel, set()) & set(names)
        for n in names:
            p = os.path.join(d, n)
            if n.endswith(("-wal", "-shm", "-journal")) and n.rsplit("-", 1)[0] in names:
                out.add(n)
            elif os.path.isfile(p) and not os.path.islink(p) and is_sqlite(p):
                out.add(n)
                dbs.append(os.path.join(rel, n))
        return out

    try:
        shutil.copytree(src, dst, symlinks=True, ignore=ignore, dirs_exist_ok=True)
        if not dbs:
            fail("%s: no SQLite database found" % src)
        for rel in dbs:
            snapshot(os.path.join(src, rel), os.path.join(dst, rel))
            check(os.path.join(dst, rel), rel)
    except BaseException:
        # Never leave a half copy that looks like a backup.
        shutil.rmtree(dst, ignore_errors=True)
        raise
    uid, gid = (int(x) for x in owner.split(":"))
    for root, dirs, files in os.walk(dst):
        for p in [root] + [os.path.join(root, n) for n in dirs + files]:
            os.lchown(p, uid, gid)
    print(" ".join(dbs))


def check_zip(path):
    name = os.path.basename(path)
    try:
        z = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as e:
        fail("%s: %s" % (name, e))
    with z:
        names = z.namelist()
        dbs = [n for n in names if n.endswith(".db")]
        if "config.xml" not in names or not dbs:
            fail("%s: expected config.xml and a .db, found %s" % (name, names))
        bad = z.testzip()
        if bad:
            fail("%s: corrupt entry %s" % (name, bad))
        with tempfile.TemporaryDirectory() as t:
            for n in dbs:
                check(z.extract(n, t), n)
    print(" ".join(dbs))


if sys.argv[1] == "tree":
    tree(sys.argv[2], sys.argv[3], sys.argv[4])
elif sys.argv[1] == "zip":
    check_zip(sys.argv[2])
else:
    fail("usage: tree SRC DST UID:GID | zip FILE")
PY

# The value of <NAME> in an XML document
xml_value() {
  printf '%s\n' "$2" | sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p"
}

# The last value of a field in a JSON document (stdin). The *arr API lists a
# resource's own id after the fields nested in it. No jq on a stock NAS.
json_last() {
  tr -d '\n' | sed -n -e "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" -e t \
    -e "s/.*\"$1\": *\([^\", }]*\).*/\1/p"
}

# GET system/backup (stdin) as one "TYPE ID NAME" line per backup
backup_rows() {
  local obj name
  tr -d '\n' | tr '}' '\n' | while IFS= read -r obj; do
    name=$(printf '%s' "$obj" | json_last name)
    [ -n "$name" ] || continue
    echo "$(printf '%s' "$obj" | json_last type) $(printf '%s' "$obj" | json_last id) $name"
  done
}

# Call an *arr's own API from inside its container, so it works whatever
# ports are published: arr_api APP METHOD PATH [JSON]
arr_api() {
  if [ -n "${4:-}" ]; then
    docker exec "$1" curl -sSf -m 30 -X "$2" -H "X-Api-Key: $ARR_API_KEY" \
      -H "Content-Type: application/json" -d "$4" "$ARR_API_URL/$3"
  else
    docker exec "$1" curl -sSf -m 30 -X "$2" -H "X-Api-Key: $ARR_API_KEY" "$ARR_API_URL/$3"
  fi
}

# Sonarr/Radarr: run the app's Backup command, copy the zip it wrote, delete
# it through the API (manual backups never rotate, so every night's would stay
# in the volume), then check the copy. Prints OK/FAILED; non-zero on failure.
backup_arr() {
  local app="$1" dest="$3"
  local cfg before rows cmd status waited=0 type id name found="" folder dbs
  local copied=true deleted=true

  if ! cfg=$(docker exec "$app" cat /config/config.xml); then
    echo "FAILED ($app is not running)"
    return 1
  fi
  ARR_API_KEY=$(xml_value ApiKey "$cfg")
  ARR_API_URL="http://localhost:$(xml_value Port "$cfg")$(xml_value UrlBase "$cfg")/api/v3"
  if [ -z "$ARR_API_KEY" ]; then
    echo "FAILED (no ApiKey in $app's config.xml)"
    return 1
  fi

  if ! before=$(arr_api "$app" GET system/backup | backup_rows); then
    echo "FAILED ($app's API did not answer)"
    return 1
  fi
  if ! cmd=$(arr_api "$app" POST command '{"name":"Backup"}' | json_last id) || [ -z "$cmd" ]; then
    echo "FAILED ($app refused the Backup command)"
    return 1
  fi
  while :; do
    status=$(arr_api "$app" GET "command/$cmd" | json_last status) || status=""
    case "$status" in
      completed) break ;;
      failed|aborted|cancelled|orphaned)
        echo "FAILED ($app's Backup command $status)"
        return 1 ;;
    esac
    if [ "$waited" -ge "$ARR_API_TIMEOUT" ]; then
      echo "FAILED ($app's Backup command not finished after ${ARR_API_TIMEOUT}s)"
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done

  # This run's zip: the manual backup that was not listed before it
  if ! rows=$(arr_api "$app" GET system/backup | backup_rows); then
    echo "FAILED ($app's API did not answer)"
    return 1
  fi
  while read -r type id name; do
    [ "$type" = manual ] || continue
    grep -qxF -- "$type $id $name" <<< "$before" && continue
    found="$id $name"
    break
  done <<EOF
$rows
EOF
  if [ -z "$found" ]; then
    echo "FAILED ($app's Backup command finished but listed no new backup)"
    return 1
  fi
  id=${found%% *}
  name=${found#* }

  folder=$(arr_api "$app" GET config/host | json_last backupFolder) || folder=""
  case "$folder" in
    /*) ;;
    *) folder="/config/${folder:-Backups}" ;;
  esac
  mkdir -p "$dest"
  docker exec "$app" cat "$folder/manual/$name" > "$dest/$name" || copied=false
  arr_api "$app" DELETE "system/backup/$id" >/dev/null || deleted=false

  if ! $copied; then
    rm -rf "$dest"
    echo "FAILED (could not read $folder/manual/$name)"
    return 1
  fi
  if ! dbs=$(docker run --rm -v "$dest":/check:ro "$DB_IMAGE" \
      python3 -c "$DB_HELPER" zip "/check/$name"); then
    rm -rf "$dest"
    echo "FAILED ($name did not pass its check)"
    return 1
  fi
  if ! $deleted; then
    echo "FAILED (backed up, but $name is still in $app: delete it under System > Backup)"
    return 1
  fi
  echo "OK ($(du -sh "$dest" | cut -f1 | tr -d " "), $dbs integrity ok)"
}

# Jellyfin: config, library definitions, plugins and the database snapshot;
# not metadata/images, caches or logs. Prints OK/FAILED; non-zero on failure.
backup_jellyfin() {
  local vol="$2" dest="$3" dbs
  if ! dbs=$(docker run --rm --name arr-backup-worker \
      -v "$vol":/source:ro \
      -v "$BACKUP_DIR":/backup \
      "$DB_IMAGE" python3 -c "$DB_HELPER" tree /source "/backup/$(basename "$dest")" \
      "$CURRENT_UID:$CURRENT_GID"); then
    echo "FAILED (database snapshot or copy failed)"
    return 1
  fi
  echo "OK ($(du -sh "$dest" | cut -f1 | tr -d " "), $dbs integrity ok)"
}

# Parse arguments
CREATE_TAR=false
ENCRYPT=false
BACKUP_DIR=""
VOLUME_PREFIX=""
USB_DIR_NAME=""
TARBALL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --tar)
      CREATE_TAR=true
      shift
      ;;
    --encrypt)
      ENCRYPT=true
      shift
      ;;
    --prefix)
      VOLUME_PREFIX="$2"
      shift 2
      ;;
    --usb)
      USB_DIR_NAME="$2"
      shift 2
      ;;
    *)
      BACKUP_DIR="$1"
      shift
      ;;
  esac
done

if $ENCRYPT && ! $CREATE_TAR; then
  echo "ERROR: --encrypt requires --tar"
  exit 1
fi

if $ENCRYPT && ! command -v gpg &>/dev/null; then
  echo "ERROR: gpg not found. Install gnupg to use --encrypt."
  exit 1
fi

# Resolve USB backup directory if --usb was specified
STEP="finding USB device"
if [ -n "$USB_DIR_NAME" ]; then
  BACKUP_DIR=$(find_usb_dir "$USB_DIR_NAME") || { notify_failure "Failed during: ${STEP}. No USB device found under /mnt/@usb/"; exit 1; }
  echo "USB device found: $BACKUP_DIR"
  mkdir -p "$BACKUP_DIR"
fi

STEP="detecting volume prefix"
# Auto-detect volume prefix from running containers if not specified
if [ -z "$VOLUME_PREFIX" ]; then
  # Try to find prefix from gluetun container's volumes
  VOLUME_PREFIX=$(docker inspect gluetun 2>/dev/null | grep -o '"[^"]*_gluetun-config"' | head -1 | tr -d '"' | sed 's/_gluetun-config$//' || true)

  # Fallback: check for any arr-stack-like volumes
  if [ -z "$VOLUME_PREFIX" ]; then
    VOLUME_PREFIX=$(docker volume ls --format '{{.Name}}' | grep -o '^[^_]*' | grep -E 'arr-stack|media' | head -1 || true)
  fi

  # Final fallback
  if [ -z "$VOLUME_PREFIX" ]; then
    VOLUME_PREFIX="arr-stack"
    echo "Warning: Could not auto-detect volume prefix, using '$VOLUME_PREFIX'"
    echo "         Use --prefix to specify if your volumes have a different prefix"
    echo ""
  fi
fi

# Backup location handling:
# - Always create backup in /tmp first (reliable space)
# - If destination specified and different from /tmp, move tarball there after checking space
STAGING_ROOT="${ARR_BACKUP_STAGING_ROOT:-/tmp}"
FINAL_DEST="${BACKUP_DIR:-}"
BACKUP_DIR="$STAGING_ROOT/arr-stack-backup-$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"

# Rotate old backups at final destination (keep 7 days), encrypted ones included
KEEP_DAYS=7
if [ -n "$FINAL_DEST" ] && [ -d "$FINAL_DEST" ]; then
  find "$FINAL_DEST" -maxdepth 1 -name "arr-stack-backup-*" -type d -mtime +$KEEP_DAYS -exec rm -rf {} \;
  find "$FINAL_DEST" -maxdepth 1 -name "arr-stack-backup-*.tar.gz" -type f -mtime +$KEEP_DAYS -delete
  find "$FINAL_DEST" -maxdepth 1 -name "arr-stack-backup-*.tar.gz.gpg" -type f -mtime +$KEEP_DAYS -delete
fi

# Get current user for ownership fix (avoids needing sudo for tar)
CURRENT_UID=$(id -u)
CURRENT_GID=$(id -g)

# Essential volumes only (small, hard to recreate)
# These are settings/configs that would require manual reconfiguration if lost
VOLUME_SUFFIXES=(
  gluetun-config          # VPN provider credentials and settings
  qbittorrent-config      # Client settings, categories, watched folders
  sabnzbd-config          # Usenet provider credentials and settings
  prowlarr-config         # Indexer configs and API keys
  bazarr-config           # Subtitle provider credentials
  uptime-kuma-data        # Monitor configurations
)

# Request manager - detect which volume exists
if docker volume inspect "${VOLUME_PREFIX}_seerr-config" &>/dev/null; then
  VOLUME_SUFFIXES+=(seerr-config)
elif docker volume inspect "${VOLUME_PREFIX}_overseerr-config" &>/dev/null; then
  VOLUME_SUFFIXES+=(overseerr-config)
fi

# Backed up separately below, as consistent database copies (never as files):
#   sonarr-config, radarr-config - the app's own backup zip (config.xml + DB)
#   jellyfin-config - config, library definitions, plugins, DB snapshot
#                     (not metadata/images, logs, extracted subtitles)
#
# Excluded (regenerate by re-downloading):
#   pihole-etc-pihole (138MB) - blocklists auto-download on startup
#   jellyfin-cache          - transcoding cache, fully regenerates
#   duc-index               - disk usage index, regenerates on restart

STEP="backing up .env"
echo "=== Arr-Stack Backup ==="
echo "Volume prefix: ${VOLUME_PREFIX}_*"
echo "Backup dir:    $BACKUP_DIR"
echo ""

BACKED_UP=0
SKIPPED=0
FAILED=0

# Back up .env (contains secrets: VPN credentials, API keys, passwords)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [ -f "$ENV_FILE" ]; then
  echo -n "Backing up .env... "
  if cp "$ENV_FILE" "$BACKUP_DIR/dot-env" 2>/dev/null; then
    chmod 600 "$BACKUP_DIR/dot-env"
    echo "OK"
    BACKED_UP=$((BACKED_UP + 1))
  else
    echo "FAILED"
    FAILED=$((FAILED + 1))
  fi
else
  echo "Skipping .env (not found at $ENV_FILE)"
  SKIPPED=$((SKIPPED + 1))
fi

STEP="backing up volumes"

for suffix in "${VOLUME_SUFFIXES[@]}"; do
  vol="${VOLUME_PREFIX}_${suffix}"

  if docker volume inspect "$vol" &>/dev/null; then
    echo -n "Backing up $suffix... "

    # Copy files and fix ownership in one container run
    # The chown ensures we can tar without sudo later
    if docker run --rm --name arr-backup-worker \
      -v "$vol":/source:ro \
      -v "$BACKUP_DIR":/backup \
      alpine sh -c "mkdir -p /backup/$suffix && cp -a /source/. /backup/$suffix/ && chown -R $CURRENT_UID:$CURRENT_GID /backup/$suffix" 2>/dev/null; then

      # Check if anything was actually copied
      if [ -d "$BACKUP_DIR/$suffix" ] && [ "$(ls -A "$BACKUP_DIR/$suffix" 2>/dev/null)" ]; then
        SIZE=$(du -sh "$BACKUP_DIR/$suffix" 2>/dev/null | cut -f1)
        echo "OK ($SIZE)"
        BACKED_UP=$((BACKED_UP + 1))
      else
        echo "OK (empty)"
        BACKED_UP=$((BACKED_UP + 1))
      fi
    else
      echo "FAILED (permission denied or volume error)"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "Skipping $suffix (volume not found)"
    SKIPPED=$((SKIPPED + 1))
  fi
done

STEP="backing up databases"

for app in sonarr radarr jellyfin; do
  suffix="${app}-config"
  vol="${VOLUME_PREFIX}_${suffix}"

  if ! docker volume inspect "$vol" &>/dev/null; then
    echo "Skipping $suffix (volume not found)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo -n "Backing up $suffix... "
  if [ "$app" = jellyfin ]; then
    backup_fn=backup_jellyfin
  else
    backup_fn=backup_arr
  fi
  # The function's last line is its OK/FAILED; anything the tools printed on
  # the way (curl, docker, the helper) goes underneath it, indented.
  if result=$("$backup_fn" "$app" "$vol" "$BACKUP_DIR/$suffix" 2>&1); then
    BACKED_UP=$((BACKED_UP + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  printf '%s\n' "${result##*$'\n'}"
  if [ "${result%$'\n'*}" != "$result" ]; then
    printf '%s\n' "${result%$'\n'*}" | sed 's/^/    /'
  fi
done

echo ""
echo "Summary: $BACKED_UP backed up, $SKIPPED skipped, $FAILED failed"
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
echo "Total size: $TOTAL_SIZE"

# Warn about failures now; the exit status reports them once the archive of
# everything else is written.
if [ $FAILED -gt 0 ]; then
  echo ""
  echo "WARNING: Some volumes failed to backup. See FAILED above."
  notify_failure "${FAILED} volume(s) failed to backup. ${BACKED_UP} succeeded, ${SKIPPED} skipped."
fi

STEP="creating tarball"
# Create tarball if requested
if [ "$CREATE_TAR" = true ]; then
  TARBALL="${BACKUP_DIR}.tar.gz"
  echo ""
  echo "Creating tarball..."

  # Remove stale tarball from previous run (sticky-bit on /tmp blocks overwrites by different users)
  rm -f "$TARBALL"

  # Exclude socket files (qbittorrent ipc-socket) - they can't be archived
  tar -czf "$TARBALL" \
    --exclude='*/ipc-socket' \
    -C "$(dirname "$BACKUP_DIR")" \
    "$(basename "$BACKUP_DIR")" 2>/dev/null

  TARBALL_SIZE_BYTES=$(stat -f%z "$TARBALL" 2>/dev/null || stat -c%s "$TARBALL" 2>/dev/null)
  TARBALL_SIZE_MB=$(( TARBALL_SIZE_BYTES / 1024 / 1024 ))
  TARBALL_SIZE=$(ls -lh "$TARBALL" | awk '{print $5}')
  echo "Created: $TARBALL ($TARBALL_SIZE)"

  # The working copy holds every volume in plain text, .env included, and
  # nothing ever removed it: on the NAS, whose /tmp is RAM, 26 days of them
  # had piled up to 5.8 GB (found 2026-09-28). The archive now has it all.
  case "$BACKUP_DIR" in
    "$STAGING_ROOT"/arr-stack-backup-[0-9]*) rm -rf "$BACKUP_DIR" ;;
  esac

  # GPG symmetric encryption (opt-in)
  if $ENCRYPT; then
    STEP="encrypting tarball"
    echo ""
    echo "Encrypting tarball with GPG..."
    gpg --batch --yes --symmetric --cipher-algo AES256 --output "${TARBALL}.gpg" "$TARBALL"
    rm -f "$TARBALL"
    TARBALL="${TARBALL}.gpg"
    TARBALL_SIZE_BYTES=$(stat -f%z "$TARBALL" 2>/dev/null || stat -c%s "$TARBALL" 2>/dev/null)
    TARBALL_SIZE_MB=$(( TARBALL_SIZE_BYTES / 1024 / 1024 ))
    TARBALL_SIZE=$(ls -lh "$TARBALL" | awk '{print $5}')
    echo "Encrypted: $TARBALL ($TARBALL_SIZE)"
  fi

  STEP="moving tarball to USB"
  # Move to final destination if specified and different from the staging root
  if [ -n "$FINAL_DEST" ] && [ "$FINAL_DEST" != "$STAGING_ROOT" ]; then
    AVAILABLE_MB=$(df -m "$FINAL_DEST" 2>/dev/null | awk 'NR==2 {print $4}')
    REQUIRED_MB=$(( TARBALL_SIZE_MB + 10 ))  # Actual size + 10MB buffer

    if [ -n "$AVAILABLE_MB" ] && [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
      echo ""
      echo "WARNING: Not enough space at $FINAL_DEST (${AVAILABLE_MB}MB free, need ${REQUIRED_MB}MB)"
      echo "         Tarball remains in $STAGING_ROOT - copy manually when space available"
    else
      # Keep the staged name, extension included: an --encrypt archive must stay
      # .tar.gz.gpg, or a restore would try to untar ciphertext.
      FINAL_TARBALL="$FINAL_DEST/$(basename "$TARBALL")"
      if mv "$TARBALL" "$FINAL_TARBALL"; then
        TARBALL="$FINAL_TARBALL"
        echo "Moved to: $TARBALL"
      else
        notify_failure "Could not move tarball to ${FINAL_DEST}. Backup remains in ${STAGING_ROOT}."
      fi
    fi
  fi

  LOCAL_COPY="backup.tar.gz"
  if $ENCRYPT; then
    LOCAL_COPY="backup.tar.gz.gpg"
  fi
  echo ""
  echo "To copy off-NAS:"
  echo "  # Ugreen NAS (scp doesn't work with /tmp):"
  echo "  ssh user@nas 'cat $TARBALL' > ./$LOCAL_COPY"
  echo ""
  echo "  # Other systems:"
  echo "  scp user@nas:$TARBALL ./$LOCAL_COPY"
  if $ENCRYPT; then
    echo ""
    echo "To decrypt: gpg --decrypt $LOCAL_COPY > backup.tar.gz"
  fi
fi

# Safety check runs via EXIT trap (ensure_services_running)

echo ""
if [[ "${TARBALL}" == "$STAGING_ROOT"/* ]] || [[ -z "${TARBALL}" ]]; then
  echo "NOTE: Backup is in /tmp which is cleared on reboot."
  echo "      Copy the tarball off-NAS before rebooting!"
fi
echo ""
echo "To restore: docker run --rm -v ./backup/VOLUME:/src:ro -v ${VOLUME_PREFIX}_VOLUME:/dst alpine cp -a /src/. /dst/"
echo "            (Sonarr, Radarr and Jellyfin restore differently: see docs/RESTORE.md)"

# A failed volume used to end in exit 0, so cron and anything reading its
# status saw a good night. Everything that succeeded is in the archive above.
if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "Exiting 1: ${FAILED} item(s) failed to back up (see FAILED above)."
  exit 1
fi
