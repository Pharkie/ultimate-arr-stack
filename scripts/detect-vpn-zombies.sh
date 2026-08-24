#!/bin/bash
set -euo pipefail
#
# Report VPN-tunneled containers that are joined to a network namespace which
# is no longer Gluetun's live one.
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. It only inspects and reports —
#     it changes nothing.
#
# THE FAILURE IT LOOKS FOR
#
# Services declaring `network_mode: "service:gluetun"` do not merely depend on
# Gluetun — they live inside its network namespace, addressed by container ID.
#
# Restarting Gluetun is harmless: the ID is preserved and the dependents come
# back with it. Recreating it is not. A recreate mints a NEW container ID, and
# that can happen without anyone asking for it — `docker compose up -d` will
# recreate Gluetun whenever its own definition has drifted, even if the command
# was aimed at some unrelated service. The dependents stay pinned to the ID that
# no longer exists, and Docker never corrects the reference.
#
# The result is invisible to every routine signal. `docker ps` prints Up. The
# container's healthcheck passes, because it asks its own localhost. deunhealth
# sees nothing wrong because nothing reports unhealthy. Meanwhile the service is
# unreachable from the rest of the stack, and its traffic has nowhere to go.
#
# Usage:
#   ./scripts/detect-vpn-zombies.sh
#
# Exit codes:
#   0 = every tunneled dependent is inside Gluetun's current namespace
#   1 = at least one is stranded, or the check could not be completed
#
# Remedy for anything reported: docker restart <container>
#
# Reasonable to run after any Gluetun recreate, or on a timer:
#   */5 * * * * /path/to/arr-stack/scripts/detect-vpn-zombies.sh || notify "VPN zombie!"

# Keep in step with the services carrying network_mode: "service:gluetun" in
# docker-compose.arr-stack.yml. Sonarr and Radarr are intentionally excluded:
# they sit on the arr-stack bridge (docs/MIGRATION-arr-off-vpn.md).
TUNNELED=(qbittorrent sabnzbd prowlarr flaresolverr)

die() { echo "ERROR: $*" >&2; exit 1; }

live_namespace=$(docker inspect --format '{{.Id}}' gluetun 2>/dev/null) \
    || die "cannot inspect gluetun — is the container present?"

[[ -n "$live_namespace" ]] || die "gluetun reported an empty container ID"

stranded=()
skipped=()

for service in "${TUNNELED[@]}"; do
    net=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$service" 2>/dev/null) || {
        # Absent or not running: there is no namespace binding to judge, and
        # calling that a zombie would be a false positive.
        skipped+=("$service")
        continue
    }

    # Anything not joined to another container's namespace is out of scope.
    case "$net" in
        container:*) target=${net#container:} ;;
        *) skipped+=("$service"); continue ;;
    esac

    [[ "$target" == "$live_namespace" ]] && continue

    # Distinguish the two ways of being wrong: pointing at a container that has
    # been destroyed, versus pointing at one that still exists but is not the
    # Gluetun in service. Both are broken; they read very differently when you
    # are trying to work out what happened.
    if docker inspect --format '{{.Id}}' "$target" >/dev/null 2>&1; then
        stranded+=("${service} (joined to a different live container)")
    else
        stranded+=("${service} (joined to a destroyed container)")
    fi
done

if [[ ${#skipped[@]} -gt 0 ]]; then
    echo "Not checked (absent, stopped, or not namespace-joined): ${skipped[*]}"
fi

if [[ ${#stranded[@]} -gt 0 ]]; then
    echo "STRANDED — outside Gluetun's current network namespace:"
    for entry in "${stranded[@]}"; do
        echo "  - ${entry}"
    done
    # Names only, so the suggestion is directly runnable.
    names=$(printf '%s\n' "${stranded[@]}" | cut -d' ' -f1 | tr '\n' ' ')
    echo "Fix: docker restart ${names% }"
    exit 1
fi

echo "OK: every tunneled dependent is inside Gluetun's current namespace"
