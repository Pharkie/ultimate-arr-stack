#!/usr/bin/env bats
# Unit tests for scripts/arr-backup.sh: where the archive lands and what it is
# called, which is what a restore trusts; that Sonarr, Radarr and Jellyfin
# databases go in as consistent copies; and that a failure shows in the exit
# status.
#
# --encrypt with a destination (a directory argument or --usb) used to move
# the encrypted archive to a name ending .tar.gz. The file was ciphertext, so
# docs/RESTORE.md's `tar -xzf` failed on it, and the 7-day rotation never
# looked for a .gpg name either.
#
# Nothing here touches Docker or /tmp. `docker` and `gpg` are stubbed on PATH,
# the working copy is built under ARR_BACKUP_STAGING_ROOT, and the script runs
# from a copy in a throwaway stack directory, so it reads a fake .env and
# finds no compose file for its EXIT trap to act on. One test uses the real
# gpg, with a throwaway home and passphrase, to follow RESTORE.md end to end.
#
# The database tests use real SQLite files. The docker stub answers the *arr
# API the way Sonarr 4 does, and runs the script's own python helper here with
# the container paths mapped, so the copy, snapshot and integrity check under
# test are the real ones. Those tests skip without python3.

setup() {
    load helpers/setup
    unset HA_WEBHOOK_URL

    STACK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$STACK/scripts"
    cp "$REPO_ROOT/scripts/arr-backup.sh" "$STACK/scripts/arr-backup.sh"
    printf 'FAKE_SECRET=1\n' > "$STACK/.env"

    DEST="$BATS_TEST_TMPDIR/dest"
    mkdir -p "$DEST"
    export ARR_BACKUP_STAGING_ROOT="$BATS_TEST_TMPDIR/staging"
    mkdir -p "$ARR_BACKUP_STAGING_ROOT"

    # What the docker stub reads. By default the database apps' volumes do
    # not exist, so the archive-naming tests below need no python3.
    export STUB_LOG="$BATS_TEST_TMPDIR/docker.log"
    export FAKE_VOLUMES="$BATS_TEST_TMPDIR/volumes"
    export ARR_STATE="$BATS_TEST_TMPDIR/arr-state"
    export MISSING_VOLUMES="sonarr-config radarr-config jellyfin-config"
    export FAIL_VOLUMES=""
    export DOWN_CONTAINERS=""
    export ARR_COMMAND_STATUS="completed"
    export ARR_BACKUP_API_TIMEOUT=4
    mkdir -p "$FAKE_VOLUMES" "$ARR_STATE/sonarr" "$ARR_STATE/radarr"

    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    write_docker_stub
    write_gpg_stub
    export PATH="$STUB_BIN:$PATH"

    STAMP=$(date +%Y%m%d)
    ARCHIVE="$DEST/arr-stack-backup-$STAMP.tar.gz"
}

teardown() {
    if [[ -n "${REAL_GNUPGHOME:-}" ]]; then
        GNUPGHOME="$REAL_GNUPGHOME" gpgconf --kill gpg-agent 2>/dev/null || true
        rm -rf "$REAL_GNUPGHOME"
    fi
}

# Covers every docker call the script makes, and logs them to $STUB_LOG.
#   volume inspect  fails for suffixes in $MISSING_VOLUMES
#   run alpine ...  the plain per-volume copy: writes one file into the /backup
#                   mount, under the `mkdir -p /backup/<suffix>` of its sh -c
#                   command; fails for suffixes in $FAIL_VOLUMES
#   run python:...  runs the script's helper with python3 here, each container
#                   path mapped to its mount (a named volume is a directory
#                   under $FAKE_VOLUMES)
#   exec APP cat    APP's config.xml (ApiKey key-APP), or a zip it wrote
#   exec APP curl   APP's API, as Sonarr 4 answers it: a Backup command copies
#                   $ARR_STATE/APP/source.zip in as a new manual backup (id 500)
#                   and finishes with $ARR_COMMAND_STATUS; a scheduled backup
#                   (id 400) is always listed; a wrong key is a 401
#   exec fails for containers in $DOWN_CONTAINERS
write_docker_stub() {
    cat > "$STUB_BIN/docker" <<'STUB'
#!/bin/bash
log() { printf '%s\n' "$*" >> "$STUB_LOG"; }
listed() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1; }

case "$1" in
  volume) listed "$MISSING_VOLUMES" "${3#*_}" && exit 1; exit 0 ;;
  inspect) exit 0 ;;
  ps) printf '%s\n' gluetun pihole sonarr radarr prowlarr qbittorrent jellyfin sabnzbd; exit 0 ;;
  exec)
    app="$2"; shift 2
    log "exec $app $*"
    if listed "$DOWN_CONTAINERS" "$app"; then
      echo "Error response from daemon: container $app is not running" >&2
      exit 1
    fi
    state="$ARR_STATE/$app"
    ours="${app}_backup_v9.9.9_2026.01.01_00.00.00.zip"
    case "$1" in
      cat)
        case "$2" in
          /config/config.xml)
            printf '<Config>\n  <Port>8989</Port>\n  <ApiKey>key-%s</ApiKey>\n  <UrlBase></UrlBase>\n</Config>\n' "$app" ;;
          /config/Backups/manual/*) exec cat "$state/manual/${2##*/}" ;;
          *) echo "cat: can't open '$2': No such file or directory" >&2; exit 1 ;;
        esac ;;
      curl)
        shift
        method=GET url="" key=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -X) method="$2"; shift 2 ;;
            -H) case "$2" in "X-Api-Key: "*) key="${2#X-Api-Key: }" ;; esac; shift 2 ;;
            -d|-m) shift 2 ;;
            http://*) url="$1"; shift ;;
            *) shift ;;
          esac
        done
        if [ "$key" != "key-$app" ]; then
          echo "curl: (22) The requested URL returned error: 401" >&2
          exit 22
        fi
        case "$method ${url#http://localhost:8989/api/v3/}" in
          "POST command")
            if [ "$ARR_COMMAND_STATUS" = completed ]; then
              mkdir -p "$state/manual"
              cp "$state/source.zip" "$state/manual/$ours" 2>/dev/null ||
                printf 'not a zip\n' > "$state/manual/$ours"
            fi
            printf '{\n  "name": "Backup",\n  "body": {\n    "name": "Backup"\n  },\n  "status": "queued",\n  "id": 77\n}\n' ;;
          "GET command/77")
            printf '{\n  "name": "Backup",\n  "status": "%s",\n  "id": 77\n}\n' "$ARR_COMMAND_STATUS" ;;
          "GET system/backup")
            printf '[\n  {\n    "name": "%s_backup_scheduled.zip",\n    "path": "/backup/scheduled/%s_backup_scheduled.zip",\n    "type": "scheduled",\n    "size": 1,\n    "id": 400\n  }' "$app" "$app"
            for f in "$state"/manual/*.zip; do
              [ -f "$f" ] || continue
              n="${f##*/}"
              id=500
              [ "$n" = "$ours" ] || id=450
              printf ',\n  {\n    "name": "%s",\n    "path": "/backup/manual/%s",\n    "type": "manual",\n    "size": 1,\n    "id": %s\n  }' "$n" "$n" "$id"
            done
            printf '\n]\n' ;;
          "DELETE system/backup/500") rm -f "$state/manual/$ours" ;;
          "GET config/host") printf '{\n  "backupFolder": "Backups",\n  "backupRetention": 28\n}\n' ;;
          *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
        esac ;;
      *) exit 1 ;;
    esac ;;
  run)
    shift
    mounts=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --rm) shift ;;
        --name|-e|--user|--network) shift 2 ;;
        -v) mounts+=("$2"); shift 2 ;;
        *) break ;;
      esac
    done
    image="$1"; shift
    log "run ${mounts[*]} $image"
    to_host() {
      local m src dst
      for m in "${mounts[@]}"; do
        src="${m%%:*}"; dst="${m#*:}"; dst="${dst%:ro}"
        case "$src" in /*) ;; *) src="$FAKE_VOLUMES/$src" ;; esac
        case "$1" in "$dst"|"$dst"/*) printf '%s' "$src${1#"$dst"}"; return ;; esac
      done
      printf '%s' "$1"
    }
    case "$image" in
      python:*)
        [ "$1" = python3 ] && [ "$2" = -c ] || exit 1
        code="$3"; shift 3
        args=()
        for a in "$@"; do args+=("$(to_host "$a")"); done
        exec python3 -c "$code" "${args[@]}" ;;
      *)
        suffix=$(printf '%s' "${3:-}" | sed -n 's|^mkdir -p /backup/\([^ ]*\) .*|\1|p')
        backup=$(to_host /backup)
        [ -n "$suffix" ] && [ "$backup" != /backup ] || exit 1
        if listed "$FAIL_VOLUMES" "$suffix"; then
          echo "cp: can't open '/source/$suffix': Permission denied" >&2
          exit 1
        fi
        mkdir -p "$backup/$suffix" && printf 'config for %s\n' "$suffix" > "$backup/$suffix/config.xml" ;;
    esac ;;
  *) exit 0 ;;
esac
STUB
    chmod +x "$STUB_BIN/docker"
}

need_python() {
    command -v python3 &>/dev/null || skip "python3 is not installed"
}

# Real SQLite fixtures:
#   sonarr, radarr      $ARR_STATE/APP/source.zip, the zip APP's Backup
#                       command "writes": config.xml, APP.db, INFO
#   corrupt-sonarr ...  the same, with a damaged page in the database
#   jellyfin            a jellyfin-config volume whose newest row is only in
#                       data/jellyfin.db-wal, as while Jellyfin runs, plus the
#                       things Jellyfin rebuilds, which must stay out
make_fixtures() {
    python3 - "$BATS_TEST_TMPDIR" "$@" <<'PY'
import os, shutil, sqlite3, sys, zipfile

root, wanted = sys.argv[1], sys.argv[2:]
fx = os.path.join(root, "fx")
os.makedirs(fx, exist_ok=True)


def put(path, text=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def arr(app, corrupt):
    db = os.path.join(fx, app + ".db")
    c = sqlite3.connect(db)
    c.execute("CREATE TABLE QualityProfiles(Name TEXT)")
    c.executemany("INSERT INTO QualityProfiles VALUES(?)",
                  [("Best Available (SD to 4K)",)] + [("profile %d" % i,) for i in range(3000)])
    c.commit()
    c.close()
    if corrupt:
        with open(db, "r+b") as f:
            f.seek(4096 + 8)  # page 2, the table's root, past its page header
            f.write(b"\xff" * 2000)
    with zipfile.ZipFile(os.path.join(root, "arr-state", app, "source.zip"), "w") as z:
        z.writestr("config.xml", "<Config><ApiKey>key-%s</ApiKey></Config>\n" % app)
        z.write(db, app + ".db")
        z.writestr("INFO", "v9.9.9\n")


def jellyfin():
    vol = os.path.join(root, "volumes", "testprefix_jellyfin-config")
    for rel in [".jellyfin-data", "config/.jellyfin-config", "config/system.xml",
                "config/users/admin.xml", "root/.jellyfin-root",
                "root/default/Movies/options.xml", "root/default/Movies/movies.mblink",
                "plugins/configurations/Jellyfin.Plugin.Tvdb.xml",
                "data/.jellyfin-data", "data/device.txt", "data/ScheduledTasks/task.js",
                # rebuilt by Jellyfin: must not be backed up
                "metadata/library/ab/poster.jpg", "log/log_20260101.log",
                "data/subtitles/ab/track.srt", "data/attachments/ab/font.ttf",
                "data/splashscreen.png"]:
        put(os.path.join(vol, rel), "fixture " + rel)
    live = os.path.join(fx, "live.db")
    c = sqlite3.connect(live, isolation_level=None)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA wal_autocheckpoint=0")
    c.execute("CREATE TABLE UserData(Played TEXT)")
    c.execute("INSERT INTO UserData VALUES('checkpointed')")
    c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    c.execute("INSERT INTO UserData VALUES('only in the wal')")
    # Copied while the connection is open: the .db and -wal of a running app
    shutil.copy(live, os.path.join(vol, "data", "jellyfin.db"))
    shutil.copy(live + "-wal", os.path.join(vol, "data", "jellyfin.db-wal"))
    c.close()
    # A database inside a directory Jellyfin rebuilds: neither copied nor snapshotted
    os.makedirs(os.path.join(vol, "data", "SQLiteBackups"))
    old = sqlite3.connect(os.path.join(vol, "data", "SQLiteBackups", "jellyfin_premigration.db"))
    old.execute("CREATE TABLE t(x)")
    old.commit()
    old.close()


for w in wanted:
    if w == "jellyfin":
        jellyfin()
    elif w.startswith("corrupt-"):
        arr(w[len("corrupt-"):], True)
    else:
        arr(w, False)
PY
}

# Rows of a table in an SQLite file, one per line: sqlite_rows DB SQL
sqlite_rows() {
    python3 -c 'import sqlite3, sys
for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2]): print(r[0])' "$@"
}

# Stands in for `gpg --symmetric`: writes a marker line, then the input, to
# --output (or, as real gpg does without it, to <input>.gpg). The marker is
# what proves the file at the destination is the encrypted one.
write_gpg_stub() {
    cat > "$STUB_BIN/gpg" <<'STUB'
#!/bin/bash
out="" in=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output|-o) out="$2"; shift 2 ;;
    --cipher-algo) shift 2 ;;
    -*) shift ;;
    *) in="$1"; shift ;;
  esac
done
[ -n "$in" ] || exit 2
{ echo "STUB-GPG-CIPHERTEXT"; cat "$in"; } > "${out:-$in.gpg}"
STUB
    chmod +x "$STUB_BIN/gpg"
}

run_backup() {
    run "$STACK/scripts/arr-backup.sh" --prefix testprefix "$@"
}

@test "--encrypt with a destination keeps the .tar.gz.gpg name" {
    run_backup --tar --encrypt "$DEST"
    assert_success
    assert_output --partial "Moved to: $DEST/arr-stack-backup-$STAMP.tar.gz.gpg"

    [ -f "$DEST/arr-stack-backup-$STAMP.tar.gz.gpg" ]
    # No ciphertext under a name that says gzip — that is the file RESTORE.md
    # would hand to `tar -xzf`.
    [ ! -e "$DEST/arr-stack-backup-$STAMP.tar.gz" ]
    [ "$(head -n 1 "$DEST/arr-stack-backup-$STAMP.tar.gz.gpg")" = "STUB-GPG-CIPHERTEXT" ]

    # Nothing left behind in staging, plaintext tarball included.
    [ ! -e "$ARR_BACKUP_STAGING_ROOT/arr-stack-backup-$STAMP.tar.gz" ]
    [ ! -e "$ARR_BACKUP_STAGING_ROOT/arr-stack-backup-$STAMP.tar.gz.gpg" ]

    # The copy-off hint names the local file the way RESTORE.md expects it.
    assert_output --partial "> ./backup.tar.gz.gpg"
    assert_output --partial "gpg --decrypt backup.tar.gz.gpg > backup.tar.gz"
}

@test "without --encrypt the destination gets a plain, extractable .tar.gz" {
    run_backup --tar "$DEST"
    assert_success
    assert_output --partial "Moved to: $DEST/arr-stack-backup-$STAMP.tar.gz"
    refute_output --partial ".gpg"

    [ ! -e "$DEST/arr-stack-backup-$STAMP.tar.gz.gpg" ]
    run tar -tzf "$DEST/arr-stack-backup-$STAMP.tar.gz"
    assert_success
    assert_output --partial "arr-stack-backup-$STAMP/dot-env"
    assert_output --partial "arr-stack-backup-$STAMP/gluetun-config/config.xml"
}

# The plain-text working copy (.env and every config) was never removed; on
# the NAS 26 of them sat in RAM-backed /tmp. With --tar the archive has it all.
@test "--tar removes the plain-text working copy once the archive exists" {
    run_backup --tar "$DEST"
    assert_success
    [ -f "$DEST/arr-stack-backup-$STAMP.tar.gz" ]
    [ ! -e "$ARR_BACKUP_STAGING_ROOT/arr-stack-backup-$STAMP" ]
}

@test "without --tar the working copy is the backup, and stays" {
    run_backup
    assert_success
    [ -f "$ARR_BACKUP_STAGING_ROOT/arr-stack-backup-$STAMP/dot-env" ]
}

@test "--encrypt with no destination leaves the .tar.gz.gpg in staging" {
    run_backup --tar --encrypt
    assert_success
    [ -f "$ARR_BACKUP_STAGING_ROOT/arr-stack-backup-$STAMP.tar.gz.gpg" ]
    [ ! -e "$ARR_BACKUP_STAGING_ROOT/arr-stack-backup-$STAMP.tar.gz" ]
}

@test "rotation deletes old encrypted and plain archives, and keeps recent ones" {
    touch -t 202001010000 "$DEST/arr-stack-backup-20200101.tar.gz.gpg" \
                          "$DEST/arr-stack-backup-20200101.tar.gz"
    touch "$DEST/arr-stack-backup-yesterday.tar.gz.gpg"
    # Not ours: rotation must leave other files at the destination alone.
    touch -t 202001010000 "$DEST/sonarr-config-premigration.tgz"

    run_backup --tar --encrypt "$DEST"
    assert_success
    [ ! -e "$DEST/arr-stack-backup-20200101.tar.gz.gpg" ]
    [ ! -e "$DEST/arr-stack-backup-20200101.tar.gz" ]
    [ -f "$DEST/arr-stack-backup-yesterday.tar.gz.gpg" ]
    [ -f "$DEST/sonarr-config-premigration.tgz" ]
}

@test "real gpg: the encrypted backup at the destination restores per RESTORE.md" {
    command -v gpg &>/dev/null || skip "gpg is not installed"
    rm "$STUB_BIN/gpg"

    # A short path: gpg-agent's socket lives in GNUPGHOME, and BATS_TEST_TMPDIR
    # on macOS is longer than a socket path may be.
    REAL_GNUPGHOME=$(mktemp -d /tmp/arr-backup-gpg.XXXXXX)
    chmod 700 "$REAL_GNUPGHOME"
    printf 'throwaway-test-passphrase\n' > "$BATS_TEST_TMPDIR/passphrase"
    printf 'pinentry-mode loopback\npassphrase-file %s\n' "$BATS_TEST_TMPDIR/passphrase" \
        > "$REAL_GNUPGHOME/gpg.conf"
    export GNUPGHOME="$REAL_GNUPGHOME"

    run_backup --tar --encrypt "$DEST"
    assert_success

    # RESTORE.md step 2 (decrypt), then step 3 (extract).
    local restore="$BATS_TEST_TMPDIR/restore"
    mkdir -p "$restore"
    gpg --quiet --decrypt "$DEST/arr-stack-backup-$STAMP.tar.gz.gpg" > "$restore/backup.tar.gz"
    tar -xzf "$restore/backup.tar.gz" -C "$restore"
    [ "$(cat "$restore/arr-stack-backup-$STAMP/dot-env")" = "FAKE_SECRET=1" ]
    [ -f "$restore/arr-stack-backup-$STAMP/prowlarr-config/config.xml" ]
}

# --- Failure shows in the exit status ---

# A volume that failed to copy only sent a webhook, and the script still
# exited 0, so cron and anything reading its status saw a good night.
@test "a failed volume: the archive of the rest is still written, then exit 1" {
    export FAIL_VOLUMES="sabnzbd-config"
    run_backup --tar "$DEST"
    [ "$status" -eq 1 ]
    assert_output --partial "Backing up sabnzbd-config... FAILED"
    assert_output --partial "Summary: 7 backed up, 3 skipped, 1 failed"
    assert_output --partial "Exiting 1: 1 item(s) failed to back up"

    run tar -tzf "$ARCHIVE"
    assert_success
    assert_output --partial "arr-stack-backup-$STAMP/dot-env"
    assert_output --partial "arr-stack-backup-$STAMP/prowlarr-config/config.xml"
    refute_output --partial "sabnzbd-config"
}

@test "a clean run exits 0" {
    run_backup --tar "$DEST"
    assert_success
    assert_output --partial "0 failed"
    refute_output --partial "Exiting 1"
}

# --- Sonarr and Radarr: their own Backup command, never a file copy ---

@test "sonarr and radarr: each app's own backup zip, checked, then deleted from the app" {
    need_python
    export MISSING_VOLUMES="jellyfin-config"
    make_fixtures sonarr radarr
    # A manual backup someone made in the UI: not this run's, so left alone
    mkdir -p "$ARR_STATE/sonarr/manual"
    cp "$ARR_STATE/sonarr/source.zip" "$ARR_STATE/sonarr/manual/sonarr_backup_user.zip"

    run_backup --tar "$DEST"
    assert_success
    assert_output --regexp "Backing up sonarr-config\.\.\. OK \([^,]+, sonarr\.db integrity ok\)"
    assert_output --regexp "Backing up radarr-config\.\.\. OK \([^,]+, radarr\.db integrity ok\)"

    # In the archive: exactly the zip this run asked for, nothing from the volume
    run tar -tzf "$ARCHIVE"
    assert_success
    assert_output --partial "arr-stack-backup-$STAMP/sonarr-config/sonarr_backup_v9.9.9_2026.01.01_00.00.00.zip"
    assert_output --partial "arr-stack-backup-$STAMP/radarr-config/radarr_backup_v9.9.9_2026.01.01_00.00.00.zip"
    refute_output --partial "backup_user"
    refute_output --partial "backup_scheduled"
    refute_output --partial "sonarr-config/config.xml"

    # ...and it holds the real database
    tar -xzf "$ARCHIVE" -C "$BATS_TEST_TMPDIR"
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("sonarr.db", sys.argv[2])' \
        "$BATS_TEST_TMPDIR/arr-stack-backup-$STAMP/sonarr-config/sonarr_backup_v9.9.9_2026.01.01_00.00.00.zip" \
        "$BATS_TEST_TMPDIR/out"
    run sqlite_rows "$BATS_TEST_TMPDIR/out/sonarr.db" "SELECT Name FROM QualityProfiles LIMIT 1"
    assert_output "Best Available (SD to 4K)"

    # Asked for with the key from config.xml, then deleted through the API:
    # this run's zip only, never the scheduled or the user's one
    grep -qF 'exec sonarr curl' "$STUB_LOG"
    grep -qF -- '-X POST -H X-Api-Key: key-sonarr -H Content-Type: application/json -d {"name":"Backup"} http://localhost:8989/api/v3/command' "$STUB_LOG"
    grep -qF -- '-X DELETE -H X-Api-Key: key-sonarr http://localhost:8989/api/v3/system/backup/500' "$STUB_LOG"
    grep -qF -- '-X DELETE -H X-Api-Key: key-radarr http://localhost:8989/api/v3/system/backup/500' "$STUB_LOG"
    run grep -E -- '-X DELETE .*/system/backup/(400|450)' "$STUB_LOG"
    assert_failure
    [ ! -e "$ARR_STATE/sonarr/manual/sonarr_backup_v9.9.9_2026.01.01_00.00.00.zip" ]
    [ ! -e "$ARR_STATE/radarr/manual/radarr_backup_v9.9.9_2026.01.01_00.00.00.zip" ]
    [ -f "$ARR_STATE/sonarr/manual/sonarr_backup_user.zip" ]
}

# The integrity check is a guard: prove it can fail.
@test "an *arr backup whose database fails integrity_check fails that volume, and exit 1" {
    need_python
    export MISSING_VOLUMES="jellyfin-config"
    make_fixtures corrupt-sonarr radarr

    run_backup --tar "$DEST"
    [ "$status" -eq 1 ]
    assert_output --partial "sonarr.db: integrity_check:"
    assert_output --partial "Backing up sonarr-config... FAILED (sonarr_backup_v9.9.9_2026.01.01_00.00.00.zip did not pass its check)"
    assert_output --regexp "Backing up radarr-config\.\.\. OK"

    # No unchecked copy in the archive, and the app's copy is still cleaned up
    run tar -tzf "$ARCHIVE"
    assert_success
    refute_output --partial "sonarr-config"
    assert_output --partial "radarr-config/radarr_backup_v9.9.9_2026.01.01_00.00.00.zip"
    [ ! -e "$ARR_STATE/sonarr/manual/sonarr_backup_v9.9.9_2026.01.01_00.00.00.zip" ]
}

@test "an *arr that is down, or whose Backup command fails or hangs, fails its volume and exit 1" {
    export MISSING_VOLUMES="jellyfin-config"
    export DOWN_CONTAINERS="sonarr"
    export ARR_COMMAND_STATUS="failed"
    run_backup --tar "$DEST"
    [ "$status" -eq 1 ]
    assert_output --partial "Backing up sonarr-config... FAILED (sonarr is not running)"
    assert_output --partial "Backing up radarr-config... FAILED (radarr's Backup command failed)"
    assert_output --partial "Exiting 1: 2 item(s) failed to back up"
    [ -f "$ARCHIVE" ]

    export DOWN_CONTAINERS=""
    export ARR_COMMAND_STATUS="started"
    export ARR_BACKUP_API_TIMEOUT=2
    run_backup --tar "$DEST"
    [ "$status" -eq 1 ]
    assert_output --partial "Backing up sonarr-config... FAILED (sonarr's Backup command not finished after 2s)"
}

# --- Jellyfin: a database snapshot, and the config a re-scan cannot rebuild ---

@test "jellyfin: the database is snapshotted with what is only in its WAL; config kept, rebuildables left out" {
    need_python
    export MISSING_VOLUMES="sonarr-config radarr-config"
    make_fixtures jellyfin
    local vol="$FAKE_VOLUMES/testprefix_jellyfin-config"
    # Not a blind test: the newest row really is only in the -wal
    run sqlite_rows "file:$vol/data/jellyfin.db?immutable=1" "SELECT Played FROM UserData"
    assert_output "checkpointed"

    run_backup --tar "$DEST"
    assert_success
    assert_output --regexp "Backing up jellyfin-config\.\.\. OK \([^,]+, data/jellyfin\.db integrity ok\)"

    run tar -tzf "$ARCHIVE"
    assert_success
    local j="arr-stack-backup-$STAMP/jellyfin-config"
    for kept in .jellyfin-data config/.jellyfin-config config/system.xml config/users/admin.xml \
                root/.jellyfin-root root/default/Movies/options.xml root/default/Movies/movies.mblink \
                plugins/configurations/Jellyfin.Plugin.Tvdb.xml data/.jellyfin-data \
                data/device.txt data/ScheduledTasks/task.js data/jellyfin.db; do
        assert_output --partial "$j/$kept"
    done
    for left in metadata log data/subtitles data/attachments data/splashscreen.png \
                data/SQLiteBackups data/jellyfin.db-wal data/jellyfin.db-shm; do
        refute_output --partial "$j/$left"
    done

    tar -xzf "$ARCHIVE" -C "$BATS_TEST_TMPDIR"
    run sqlite_rows "$BATS_TEST_TMPDIR/$j/data/jellyfin.db" "SELECT Played FROM UserData ORDER BY rowid"
    assert_output "$(printf 'checkpointed\nonly in the wal')"
}

@test "jellyfin: a database that cannot be read fails the volume, leaves no half copy, and exit 1" {
    need_python
    export MISSING_VOLUMES="sonarr-config radarr-config"
    make_fixtures jellyfin
    printf 'SQLite format 3\000 but not really a database' \
        > "$FAKE_VOLUMES/testprefix_jellyfin-config/data/jellyfin.db"
    rm "$FAKE_VOLUMES/testprefix_jellyfin-config/data/jellyfin.db-wal"

    run_backup --tar "$DEST"
    [ "$status" -eq 1 ]
    assert_output --partial "Backing up jellyfin-config... FAILED (database snapshot or copy failed)"
    run tar -tzf "$ARCHIVE"
    assert_success
    refute_output --partial "jellyfin-config"
}

# The script may read live volumes and call the apps' own API, nothing more.
@test "live volumes are only mounted read-only, and the only API writes are Backup and its delete" {
    need_python
    export MISSING_VOLUMES=""
    make_fixtures sonarr radarr jellyfin
    run_backup --tar "$DEST"
    assert_success

    # Every named-volume mount of every container run ends :ro (the jellyfin
    # one included: it is in the log)
    grep -qE '^run testprefix_jellyfin-config:/source' "$STUB_LOG"
    run grep -oE ' testprefix_[^ ]+' "$STUB_LOG"
    assert_success
    while read -r mount; do
        [[ "$mount" == *:ro ]] || { echo "not read-only: $mount"; false; }
    done <<< "$output"

    # Inside the apps: only cat and curl, and curl only GETs, plus one POST
    # (the Backup command) and one DELETE (its zip) per app
    grep -qE '^exec sonarr cat ' "$STUB_LOG"
    [ "$(grep -E '^exec ' "$STUB_LOG" | grep -cvE '^exec [a-z]+ (cat|curl) ')" -eq 0 ]
    [ "$(grep -cE '^exec [a-z]+ curl .*-X POST' "$STUB_LOG")" -eq 2 ]
    [ "$(grep -cE '^exec [a-z]+ curl .*-X POST .*/api/v3/command$' "$STUB_LOG")" -eq 2 ]
    [ "$(grep -cE '^exec [a-z]+ curl .*-X DELETE' "$STUB_LOG")" -eq 2 ]
    [ "$(grep -cE '^exec [a-z]+ curl .*-X (PUT|PATCH)' "$STUB_LOG")" -eq 0 ]
}

# notify_failure only read HA_WEBHOOK_URL from the environment, and cron sets
# none, so a failed backup alerted nobody (found 2026-09-29). It now falls back
# to the stack's .env.
@test "a failure alert goes to the HA_WEBHOOK_URL in the stack's .env" {
    printf 'FAKE_SECRET=1\nHA_WEBHOOK_URL="http://ha.example.invalid/api/webhook/test-hook"\n' > "$STACK/.env"
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s"\n' "$BATS_TEST_TMPDIR/curl.log" > "$STUB_BIN/curl"
    chmod +x "$STUB_BIN/curl"
    run_backup --usb no-such-backup-dir
    assert_failure
    grep -qx 'http://ha.example.invalid/api/webhook/test-hook' "$BATS_TEST_TMPDIR/curl.log"
    grep -q 'Backup Failed' "$BATS_TEST_TMPDIR/curl.log"
}
