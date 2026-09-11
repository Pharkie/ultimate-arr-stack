#!/usr/bin/env bats
# scripts/lib/common.sh
#
# Every one of the eleven pre-commit checks sources this file, so a defect here
# is not one check's problem -- it is every check's problem at once. It was
# also the file that proved "sourced by a tested file" is not coverage: swept
# by the generative mutator on exactly that theory, it produced 78 mutants and
# survived all 78. The three tested files that source it exercise none of its
# NAS, SSH or domain helpers.
#
# Two things shape how these tests are written:
#
#   1. Nearly everything here is CACHED in a module-level global
#      (_REPO_ROOT, _NAS_CONFIG_LOADED, _DOMAIN_LOADED). Left alone, whichever
#      test ran first would decide the answer for all the rest, and the suite
#      would pass or fail on test ORDER. setup() resets all six.
#
#   2. A cache is set by an ASSIGNMENT, and an assignment inside $( ) dies with
#      the subshell -- the same trap as asserting on a variable set inside bats'
#      own `run`. So the caching tests call the function with `>/dev/null` and
#      then read the global, never `x=$(...)`.

setup() {
    load helpers/setup
    load helpers/stubs
    source "$REPO_ROOT/scripts/lib/common.sh"

    # (1) above. Every global this file caches into, back to its declared state.
    _REPO_ROOT=""
    _NAS_CONFIG_LOADED=false
    _NAS_HOST=""
    _NAS_USER=""
    _NAS_HOSTNAME=""
    _DOMAIN_LOADED=false
    _DOMAIN=""

    FAKE="$BATS_TEST_TMPDIR/fake-root"
    mkdir -p "$FAKE/.claude"
}

# The config-reading half reaches the filesystem through exactly one seam.
fake_root() { get_repo_root() { echo "$FAKE"; }; }

# A real repository, because get_all_tracked_files / get_staged_files call git
# in the CWD and a git stub that answered them both would be re-implementing
# the thing under test.
real_repo() {
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    cd "$REPO" || return 1
    git init -q .
    git config user.email t@example.com
    git config user.name t
}

# ---------------------------------------------------------------- get_repo_root

@test "common: get_repo_root returns the git toplevel" {
    real_repo
    run get_repo_root
    assert_success
    # macOS puts the tmpdir behind /private; compare resolved paths.
    [ "$(cd "$output" && pwd -P)" = "$(cd "$REPO" && pwd -P)" ]
}

@test "common: get_repo_root asks git exactly once, then serves the cache" {
    real_repo
    stub_init
    stub_git 'echo /from/git'

    get_repo_root >/dev/null
    get_repo_root >/dev/null
    get_repo_root >/dev/null

    [ "$_REPO_ROOT" = "/from/git" ]
    [ "$(grep -c '^git' "$STUB_LOG")" -eq 1 ]
}

@test "common: outside a repo get_repo_root falls back to . -- and caches the fallback" {
    stub_init
    stub_git 'exit 128'          # what git prints outside a work tree

    get_repo_root >/dev/null
    [ "$_REPO_ROOT" = "." ]

    # Pinned, not endorsed: the fallback is cached like any other answer, so a
    # single failed call decides the repo root for the rest of the process even
    # if a later call would have succeeded. Harmless for a hook that runs once
    # from the repo; worth knowing before reusing this anywhere longer-lived.
    stub_git 'echo /real/root'
    get_repo_root >/dev/null
    [ "$_REPO_ROOT" = "." ]
}

# ------------------------------------------------- tracked / staged / to-scan

@test "common: get_all_tracked_files lists tracked files and drops the root .env" {
    real_repo
    printf 'x\n' > a.txt
    printf 'SECRET=1\n' > .env
    mkdir -p sub && printf 'SECRET=1\n' > sub/.env
    git add -A -f
    run get_all_tracked_files
    assert_success
    assert_line "a.txt"
    assert_line "sub/.env"
    refute_line ".env"
}

@test "common: get_staged_files returns only staged additions and modifications" {
    real_repo
    printf 'x\n' > committed.txt
    printf 'y\n' > deleted.txt
    git add -A && git commit -qm init

    printf 'new\n' > added.txt
    printf 'changed\n' > committed.txt
    rm deleted.txt
    git add -A

    run get_staged_files
    assert_success
    assert_line "added.txt"
    assert_line "committed.txt"
    # --diff-filter=ACM: a deletion is not something a content check can scan.
    refute_line "deleted.txt"
}

@test "common: get_files_to_scan is the deduplicated union of both" {
    real_repo
    printf 'x\n' > both.txt
    git add -A && git commit -qm init
    printf 'y\n' > staged-only.txt
    git add -A

    run get_files_to_scan
    assert_success
    assert_line "both.txt"
    assert_line "staged-only.txt"
    [ "$(printf '%s\n' "$output" | grep -c '^both\.txt$')" -eq 1 ]
}

@test "common: DEFECT - a backslash in a filename is data, not an escape" {
    # `echo -e` interpreted backslash escapes in a PATH. Git already quotes such
    # a name on the way out (core.quotePath), so what arrives here is the two
    # characters \\ and t -- which `echo -e` then collapsed to \t, handing every
    # caller a path that is neither the real filename nor the one git named. A
    # filename is data; this is the same class as interpolating a path into a
    # python -c string.
    #
    # The assertion is that get_files_to_scan passes git's answer through
    # BYTE-FOR-BYTE, which is the only property it is entitled to change nothing
    # about.
    real_repo
    printf 'x\n' > 'a\tb.txt'
    git add -A

    run get_files_to_scan
    assert_success
    assert_line "$(get_all_tracked_files)"
    assert_line '"a\\tb.txt"'
    refute_output --partial "$(printf 'a\tb.txt')"
}

# ------------------------------------------------------------ read_file_content

@test "common: read_file_content returns the file, and fails empty on a missing one" {
    printf 'hello\n' > "$FAKE/f"
    run read_file_content "$FAKE/f"
    assert_success
    assert_output "hello"

    # The header says "empty on error" and says nothing about the status, but
    # the status is cat's and it is 1. That is not academic: two of the checks
    # that source this file are called BARE by scripts/pre-commit under set -e,
    # where a non-zero return from an unguarded call aborts the whole hook.
    # Pinned so the contract is the tested one rather than the documented one.
    run read_file_content "$FAKE/nope"
    assert_failure
    assert_output ""
}

# --------------------------------------------------------------- is_binary_file

@test "common: is_binary_file returns 0 for binary -- the inverted-looking contract" {
    # 0 means SKIP THIS FILE, not "yes it is binary" in the usual boolean sense.
    # Both call sites read `is_binary_file "$f" && continue`, so getting this
    # backwards would silently scan nothing at all rather than fail loudly.
    for ext in png jpg jpeg gif ico woff woff2 ttf eot svg; do
        run is_binary_file "logo.$ext"
        assert_success
    done
    for name in README.md script.sh docker-compose.yml noextension; do
        run is_binary_file "$name"
        assert_failure
    done
}

@test "common: is_binary_file matches the extension case-sensitively" {
    # Pinned as a known limit, not endorsed. A .PNG is scanned as text, which
    # is merely noisy; the reverse direction is what would matter.
    run is_binary_file "LOGO.PNG"
    assert_failure
}

@test "common: an .svg is text but classified binary, so it is never scanned" {
    # 20+ tracked SVGs are excluded from the hardcoded-domain scan by this line.
    # An SVG is XML -- a domain, a key or a comment inside one is readable text
    # that no check here will ever look at. Recorded as a real gap so that the
    # next person to widen the scan knows this is where the files went.
    run is_binary_file "docs/logos/jellyfin.svg"
    assert_success
}

# ----------------------------------------------------------- load_nas_config

@test "common: it reads host, hostname and user from the SSH: user@host form" {
    fake_root
    printf 'SSH: leoleg@mynas.local\n' > "$FAKE/.claude/config.local.md"
    [ "$(get_nas_host)" = "mynas.local" ]
    [ "$(get_nas_hostname)" = "mynas" ]
    [ "$(get_nas_user)" = "leoleg" ]
    has_nas_config
}

@test "common: it falls back to the SSH User table form for the user" {
    fake_root
    printf '| SSH User | `leoleg` |\n| Host | mynas.local |\n' \
        > "$FAKE/.claude/config.local.md"
    [ "$(get_nas_user)" = "leoleg" ]
    [ "$(get_nas_host)" = "mynas.local" ]
}

@test "common: the user defaults to admin when neither form is present" {
    fake_root
    printf 'Host | mynas.local\n' > "$FAKE/.claude/config.local.md"
    [ "$(get_nas_user)" = "admin" ]
}

@test "common: no config file is no host, and has_nas_config says so" {
    fake_root
    run has_nas_config
    assert_failure
    [ "$(get_nas_host)" = "" ]
    # The user still defaults, so a caller reading get_nas_user alone cannot
    # tell configured-as-admin from not-configured-at-all. has_nas_config is
    # the only honest question.
    [ "$(get_nas_user)" = "admin" ]
}

@test "common: the first .local in the file wins, wherever it appears" {
    fake_root
    # Pinned so the fragility is visible: the match is not anchored to a field
    # or a table row, so a sentence mentioning some other host earlier in the
    # document silently becomes the NAS host.
    printf 'See also router.local for DNS.\nSSH: leoleg@mynas.local\n' \
        > "$FAKE/.claude/config.local.md"
    [ "$(get_nas_host)" = "router.local" ]
}

@test "common: config is read once, then served from the cache" {
    fake_root
    printf 'SSH: leoleg@mynas.local\n' > "$FAKE/.claude/config.local.md"
    load_nas_config
    rm -f "$FAKE/.claude/config.local.md"
    load_nas_config
    [ "$_NAS_HOST" = "mynas.local" ]
}

@test "common: DEFECT - the loaded flag is compared, not executed" {
    # `if $_NAS_CONFIG_LOADED` ran the variable's VALUE as a command, unquoted,
    # so it word-split too. A flag is data. The payload below is the whole
    # point: with the old form the file appears, with the new form it cannot.
    fake_root
    _NAS_CONFIG_LOADED="touch $BATS_TEST_TMPDIR/PWNED"
    load_nas_config
    [ ! -f "$BATS_TEST_TMPDIR/PWNED" ]
}

@test "common: DEFECT - the domain loaded flag is compared, not executed" {
    fake_root
    _DOMAIN_LOADED="touch $BATS_TEST_TMPDIR/PWNED-DOMAIN"
    load_domain_config
    [ ! -f "$BATS_TEST_TMPDIR/PWNED-DOMAIN" ]
}

# ----------------------------------------------------------------- get_nas_ip

@test "common: get_nas_ip reads NAS_IP from .env.nas.backup and strips quotes" {
    fake_root
    printf 'FOO=1\nNAS_IP="192.168.8.2"\nBAR=2\n' > "$FAKE/.env.nas.backup"
    [ "$(get_nas_ip)" = "192.168.8.2" ]
}

@test "common: get_nas_ip is empty when there is no backup file" {
    fake_root
    [ "$(get_nas_ip)" = "" ]
}

@test "common: a value containing = survives the split" {
    # cut -f2 stopped at the SECOND delimiter, truncating any value with an =
    # in it -- base64 padding being the everyday example. -f2- keeps the value.
    fake_root
    printf 'NAS_IP=a=b\n' > "$FAKE/.env.nas.backup"
    [ "$(get_nas_ip)" = "a=b" ]
}

@test "common: a trailing comment is part of the value, as docker reads it" {
    # Not a bug to fix: docker's own env-file parsing treats everything after
    # the = as the value, comment marker included. Matching it is correct, and
    # pinning it stops someone "fixing" this into a divergence from the runtime.
    fake_root
    printf 'NAS_IP=192.168.8.2 # the nas\n' > "$FAKE/.env.nas.backup"
    [ "$(get_nas_ip)" = "192.168.8.2 # the nas" ]
}

# ---------------------------------------------------------- get_nas_stack_dir

@test "common: .env wins over .env.nas.backup for the stack dir" {
    fake_root
    printf 'NAS_STACK_DIR=/from/env\n' > "$FAKE/.env"
    printf 'NAS_STACK_DIR=/from/backup\n' > "$FAKE/.env.nas.backup"
    [ "$(get_nas_stack_dir)" = "/from/env" ]
}

@test "common: the stack dir falls back to the backup when there is no .env" {
    fake_root
    printf 'NAS_STACK_DIR=/from/backup\n' > "$FAKE/.env.nas.backup"
    [ "$(get_nas_stack_dir)" = "/from/backup" ]
}

@test "common: the stack dir defaults when neither file exists" {
    fake_root
    [ "$(get_nas_stack_dir)" = "/volume1/docker/arr-stack" ]
}

@test "common: an .env without the key does NOT fall through to the backup" {
    # The fallback is on the FILE's existence, not the KEY's presence. An .env
    # that exists but says nothing about NAS_STACK_DIR yields the built-in
    # default and the backup is never consulted -- which is the shape of every
    # "why is it using the wrong path" afternoon. Pinned so it is at least a
    # known behaviour rather than a surprise.
    fake_root
    printf 'SOMETHING=else\n' > "$FAKE/.env"
    printf 'NAS_STACK_DIR=/from/backup\n' > "$FAKE/.env.nas.backup"
    [ "$(get_nas_stack_dir)" = "/volume1/docker/arr-stack" ]
}

# ------------------------------------------------------------- domain helpers

@test "common: get_domain reads DOMAIN from .env" {
    fake_root
    printf 'DOMAIN="example.com"\n' > "$FAKE/.env"
    [ "$(get_domain)" = "example.com" ]
}

@test "common: get_domain uses .env.nas.backup when there is no .env" {
    fake_root
    printf 'DOMAIN=example.com\n' > "$FAKE/.env.nas.backup"
    [ "$(get_domain)" = "example.com" ]
}

@test "common: an .env without DOMAIN does NOT fall through to the backup" {
    # Same existence-not-presence rule as the stack dir, pinned for the same
    # reason: the comment above it says "fallback to .env.nas.backup", and the
    # fallback it describes is not the one a reader would assume.
    fake_root
    printf 'SOMETHING=else\n' > "$FAKE/.env"
    printf 'DOMAIN=example.com\n' > "$FAKE/.env.nas.backup"
    [ "$(get_domain)" = "" ]
}

@test "common: has_custom_domain rejects empty and the placeholder" {
    fake_root
    run has_custom_domain
    assert_failure

    _DOMAIN_LOADED=true
    _DOMAIN="yourdomain.com"
    run has_custom_domain
    assert_failure

    _DOMAIN="example.com"
    run has_custom_domain
    assert_success
}

# ---------------------------------------------------------------- ssh helpers

@test "common: is_nas_reachable is false with no host, and never pings" {
    fake_root
    stub_init
    stub_tool ping 'exit 0'
    run is_nas_reachable
    assert_failure
    assert_stub_not_called ping ''
}

@test "common: is_nas_reachable follows ping's verdict" {
    fake_root
    printf 'SSH: leoleg@mynas.local\n' > "$FAKE/.claude/config.local.md"
    stub_init

    stub_tool ping 'exit 0'
    run is_nas_reachable
    assert_success
    assert_stub_called ping 'mynas.local'

    stub_tool ping 'exit 1'
    run is_nas_reachable
    assert_failure
}

@test "common: is_ssh_available is false with no host" {
    fake_root
    run is_ssh_available
    assert_failure
}

@test "common: is_ssh_available is true when the host is set and the port answers" {
    # The empty-host test above cannot see a guard that returns 1 for EVERY
    # host, because "no host configured" and "refuses to check anything" both
    # fail. Measured: mutating the guard on :219 to `-n`, and separately to
    # `||`, left this whole file green. Neither mutant is dead code. Every
    # caller is the same shape -- `if ! is_ssh_available; then SKIP` in
    # check-env-backup.sh, check-dns-duplicates.sh and check-uptime-monitors.sh
    # -- so a guard stuck at 1 does not fail a check, it makes three of them
    # skip silently on a NAS that is up.
    #
    # `timeout` EXECs its argument (docs/TEST-HARDENING-LOG.md §8), so the stub
    # has to be a real executable; a shell function would never be reached.
    # Having it on PATH is also what keeps this hermetic: the /dev/tcp connect
    # is never run, and the test passes with no network and no NAS.
    fake_root
    printf 'SSH: leoleg@mynas.local\n' > "$FAKE/.claude/config.local.md"
    stub_init
    stub_tool timeout 'exit 0'

    run is_ssh_available
    assert_success
    # And on the argv, not just the status: a stub handed no host at all would
    # produce the same success, which is the mutant's other half.
    assert_stub_called timeout 'mynas.local'
}

@test "common: DEFECT - the host is data to bash -c, never code" {
    # The host was interpolated into the string bash -c parses, so bash saw it
    # before /dev/tcp did. Nothing but load_nas_config's grep stood between a
    # host name and command execution -- a guarantee living in a different
    # function. The payload has an observable side effect precisely because a
    # connection failure looks identical either way.
    fake_root
    _NAS_CONFIG_LOADED=true
    _NAS_HOST="h; touch $BATS_TEST_TMPDIR/PWNED-SSH; :"
    run is_ssh_available
    [ ! -f "$BATS_TEST_TMPDIR/PWNED-SSH" ]
}

@test "common: ssh_to_nas builds the argv the NAS actually needs" {
    fake_root
    printf 'SSH: leoleg@mynas.local\n' > "$FAKE/.claude/config.local.md"
    stub_init
    stub_ssh 'echo remote-output'

    run ssh_to_nas 'cat /etc/hostname'
    assert_success
    assert_output "remote-output"

    # Assert on what was ASKED FOR. A stub returning 0 proves only that
    # something ran; the argv is where BatchMode and the timeout live, and both
    # are what stop this hanging a commit on an unreachable NAS.
    assert_stub_called ssh 'BatchMode=yes'
    assert_stub_called ssh 'ConnectTimeout=2'
    assert_stub_called ssh 'leoleg@mynas.local cat /etc/hostname'
    assert_nothing_forbidden
}

@test "common: ssh_to_nas uses sshpass only when both the password and sshpass exist" {
    fake_root
    printf 'SSH: leoleg@mynas.local\n' > "$FAKE/.claude/config.local.md"
    stub_init
    stub_ssh ''
    stub_tool sshpass 'exit 0'

    NAS_SSH_PASS=secret run ssh_to_nas 'true'
    assert_stub_called sshpass '\-p secret'
    assert_stub_not_called ssh 'leoleg@mynas.local'
}

@test "common: an unset NAS_SSH_PASS is not an unbound variable" {
    # The bare $NAS_SSH_PASS aborted instantly under any caller running set -u.
    # scripts/pre-commit does not, today -- which is exactly how a latent trap
    # stays latent until the first caller that does.
    fake_root
    printf 'SSH: leoleg@mynas.local\n' > "$FAKE/.claude/config.local.md"
    stub_init
    stub_ssh 'echo ok'

    unset NAS_SSH_PASS
    run bash -c 'set -u; root="$2"; source "$1"
                 get_repo_root() { echo "$root"; }
                 ssh_to_nas true' \
        _ "$REPO_ROOT/scripts/lib/common.sh" "$FAKE"
    assert_success
    assert_output "ok"
}
