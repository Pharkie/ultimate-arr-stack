#!/usr/bin/env bats
# .github/workflows/nas-auto-deploy.yml
#
# main is protected: pull requests are required, force-pushes and deletions are
# refused, and `enforce_admins` makes that apply to the owner's own pushes. The
# workflow used to merge a dispatched branch locally and `git push origin main`
# when no PR existed, and scripts/post-merge still pushes from a local merge.
# Both would now be rejected by the remote -- and the workflow would be rejected
# AFTER it had already recreated services on the NAS, which is the worst version
# of the failure: host deployed, main unchanged.
#
# These assertions read the file as text on purpose. The alternative is driving
# a workflow_dispatch, which needs the NAS, secrets and a real PR.

setup() {
    load helpers/setup
    WF="$REPO_ROOT/.github/workflows/nas-auto-deploy.yml"
}

@test "deploy workflow: nothing in it pushes main directly" {
    run grep -nE 'git +push[^|]*\bmain\b' "$WF"
    [ "$status" -ne 0 ] || {
        echo "a direct push to main survives in the workflow:"
        echo "$output"
        return 1
    }
}

@test "deploy workflow: it merges through a pull request" {
    run grep -qE 'gh pr merge' "$WF"
    [ "$status" -eq 0 ] || { echo "no gh pr merge anywhere in the workflow"; return 1; }
}

@test "deploy workflow: a branch with no PR is refused before the NAS is touched" {
    local preflight first_nas_step
    preflight=$(grep -n 'Require an open PR' "$WF" | head -1 | cut -d: -f1)
    first_nas_step=$(grep -n 'Sync branch to NAS' "$WF" | head -1 | cut -d: -f1)
    [ -n "$preflight" ] || fail "the workflow has no preflight step for a missing PR"
    [ -n "$first_nas_step" ] || fail "the workflow no longer has a NAS sync step to order against"
    [ "$preflight" -lt "$first_nas_step" ] \
        || fail "the PR preflight is at line $preflight, after the first NAS step at $first_nas_step - it must fail before anything is deployed"
}
