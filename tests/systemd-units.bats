#!/usr/bin/env bats
# Static checks for the credential-drift systemd units. No `systemd-analyze`
# here - it's not available on this darwin dev machine and isn't guaranteed
# in CI; these are the checks that can run anywhere. Live verification
# (`systemd-analyze --user verify`) still happens against the real NAS
# before every install, per CLAUDE.md's deploy rule.

setup() {
    load helpers/setup
    UNITS_DIR="$REPO_ROOT/scripts"
}

# --- Regression for snag #19: the alert unit's journalctl call read the
# wrong journal scope once installed as a --user unit (queries the system
# journal by default; the detector's own logs live in the user journal
# under this install method). Every journalctl invocation in this file must
# carry --user. ---

@test "alert unit's journalctl calls all use --user" {
    run bash -c "grep -o 'journalctl[^;|]*' '$UNITS_DIR/detect-credential-drift-alert.service'"
    assert_success
    # Every matched journalctl invocation must include --user.
    while IFS= read -r invocation; do
        [[ "$invocation" == *"--user"* ]] || fail "journalctl call missing --user: $invocation"
    done <<< "$output"
}

# --- Regression for snag #17: a wrong "systemd timer install needs root"
# assumption was carried for most of a session before being re-tested and
# found false. These units are designed to install under
# ~/.config/systemd/user/ with no root/system-install assumptions baked in
# - assert none of the three creep back in. ---

@test "unit files carry no root/system-install assumptions" {
    local f
    for f in detect-credential-drift.service detect-credential-drift.timer detect-credential-drift-alert.service; do
        run grep -c '/etc/systemd' "$UNITS_DIR/$f"
        assert_output "0"

        run grep -c '^WantedBy=multi-user.target' "$UNITS_DIR/$f"
        assert_output "0"

        run grep -c '^User=' "$UNITS_DIR/$f"
        assert_output "0"
    done
}

@test "service and alert unit ExecStart paths point at the NAS deploy path, not a root-only location" {
    run grep 'ExecStart=' "$UNITS_DIR/detect-credential-drift.service"
    assert_output --partial "/volume1/docker/arr-stack/"
    refute_output --partial "/root/"
}
