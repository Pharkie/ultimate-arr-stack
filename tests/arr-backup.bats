#!/usr/bin/env bats
# Unit tests for scripts/arr-backup.sh: where the archive lands and what it is
# called, which is what a restore trusts.
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

    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_BIN"
    write_docker_stub
    write_gpg_stub
    export PATH="$STUB_BIN:$PATH"

    STAMP=$(date +%Y%m%d)
}

teardown() {
    if [[ -n "${REAL_GNUPGHOME:-}" ]]; then
        GNUPGHOME="$REAL_GNUPGHOME" gpgconf --kill gpg-agent 2>/dev/null || true
        rm -rf "$REAL_GNUPGHOME"
    fi
}

# Covers every docker call the script makes. `docker run` is the per-volume
# copy: it writes one file into the /backup mount, under the directory named
# in the `mkdir -p /backup/<suffix>` of its sh -c command.
write_docker_stub() {
    cat > "$STUB_BIN/docker" <<'STUB'
#!/bin/bash
case "$1" in
  volume|inspect) exit 0 ;;
  ps) printf '%s\n' gluetun pihole sonarr radarr prowlarr qbittorrent jellyfin sabnzbd; exit 0 ;;
  run)
    backup="" cmd=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -v) case "$2" in *:/backup) backup="${2%:/backup}" ;; esac; shift 2 ;;
        -c) cmd="$2"; shift 2 ;;
        *)  shift ;;
      esac
    done
    suffix=$(printf '%s' "$cmd" | sed -n 's|^mkdir -p /backup/\([^ ]*\) .*|\1|p')
    [ -n "$backup" ] && [ -n "$suffix" ] || exit 1
    mkdir -p "$backup/$suffix" && printf 'config for %s\n' "$suffix" > "$backup/$suffix/config.xml"
    ;;
  *) exit 0 ;;
esac
STUB
    chmod +x "$STUB_BIN/docker"
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
