#!/bin/bash
#
# Safe stack restart - NEVER uses 'down' which kills Pi-hole DNS
#
# Usage:
#   ./scripts/restart-stack.sh           # Restart all compose files
#   ./scripts/restart-stack.sh arr       # Restart arr-stack only
#   ./scripts/restart-stack.sh traefik   # Restart traefik only
#   ./scripts/restart-stack.sh utilities # Restart utilities only
#   ./scripts/restart-stack.sh magnetio  # Restart the magnetio addon only
#
# "all" means every compose file in the repo EXCEPT docker-compose.tailscale.yml,
# and that exclusion is deliberate: recreating Tailscale node 1 severs every path
# to the NAS at once -- SSH and the UGOS admin UI both ride its own subnet route,
# so the command that would fix it arrives over the link it just cut. Rotate or
# restart that one by hand, detached, with a state-volume backup. See CLAUDE.md.
#
# tests/restart-stack.bats derives the covered set from the filesystem, so a new
# docker-compose.*.yml fails the suite until someone decides which list it joins.
#
# ORDER IN THE "all" ARM IS A DEPENDENCY ORDER, read off the compose files
# themselves, not a preference:
#
#   magnetio  creates magnetio-net, which docker-compose.arr-stack.yml declares
#             `external: true` and gluetun joins. That file says so in a comment:
#             recreate gluetun without it and you get "network not found".
#   arr-stack creates arr-core AND holds pihole/dnscrypt-proxy, so it is both the
#             network owner and the DNS the rest of the house needs.
#   traefik,  all declare arr-core `external: true`, so none of them can come up
#   cloudflared,  before the file that creates it. docs/UPGRADING.md states this
#   utilities     directly: "Start arr-stack first - it now owns the network.
#             Traefik and utilities reference it as external: true."
#             Cloudflared additionally forwards to http://traefik:80.
#
# This arm ran traefik first until 2026-09-01, which is backwards on both counts.
# It survived because the networks already existed on the one machine it was ever
# run on -- `up -d` on an existing external network is a no-op. On a machine where
# arr-core was absent (fresh deploy, or after a network prune) traefik would fail,
# and `set -e` means the run would abort BEFORE arr-stack, so the recovery command
# for a house with no DNS would itself never start DNS.
#

set -euo pipefail
cd "$(dirname "$0")/.."

restart_compose() {
    local file="$1"
    local name="$2"
    echo "♻️  Restarting $name..."
    # Output is captured rather than streamed so the "restarted" line below can be
    # made conditional on compose having actually selected a service. A stack
    # whose only service sits behind an unselected profile (cloudflared, until an
    # operator opts in) exits 0 having done nothing, and reporting that as
    # "restarted" is the same false-success shape this repo keeps finding in its
    # own guards. `up -d` is a short-lived command, so nothing is lost by it.
    local out rc=0
    out=$(docker compose -f "$file" up -d --force-recreate 2>&1) || rc=$?
    # `if`, not `[ -n "$out" ] && printf` -- a false test as a standalone statement
    # returns non-zero and `set -e` (set at the top of this file) would abort the
    # whole run on a stack that produced no output.
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
    fi
    if [ "$rc" -ne 0 ]; then
        # The exit code is propagated unchanged, not flattened to 1. The stub
        # harness in tests/helpers/stubs.bash signals "a test tried to reach live
        # docker" with 99, and tests/restart-stack.bats asserts on that number;
        # swallowing it here would make the harness's refusal indistinguishable
        # from an ordinary compose failure.
        echo "❌ $name FAILED (exit $rc)" >&2
        return "$rc"
    fi
    if printf '%s' "$out" | grep -q "no service selected"; then
        echo "⏭️  $name skipped - opt-in profile not enabled"
        return 0
    fi
    echo "✅ $name restarted"
}

case "${1:-all}" in
    arr|arr-stack)
        restart_compose docker-compose.arr-stack.yml "arr-stack"
        ;;
    traefik)
        restart_compose docker-compose.traefik.yml "traefik"
        ;;
    cloudflared|tunnel)
        restart_compose docker-compose.cloudflared.yml "cloudflared"
        ;;
    utilities|utils)
        restart_compose docker-compose.utilities.yml "utilities"
        ;;
    magnetio)
        restart_compose docker-compose.magnetio.yml "magnetio"
        ;;
    all)
        restart_compose docker-compose.magnetio.yml "magnetio"
        restart_compose docker-compose.arr-stack.yml "arr-stack"
        restart_compose docker-compose.traefik.yml "traefik"
        restart_compose docker-compose.cloudflared.yml "cloudflared"
        restart_compose docker-compose.utilities.yml "utilities"
        echo ""
        echo "✅ All stacks restarted"
        ;;
    *)
        echo "Usage: $0 [arr|traefik|cloudflared|utilities|magnetio|all]"
        exit 1
        ;;
esac
