#!/usr/bin/env bats
# Tests for the pre-commit check scripts themselves

setup() {
    load helpers/setup
    # Source the check scripts
    source "$REPO_ROOT/scripts/lib/common.sh"
}

@test "check_secrets catches a known WireGuard key pattern" {
    source "$REPO_ROOT/scripts/lib/check-secrets.sh"

    # Copy fixture to a temp path that won't match the tests/fixtures/* skip rule
    local tmpdir
    tmpdir=$(mktemp -d)
    cp "$REPO_ROOT/tests/fixtures/compose-with-secrets.yml" "$tmpdir/docker-compose.secrets.yml"

    # Override get_files_to_scan to return the temp copy
    get_files_to_scan() {
        echo "docker-compose.secrets.yml"
    }

    # Override read_file_content to read from the temp dir
    read_file_content() {
        cat "$tmpdir/$1" 2>/dev/null
    }

    run check_secrets
    assert_failure
    assert_output --partial "WireGuard private key"

    rm -rf "$tmpdir"
}

@test "check_env_vars catches an undocumented variable" {
    source "$REPO_ROOT/scripts/lib/check-env-vars.sh"

    # Create a temp compose file with an undocumented var
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.test.yml" <<'EOF'
services:
  test:
    image: alpine:3.20
    environment:
      - UNDOCUMENTED_VAR_XYZZY=${UNDOCUMENTED_VAR_XYZZY}
EOF

    # Run check_env_vars in a subshell with overridden repo root
    run bash -c "
        source '$REPO_ROOT/scripts/lib/common.sh'
        source '$REPO_ROOT/scripts/lib/check-env-vars.sh'
        # Override git rev-parse to use tmpdir
        git() { echo '$tmpdir'; }
        export -f git
        # Copy .env.example to tmpdir
        cp '$REPO_ROOT/.env.example' '$tmpdir/'
        check_env_vars
    "
    assert_failure
    assert_output --partial "UNDOCUMENTED_VAR_XYZZY"

    rm -rf "$tmpdir"
}

@test "check_conflicts catches duplicate ports within a file" {
    source "$REPO_ROOT/scripts/lib/check-conflicts.sh"

    # Create a temp dir with a conflicting compose file
    local tmpdir
    tmpdir=$(mktemp -d)
    cp "$REPO_ROOT/tests/fixtures/compose-port-conflict.yml" "$tmpdir/docker-compose.conflict.yml"

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-conflicts.sh'
        # Override git rev-parse to use tmpdir
        git() { echo '$tmpdir'; }
        export -f git
        check_conflicts
    "
    assert_failure
    assert_output --partial "Duplicate ports"

    rm -rf "$tmpdir"
}

@test "check_conflicts catches cross-file port duplicates" {
    source "$REPO_ROOT/scripts/lib/check-conflicts.sh"

    # Create two compose files with same port in different files
    local tmpdir
    tmpdir=$(mktemp -d)
    cat > "$tmpdir/docker-compose.a.yml" <<'EOF'
services:
  svc-a:
    image: alpine:3.20
    ports:
      - "9999:80"
EOF
    cat > "$tmpdir/docker-compose.b.yml" <<'EOF'
services:
  svc-b:
    image: alpine:3.20
    ports:
      - "9999:8080"
EOF

    run bash -c "
        source '$REPO_ROOT/scripts/lib/check-conflicts.sh'
        git() { echo '$tmpdir'; }
        export -f git
        check_conflicts
    "
    assert_failure
    assert_output --partial "Port 9999 used across multiple files"

    rm -rf "$tmpdir"
}
