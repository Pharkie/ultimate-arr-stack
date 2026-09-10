# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for docker-compose.cloudflared.yml's opt-in profile.
#
# Safe to run: the guard under test reads the compose file as text. Nothing here
# starts a container, so a mutant cannot reach the live tunnel -- and the mutated
# file is restored from a byte copy by lib-mutate.sh's EXIT trap.

mutation cloudflared-profile-removed \
  --file docker-compose.cloudflared.yml \
  --bats tests/compose-validation.bats \
  --test "cloudflared is opt-in: a plain 'up -d' cannot start a tunnel with no config" \
  --why "removes the profile that keeps cloudflared out of an unconditional 'up -d'. cloudflared/config.yml is gitignored, so on any checkout where an operator has not created one there is no tunnel config: scripts/boot-compose-up.sh (every boot) and scripts/restart-stack.sh's all arm would start cloudflared, have it exit immediately, and let 'restart: always' loop it -- the crash-loop observed on this NAS on 2026-08-16" \
  --apply 'sed -i "/^    profiles:/d" "$F"'
