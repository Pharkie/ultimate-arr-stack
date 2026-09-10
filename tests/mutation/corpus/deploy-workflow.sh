# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for .github/workflows/nas-auto-deploy.yml.
#
# Safe to run: tests/deploy-workflow.bats reads the file as text and never
# dispatches anything, so a mutation here cannot reach the NAS.

mutation deploy-workflow-pushes-main-directly \
  --file .github/workflows/nas-auto-deploy.yml \
  --bats tests/deploy-workflow.bats \
  --test "deploy workflow: nothing in it pushes main directly" \
  --why "restores a direct push to main. main is protected (pull requests required, enforced for admins), so the remote rejects it - and the step that used to do this runs AFTER services have been recreated on the NAS, leaving the host deployed from a commit main never reaches" \
  --apply 'printf "          git push origin main\n" >> "$F"'

mutation deploy-workflow-no-pr-preflight \
  --file .github/workflows/nas-auto-deploy.yml \
  --bats tests/deploy-workflow.bats \
  --test "deploy workflow: a branch with no PR is refused before the NAS is touched" \
  --why "renames the preflight step, which is how it stops existing as far as the ordering assertion is concerned. Without it the run proceeds to recreate services on the NAS and only then discovers it cannot merge" \
  --apply 'sed -i "s/name: Require an open PR for this branch/name: Optional PR check/" "$F"'
