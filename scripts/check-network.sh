#!/bin/bash
# Check for and optionally clean orphaned Docker networks
#
# Interactive, manual-only tooling. Nothing invokes it automatically and nothing
# is meant to: run it by hand before a deployment if you have had failed
# attempts and suspect a network is left over. "No automated caller" is not
# evidence this is dead code.
#
# Usage: ./scripts/check-network.sh

set -euo pipefail

# The networks this repo's compose files CREATE, as opposed to the ones they
# declare `external: true` and merely join. Only a network we own can be
# orphaned by a failed deploy of ours.
#
# Hardcoded rather than parsed out of the YAML at run time, for the same reason
# detect-vpn-zombies.sh hardcodes its dependent map: a bash YAML parser is a
# liability on a NAS whose compose files may be mid-sync, and this script has to
# work when the deploy is in a bad state -- that is the only time it is run.
# tests/check-network.bats derives the same set from the compose files and fails
# if the two disagree, so the list cannot go stale quietly.
OWNED_NETWORKS=(arr-core vpn-net magnetio-net traefik-lan)

# Color output, disabled when stdout is not a terminal so a redirected run or a
# `| tee` produces a readable log rather than escape sequences. Deliberately
# gated on stdout (-t 1) while the removal prompt below is gated on stdin
# (-t 0): they are different questions and a pipeline can make them disagree.
GREEN='' YELLOW='' NC=''
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
fi

# A seam, not indirection: `[[ -t 0 ]]` cannot be made true from a test without
# allocating a pty, so the only alternative to overriding this is leaving the
# entire interactive branch -- the one that reaches `docker network rm` -- with
# no test at all. tests/check-network.bats overrides it in both directions.
stdin_is_tty() { [[ -t 0 ]]; }

# Report on one network, and offer to remove it if it is orphaned.
# Args: $1 = network name
check_one_network() {
    local net="$1" containers inspect_rc=0

    if ! docker network inspect "$net" &>/dev/null; then
        echo -e "${GREEN}OK${NC}: $net doesn't exist (will be created on deploy)"
        return 0
    fi

    # Three outcomes here, not two. `inspect` prints an empty string both for a
    # network with nothing attached and for a call that failed, and this line
    # used to collapse the two with `|| true`: the failure came back as an empty
    # container list, and an empty list is what the orphan branch below asks the
    # operator to delete. A half-finished deploy is where that lands worst -- it
    # is the state this script is run in, and the one where the daemon is most
    # likely to fail one inspect and answer the next.
    #
    # The status goes into a variable rather than being read from `$?` further
    # down, because the `[[` tests in between overwrite it.
    containers=$(docker network inspect "$net" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null) || inspect_rc=$?

    if [[ "$inspect_rc" -ne 0 ]]; then
        echo -e "${YELLOW}WARNING${NC}: could not read the container list for $net: docker network inspect failed."
        echo "         That is not the same as a network with nothing attached, so it is not offered for removal."
        echo "         Look at it by hand, then re-run this script: docker network inspect $net"
        return 0
    fi

    if [[ -n "${containers// /}" ]]; then
        # The template emits a trailing space after every name, so a network
        # with one container yields "name " -- and an EMPTY one yields "". The
        # check strips spaces before testing so a future template change that
        # emits a bare separator cannot read as "in use" and silently stop this
        # script from ever offering to clean anything.
        echo -e "${GREEN}OK${NC}: $net exists with containers: $containers"
        return 0
    fi

    echo -e "${YELLOW}WARNING${NC}: $net network exists but has no containers attached."
    echo "         This may be orphaned from a previous deployment."
    echo ""

    if ! stdin_is_tty; then
        # Not interactive: say what to run, do not guess. This is the branch a
        # redirected or piped run takes, and it must never remove anything.
        echo "Run interactively to remove, or use: docker network rm $net"
        return 0
    fi

    # `|| true` because a closed stdin (Ctrl-D, or a caller that lied about
    # having a terminal) makes read return 1, and under `set -e` that would kill
    # the script mid-report. REPLY is pre-cleared so the EOF case lands on the
    # SAFE branch rather than on whatever a previous iteration left behind.
    REPLY=""
    read -r -p "Remove it? [y/N] " -n 1 REPLY || true
    echo
    if [[ "${REPLY:-}" =~ ^[Yy]$ ]]; then
        docker network rm "$net"
        echo -e "${GREEN}OK${NC}: Removed $net"
    else
        echo "Skipped. You can remove it manually with: docker network rm $net"
    fi
}

main() {
    echo ""
    echo "Checking Docker networks..."
    echo ""

    local net
    for net in "${OWNED_NETWORKS[@]}"; do
        check_one_network "$net"
    done

    echo ""
    echo "All Docker networks:"
    docker network ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}"

    echo ""
    echo "Tip: To clean up all unused networks: docker network prune"
    echo ""
}

# Sourced by tests/check-network.bats; executed by a human.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
