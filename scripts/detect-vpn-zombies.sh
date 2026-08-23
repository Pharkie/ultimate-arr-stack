#!/bin/bash
set -euo pipefail
#
# Detects VPN-tunneled containers whose network namespace binding is stale
# relative to Gluetun's *current* container ID — the "zombie" failure mode
# from a Gluetun recreate (docker compose up -d, even of an unrelated
# service, if Gluetun's own config drifted). Neither `docker ps`, container
# health status, nor deunhealth can see this: a zombie still answers fine on
# its own localhost healthcheck, but is completely unreachable from the rest
# of the stack because it's bound to a network namespace that no longer
# exists as "gluetun" — Docker just hasn't cleaned up the dead reference.
#
# Usage:
#   ./scripts/detect-vpn-zombies.sh
#
# Exit codes:
#   0 = all VPN-tunneled dependents share Gluetun's current netns
#   1 = one or more zombies found (or the check itself failed)
#
# Fix for a detected zombie: docker restart <container>
#
# Use in cron or after any Gluetun recreate:
#   */5 * * * * /path/to/arr-stack/scripts/detect-vpn-zombies.sh || notify "VPN zombie container!"

GLUETUN_ID=$(docker inspect --format '{{.Id}}' gluetun 2>/dev/null) || {
    echo "ERROR: Could not inspect gluetun — is it running?"
    exit 1
}

# Must list every container with network_mode: "service:gluetun" or
# "container:gluetun" across all compose files — grep for that pattern when
# adding a new VPN-tunneled service, this list doesn't derive itself.
DEPENDENTS=(qbittorrent sabnzbd prowlarr flaresolverr vpn-socks5 magnetio-addon)
zombies=()

for c in "${DEPENDENTS[@]}"; do
    mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$c" 2>/dev/null) || continue
    [[ "$mode" == container:* ]] || continue
    if [[ "$mode" != "container:$GLUETUN_ID" ]]; then
        zombies+=("$c")
    fi
done

# Second gateway: gluetun-exit (docker-compose.tailscale.yml), the dedicated
# ProtonVPN tunnel behind the Tailscale exit node. Its dependents hit exactly
# the same stale-netns failure mode, but they can't be folded into DEPENDENTS
# above — they're bound to a DIFFERENT gateway container, so they'd be flagged
# as zombies against gluetun's ID every single time.
#
# Unlike gluetun, a missing gluetun-exit is NOT an error: the exit-node stack
# is opt-in, so most deployments won't have it running.
EXIT_DEPENDENTS=(tailscale-exit tailscale-exit-routing gluetun-exit-rotator)

if GLUETUN_EXIT_ID=$(docker inspect --format '{{.Id}}' gluetun-exit 2>/dev/null); then
    for c in "${EXIT_DEPENDENTS[@]}"; do
        mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$c" 2>/dev/null) || continue
        [[ "$mode" == container:* ]] || continue
        if [[ "$mode" != "container:$GLUETUN_EXIT_ID" ]]; then
            zombies+=("$c")
        fi
    done
fi

if [[ ${#zombies[@]} -gt 0 ]]; then
    echo "ZOMBIE CONTAINERS (stale netns binding to a dead Gluetun): ${zombies[*]}"
    echo "Fix: docker restart ${zombies[*]}"
    exit 1
fi

echo "OK: all VPN-tunneled dependents share Gluetun's current netns"
