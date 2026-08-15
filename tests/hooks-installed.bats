#!/usr/bin/env bats
# Regression guard: the pre-commit hook (which runs check_conflicts, among
# other blocking checks) must actually be installed, or none of those checks
# ever run before a commit lands. A prior static-IP collision reached the
# repo uncaught specifically because this hook was never installed — the
# detection logic in check-conflicts.sh was correct the whole time; nothing
# was invoking it. Run ./setup-hooks.sh if this test fails.

setup() {
    load helpers/setup
}

@test "pre-commit hook is installed and points at scripts/pre-commit" {
    local git_common_dir
    git_common_dir=$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir)
    local hook_path="$git_common_dir/hooks/pre-commit"

    if [[ ! -e "$hook_path" ]]; then
        fail "Pre-commit hook not installed at $hook_path — run ./setup-hooks.sh"
    fi

    if [[ -L "$hook_path" ]]; then
        local target
        target=$(readlink "$hook_path")
        [[ "$target" == *"scripts/pre-commit" ]] || fail "Pre-commit hook symlink points at unexpected target: $target"
    fi
}
