# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/boot-compose-up.sh.
#
# Safe to run: tests/boot-compose-up.bats points the script at a throwaway deploy
# tree via BOOT_DOCKER_ROOT and drives it with the stub harness on PATH, so
# `docker compose up` trips forbid() instead of reconciling anything.

mutation boot-magnetio-missing-from-stacks \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: every compose file in this repo is in STACKS" \
  --why "drops a compose file from the boot list, which is the state this script was actually in: magnetio was absent from the day it was added. A stack that is never brought up produces no error, no FAILED line, and a log that ends 'finished clean' - the reboot equivalent of a container that is running with no published ports, which is the failure this script exists to fix" \
  --apply 'sed -i "\@^\$DOCKER_ROOT/arr-stack/docker-compose.magnetio.yml\$@d" "$F"'

mutation boot-consumer-before-network-owner \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: STACKS orders network owners before their consumers" \
  --why "brings traefik up before the file that creates the network traefik declares external. Docker networks survive a reboot, so this is invisible on a NAS that has been up before - and fires the first time this runs after a network prune or on a rebuilt NAS, which is exactly when nobody is reading the log" \
  --apply 'sed -i "\@^\$DOCKER_ROOT/arr-stack/docker-compose.traefik.yml\$@d; s@^\$DOCKER_ROOT/arr-stack/docker-compose.magnetio.yml\$@\$DOCKER_ROOT/arr-stack/docker-compose.traefik.yml\n\$DOCKER_ROOT/arr-stack/docker-compose.magnetio.yml@" "$F"'

mutation boot-magnetio-after-arr-stack \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: magnetio comes up before arr-stack" \
  --why "puts magnetio after arr-stack. arr-stack.yml declares magnetio-net external and gluetun joins it, so on a machine where that network does not yet exist gluetun fails - and gluetun failing takes the whole arr-stack file with it, including pihole" \
  --apply 'sed -i "\@^\$DOCKER_ROOT/arr-stack/docker-compose.magnetio.yml\$@d; s@^\$DOCKER_ROOT/arr-stack/docker-compose.cloudflared.yml\$@\$DOCKER_ROOT/arr-stack/docker-compose.cloudflared.yml\n\$DOCKER_ROOT/arr-stack/docker-compose.magnetio.yml@" "$F"'

mutation boot-first-failure-aborts-the-loop \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: one failing stack does not stop the rest" \
  --why "stops the loop at the first stack that fails. DNS matters more than Immich: one bad stack early in the list would leave the entire NAS unreconciled after a reboot, which is the precise condition this script was written to fix" \
  --apply 'sed -i "s@^        failed=\"\$failed \$f\"\$@        failed=\"\$failed \$f\"; break@" "$F"'

mutation boot-missing-stack-is-fatal \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: a missing stack is skipped, not fatal" \
  --why "treats an absent compose file as a failure. frigate, immich and therapy-stack are other deployments that may not be on this NAS at all - CLAUDE.md records therapy-stack as verified absent - so this turns every single boot into a reported failure and trains whoever reads the log to stop reading it" \
  --apply 'sed -i "s@{ echo \"--- SKIP (missing): \$f\"; continue; }@{ echo \"--- SKIP (missing): \$f\"; failed=\"\$failed \$f\"; continue; }@" "$F"'

mutation boot-failures-exit-zero \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: one failing stack does not stop the rest" \
  --why "drops the non-zero exit after failures, which is how this script shipped: \`failed\` was accumulated, printed, and then could not affect the outcome. Running it by hand to check a reboot went cleanly gave 0 either way" \
  --apply 'sed -i "/=== finished WITH FAILURES/,/^fi\$/{/^    exit 1\$/d}" "$F"'

mutation boot-readiness-give-up-falls-through \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: it gives up rather than looping forever" \
  --why "logs the give-up message and then carries on anyway with no docker. Every stack is attempted, every one fails, and the log fills with six FAILED lines whose real cause is the one line above them - which is how a legible boot failure becomes an unreadable one. Note the mutation is a fall-through rather than an unbounded loop: a mutant that never terminates hangs the whole corpus run instead of failing it" \
  --apply 'sed -i "/docker never became ready/{n;s@^        exit 1\$@        break@}" "$F"'

mutation boot-log-trim-disabled \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: an oversized log is trimmed to its last 500 lines" \
  --why "raises the trim threshold beyond anything the log will reach. There is no logrotate on this NAS, so the file grows until the volume does not - and the volume filling is a stack-wide failure whose cause is a log nobody was looking at" \
  --apply 'sed -i "s@-gt 1000000 \]@-gt 100000000000 ]@" "$F"'

mutation boot-remove-orphans \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: --remove-orphans and 'down' never appear in any argv" \
  --why "adds --remove-orphans to the boot bring-up. The stack's services are split across compose files sharing one project name, so every container defined by the other files looks like an orphan to each individual file. This took out 11 containers on 2026-08-01; at boot it would do it to all of them in sequence" \
  --apply 'sed -i "s@docker compose -f \"\$(basename \"\$f\")\" up -d@docker compose -f \"\$(basename \"\$f\")\" up -d --remove-orphans@" "$F"'

mutation boot-log-trim-boundary-inclusive \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: a log of exactly the limit is left alone" \
  --why "makes the trim fire AT the limit instead of above it. A log sitting exactly on the bound is rewritten to its last 500 lines, so the oldest entries - the ones from the boot someone is asking about - are dropped by an inclusive comparison, in the one file that records what a reboot did. The sibling script needed the same boundary closed, and the same class is what the 2026-09-01 sweep found surviving elsewhere: -gt to -ge changes no exit status, only what gets rewritten" \
  --apply 'perl -pi -e "s@-gt 1000000 \]@-ge 1000000 ]@" "$F"'

mutation boot-wait-budget-off-by-one \
  --file scripts/boot-compose-up.sh \
  --bats tests/boot-compose-up.bats \
  --test "boot-compose-up: the give-up budget is the 5 minutes its message claims" \
  --why "stops the wait one attempt early. The loop sleeps 5s per attempt and gives up once the counter exceeds 60, which is the 300s the give-up line names; -ge 60 makes that 295s, so a dockerd that becomes ready in the window between gets every stack reconciled by the real script and none by this one - after a reboot, which is the one moment nobody is watching the log that still claims 5 minutes" \
  --apply 'perl -pi -e "s@-gt 60 \]@-ge 60 ]@" "$F"'
