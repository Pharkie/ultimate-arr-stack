#!/usr/bin/env bats
# Shellcheck baseline. This session hit several bash quoting/escaping
# mistakes (nested SSH heredocs, quote-mangling - snags #1, #20) that
# shellcheck's SC2086/SC1091-class checks are built to catch. None of those
# specific snags were literal shellcheck findings (they were interactive
# command construction, not committed script bugs), but the repo had zero
# shellcheck coverage on its own scripts, which is the more direct gap.
#
# Scoped to `-S error` only: the repo already carries a handful of
# pre-existing info/warning-level findings (SC2086 unquoted vars, SC2012
# `ls` usage, SC2034 unused vars) that are unrelated to this session's work
# and out of scope to fix here - this check exists to catch genuine bugs
# (the error-severity class: broken syntax, invalid redirections, etc.),
# not to gate on style. Widening the severity is a separate, deliberate
# decision for later, not a side effect of adding this file.

setup() {
    load helpers/setup
}

@test "scripts/*.sh and terraform/apply.sh have no shellcheck errors" {
    if ! command -v shellcheck &>/dev/null; then
        skip "shellcheck not installed"
    fi

    run shellcheck -S error "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT/terraform/apply.sh"
    assert_success
}
