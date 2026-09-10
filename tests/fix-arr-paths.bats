#!/usr/bin/env bats
# scripts/fix-radarr-paths.sh and scripts/fix-sonarr-folders.sh -- bash halves.
#
# Both scripts read one API key out of a `.env` and hand it to a Python module.
# They had two different wrong readers between them until 2026-09-01, and the
# failure mode was silent in both: a key containing an '=' was truncated at it,
# so the script authenticated with a prefix of the real key and the arr API
# answered 401. Nothing in either script reports a 401 as a configuration
# problem, so it surfaced as "the fixer did nothing".
#
# Driven out of a throwaway copy: both derive their .env path from their own
# location, and a test must never read the repo's real one.

# `run --separate-stderr` is a 1.5.0 feature.
bats_require_minimum_version 1.5.0

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    STACK="$BATS_TEST_TMPDIR/stack"
    mkdir -p "$STACK/scripts/lib"
    cp "$REPO_ROOT/scripts/lib/env-file.sh" "$STACK/scripts/lib/"
    cp "$REPO_ROOT/scripts/fix-radarr-paths.sh" \
       "$REPO_ROOT/scripts/fix-sonarr-folders.sh" "$STACK/scripts/"
    cp "$REPO_ROOT/scripts/lib/fix_radarr_paths.py" \
       "$REPO_ROOT/scripts/lib/fix_sonarr_folders.py" "$STACK/scripts/lib/"

    RADARR="$STACK/scripts/fix-radarr-paths.sh"
    SONARR="$STACK/scripts/fix-sonarr-folders.sh"
    ENV="$STACK/.env"

    MEDIA="$BATS_TEST_TMPDIR/media"
    mkdir -p "$MEDIA/media/movies"

    # Empty body on purpose, not an oversight: this half of the fixer only decides
    # curl's argv (asserted below) and redirects the response into a file that the
    # *Python* half reads -- and python3 is stubbed out on the next line. The JSON
    # contract is owned by tests/python/test_fix_radarr_paths.py, not by this file.
    stub_curl ''
    # Neither script's Python half is under test here; what it was handed is.
    stub_tool python3 'echo "ARGV: $*"'
}

env_with() {
    printf '%s\n' "$@" > "$ENV"
}

# --- fix-radarr-paths.sh --------------------------------------------------

@test "fix-radarr: a missing .env is a clear error, not a crash" {
    rm -f "$ENV"
    run "$RADARR"
    [ "$status" -eq 1 ]
    [[ "$output" == *".env not found"* ]]
}

@test "fix-radarr: an .env without the key is a clear error" {
    env_with "MEDIA_ROOT=$MEDIA"
    run "$RADARR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"RADARR_API_KEY not found"* ]]
}

@test "fix-radarr: a key containing an equals sign reaches the API intact" {
    # The defect. `cut -d= -f2` handed over "abc" and the run failed as a 401
    # with no message saying so.
    env_with "RADARR_API_KEY=abc=def==" "MEDIA_ROOT=$MEDIA"
    run "$RADARR"
    [ "$status" -eq 0 ]
    assert_stub_called curl "apikey=abc=def=="
}

@test "fix-radarr: a quoted key is unquoted before use" {
    env_with 'RADARR_API_KEY="abc123"' "MEDIA_ROOT=$MEDIA"
    run "$RADARR"
    assert_stub_called curl "apikey=abc123"
    assert_stub_not_called curl 'apikey=%22'
}

@test "fix-radarr: a quoted MEDIA_ROOT still resolves to a real directory" {
    env_with "RADARR_API_KEY=k" "MEDIA_ROOT=\"$MEDIA\""
    run "$RADARR"
    [ "$status" -eq 0 ]
}

@test "fix-radarr: a missing movies directory is a clear error" {
    env_with "RADARR_API_KEY=k" "MEDIA_ROOT=$BATS_TEST_TMPDIR/nowhere"
    run "$RADARR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Movies directory not found"* ]]
}

@test "fix-radarr: an .env that is a directory is reported as a missing .env" {
    rm -f "$ENV"
    mkdir "$ENV"
    run "$RADARR"
    [ "$status" -eq 1 ]
    [[ "$output" == *".env not found"* ]]
}

@test "fix-radarr: a movies path that is a file is reported as a missing directory" {
    env_with "RADARR_API_KEY=k" "MEDIA_ROOT=$BATS_TEST_TMPDIR/notadir"
    mkdir -p "$BATS_TEST_TMPDIR/notadir/media"
    : > "$BATS_TEST_TMPDIR/notadir/media/movies"
    run "$RADARR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Movies directory not found"* ]]
}

@test "fix-radarr: an .env with a key but no MEDIA_ROOT still explains itself" {
    # Not just "exits 1": with MEDIA_ROOT unset the movies path resolves to
    # /media/movies and the script must SAY that, rather than dying at the
    # assignment with no output at all.
    env_with "RADARR_API_KEY=k"
    run "$RADARR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Movies directory not found"* ]]
}

@test "fix-radarr: a failed library dump aborts before the fixer runs" {
    # curl writes movies.json; if it fails the file is empty or absent, and
    # handing that to the fixer would have it conclude the library is empty.
    env_with "RADARR_API_KEY=k" "MEDIA_ROOT=$MEDIA"
    stub_curl 'exit 7'
    run "$RADARR"
    [ "$status" -ne 0 ]
    assert_stub_not_called python3 ""
}

@test "fix-radarr: the fatal error goes to stderr, not stdout" {
    env_with "RADARR_API_KEY=k" "MEDIA_ROOT=$MEDIA"
    stub_tool python3 'exit 4'
    run --separate-stderr "$RADARR"
    [[ "$stderr" == *"path fixer exited non-zero"* ]]
    [[ "$output" != *"path fixer exited non-zero"* ]]
}

@test "fix-radarr: hands the Python half the key and a temp directory" {
    env_with "RADARR_API_KEY=k" "MEDIA_ROOT=$MEDIA"
    run "$RADARR"
    [[ "$output" == *"ARGV: "*"fix_radarr_paths.py k /tmp/fix-radarr-"* ]]
}

@test "fix-radarr: the disk listing it collects is the movies directory" {
    mkdir -p "$MEDIA/media/movies/Alpha (1999)"
    env_with "RADARR_API_KEY=k" "MEDIA_ROOT=$MEDIA"
    stub_tool python3 'cat "$3/disk_dirs.txt"'
    run "$RADARR"
    [[ "$output" == *"Alpha (1999)"* ]]
}

@test "fix-radarr: the temp directory is removed even when the fixer fails" {
    env_with "RADARR_API_KEY=k" "MEDIA_ROOT=$MEDIA"
    stub_tool python3 'echo "$3" > '"$BATS_TEST_TMPDIR/tmpdir"'; exit 1'
    run "$RADARR"
    [ "$status" -eq 1 ]
    # An absolute path, asserted as such: a relative one would make the -e
    # check pass against a name that was never going to exist anyway.
    [[ "$(cat "$BATS_TEST_TMPDIR/tmpdir")" == /* ]]
    [ ! -e "$(cat "$BATS_TEST_TMPDIR/tmpdir")" ]
}

@test "fix-radarr: a failing Python half is fatal and says so" {
    env_with "RADARR_API_KEY=k" "MEDIA_ROOT=$MEDIA"
    stub_tool python3 'exit 4'
    run "$RADARR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"path fixer exited non-zero"* ]]
}

# --- fix-sonarr-folders.sh ------------------------------------------------

@test "fix-sonarr: no key anywhere is a clear error" {
    rm -f "$ENV"
    run "$SONARR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"SONARR_API_KEY not found"* ]]
}

@test "fix-sonarr: a missing library aborts rather than blaming the API key" {
    # Both branches exit 1, so the status says nothing. What errexit buys is
    # the right diagnosis: without it the failed `.` is ignored, `env_value`
    # is then not a command, the substitution yields an empty key, and the
    # script reports a missing SONARR_API_KEY -- sending whoever reads the
    # cron mail to edit an .env that was never the problem.
    env_with "SONARR_API_KEY=k"
    rm -f "$STACK/scripts/lib/env-file.sh"
    run "$SONARR"
    [ "$status" -ne 0 ]
    [[ "$output" != *"SONARR_API_KEY not found"* ]]
}

@test "fix-sonarr: falls back to .env.nas.backup when .env has no key" {
    env_with "OTHER=1"
    printf 'SONARR_API_KEY=frombackup\n' > "$STACK/.env.nas.backup"
    run "$SONARR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"fix_sonarr_folders.py frombackup "* ]]
}

@test "fix-sonarr: .env wins over .env.nas.backup when both have a key" {
    env_with "SONARR_API_KEY=fromenv"
    printf 'SONARR_API_KEY=frombackup\n' > "$STACK/.env.nas.backup"
    run "$SONARR"
    [[ "$output" == *"fix_sonarr_folders.py fromenv "* ]]
}

@test "fix-sonarr: a key containing an equals sign is passed whole" {
    env_with "SONARR_API_KEY=abc=def=="
    run "$SONARR"
    [[ "$output" == *"fix_sonarr_folders.py abc=def== "* ]]
}

@test "fix-sonarr: a single-quoted key is unquoted before use" {
    env_with "SONARR_API_KEY='abc123'"
    run "$SONARR"
    [[ "$output" == *"fix_sonarr_folders.py abc123 "* ]]
}

@test "fix-sonarr: the default mode passes false, and says it is a dry run" {
    env_with "SONARR_API_KEY=k"
    run "$SONARR"
    [[ "$output" == *"Mode: DRY RUN"* ]]
    [[ "$output" == *"http://localhost:8989 false"* ]]
}

@test "fix-sonarr: --apply passes the lowercase true the Python half expects" {
    # Defect #4 lived on exactly this boundary: bash writes `true`, and the
    # heredoc compared against "True", so --apply renamed nothing for the whole
    # life of the script while printing a summary that read like a plan.
    env_with "SONARR_API_KEY=k"
    run "$SONARR" --apply
    [[ "$output" == *"Mode: APPLYING CHANGES"* ]]
    [[ "$output" == *"http://localhost:8989 true"* ]]
}

@test "fix-sonarr: an unrecognised argument does not enable applying" {
    env_with "SONARR_API_KEY=k"
    run "$SONARR" --appply
    [[ "$output" == *"Mode: DRY RUN"* ]]
    [[ "$output" == *"http://localhost:8989 false"* ]]
}

@test "fix-sonarr: a failing Python half is fatal and says so" {
    env_with "SONARR_API_KEY=k"
    stub_tool python3 'exit 5'
    run "$SONARR" --apply
    [ "$status" -eq 1 ]
    [[ "$output" == *"folder fixer exited non-zero"* ]]
}

@test "fix-sonarr: the fatal error goes to stderr, not stdout" {
    env_with "SONARR_API_KEY=k"
    stub_tool python3 'exit 5'
    run --separate-stderr "$SONARR"
    [[ "$stderr" == *"folder fixer exited non-zero"* ]]
    [[ "$output" != *"folder fixer exited non-zero"* ]]
}

@test "fix-arr: neither script reaches a destructive operation on its own" {
    env_with "RADARR_API_KEY=k" "SONARR_API_KEY=k" "MEDIA_ROOT=$MEDIA"
    run "$RADARR"
    run "$SONARR"
    assert_nothing_forbidden
}
