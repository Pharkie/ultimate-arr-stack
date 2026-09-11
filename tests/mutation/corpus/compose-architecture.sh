# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for the architecture rules asserted in tests/compose-validation.bats.
#
# Safe to run: every guard here reads the compose files as text, so nothing starts
# a container and no mutant can reach the running stack. The mutated file is
# restored from a byte copy by lib-mutate.sh's EXIT trap.

mutation compose-download-client-outside-vpn \
  --file docker-compose.arr-stack.yml \
  --bats tests/compose-validation.bats \
  --test "every BitTorrent or Usenet client runs inside gluetun's namespace" \
  --why "removes qbittorrent's gluetun binding, which is the first occurrence of the line in this file. The service keeps its ports and its volumes, comes up healthy, and downloads through the house's own address instead of the tunnel: every other test in this file passes, and the swarm sees the IP the VPN exists to hide" \
  --apply 'perl -0pi -e "s/    network_mode: \\\"service:gluetun\\\"\n//" "$F"'

mutation compose-project-name-unpinned \
  --file docker-compose.arr-stack.yml \
  --bats tests/compose-validation.bats \
  --test "every compose file pins its project name" \
  --why "removes the project name, so compose derives one from the directory it is invoked in. Docker names every volume and container <project>_<name>, so the next recreate from a differently-named directory attaches a second set of empty volumes: the stack comes up looking healthy with no settings, and backup-volume-resolution.bats resolves a volume prefix nothing writes to any more" \
  --apply 'perl -0pi -e "s/^name: arr-core\n//m" "$F"'

mutation compose-arr-core-dynamic-range-widened \
  --file docker-compose.arr-stack.yml \
  --bats tests/compose-validation.bats \
  --test "the arr-core subnet and its dynamic range stay pinned" \
  --why "widens the dynamic range to the whole subnet. Static IPs in this stack are pinned outside 172.20.0.128/25 precisely so Docker's allocator cannot hand the same address to a dynamic container on its next restart -- the collision CLAUDE.md pins addresses to avoid, and one that only shows up as a service that cannot bind after an unrelated recreate" \
  --apply 'perl -pi -e "s|ip_range: 172.20.0.128/25|ip_range: 172.20.0.0/24|" "$F"'
