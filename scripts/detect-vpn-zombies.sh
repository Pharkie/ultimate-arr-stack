#!/bin/bash
#
# Find VPN services stranded outside gluetun's current network namespace.
#
# A service with network_mode "service:gluetun" is recorded by Docker as
# "container:<gluetun's ID when the service was created>". When gluetun is
# RECREATED (not merely restarted) it gets a new ID, and those services are
# left joined to the old one: running with no usable network, or exited. A
# plain `docker restart` cannot save them, because it re-joins the dead ID.
# See docs/TROUBLESHOOTING.md, "After a Gluetun RECREATE".
#
# Usage: ./scripts/detect-vpn-zombies.sh
#
# Exit 0: no service is stranded (prints an OK line).
# Exit 1: at least one is; each is listed, with the command that fixes them.
# Exit 2: gluetun itself could not be inspected, so nothing was compared.
#
# A gluetun RESTART (same ID, stale namespace) is the other failure mode;
# gluetun-recover in docker-compose.utilities.yml handles that one.
#
# Environment overrides:
#   GLUETUN_CONTAINER  the VPN container (default: gluetun)
#
# It only reads (docker inspect). It restarts and changes nothing.
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. It only inspects and reports —
#     it changes nothing.
#

set -uo pipefail

# Every service bound into gluetun's namespace, by container name. Keep it on
# ONE line: tests/vpn-zombies.bats parses it, and fails when it drifts from
# the network_mode bindings in the compose files.
TUNNELED=(qbittorrent sabnzbd prowlarr flaresolverr)

GLUETUN="${GLUETUN_CONTAINER:-gluetun}"

# One line, whitespace squeezed: docker's multi-line errors stay readable.
oneline() { printf '%s' "$*" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'; }

is_no_such() { case "$1" in *"No such"*|*"no such"*) return 0 ;; esac; return 1; }

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker not found on PATH — nothing was checked"
    exit 2
fi

# gluetun's current ID is the reference everything is compared against.
if ! gid=$(docker inspect --type container -f '{{.Id}}' "$GLUETUN" 2>&1); then
    echo "ERROR: cannot inspect the gluetun container '$GLUETUN': $(oneline "$gid")"
    echo "       Without its current ID there is nothing to compare against."
    exit 2
fi
gid=$(oneline "$gid")
# An empty or odd ID would make every comparison below meaningless: an empty
# one would even match a service whose network mode lost its ID.
if [ -z "$gid" ]; then
    echo "ERROR: docker inspect returned an empty ID for '$GLUETUN'"
    exit 2
fi
case "$gid" in
    *[!0-9a-f]*)
        echo "ERROR: docker inspect returned an unexpected ID for '$GLUETUN': $gid"
        exit 2 ;;
esac

stranded="" n_stranded=0 n_joined=0 n_skipped=0 n_errors=0

for svc in "${TUNNELED[@]}"; do
    if ! info=$(docker inspect --type container -f '{{.HostConfig.NetworkMode}}|{{.State.Status}}' "$svc" 2>&1); then
        if is_no_such "$info"; then
            # Optional services (SABnzbd, say) may simply not be deployed.
            echo "  SKIP    $svc: no such container"
            n_skipped=$((n_skipped + 1))
        else
            echo "  ERROR   $svc: cannot inspect: $(oneline "$info")"
            n_errors=$((n_errors + 1))
        fi
        continue
    fi
    mode="${info%|*}" state="${info##*|}"

    case "$mode" in
        container:?*) ref="${mode#container:}" ;;
        *)
            # Not a zombie: it is on some other network entirely. Whether
            # that leaks is check-vpn.sh's question, not this script's.
            echo "  SKIP    $svc: not joined to any container's namespace (network mode '$mode'); run check-vpn.sh to verify its egress"
            n_skipped=$((n_skipped + 1))
            continue ;;
    esac

    if [ "$ref" = "$gid" ]; then
        echo "  OK      $svc ($state) is in $GLUETUN's namespace"
        n_joined=$((n_joined + 1))
        continue
    fi

    # The reference is not gluetun's current ID. It may still name gluetun
    # (a short ID, or a container name), so ask Docker what it points at.
    if target=$(docker inspect --type container -f '{{.Id}} {{.Name}}' "$ref" 2>&1); then
        tid="${target%% *}" tname="${target#* }"
        tname="${tname#/}"
        if [ "$tid" = "$gid" ]; then
            echo "  OK      $svc ($state) is in $GLUETUN's namespace"
            n_joined=$((n_joined + 1))
            continue
        fi
        echo "  ZOMBIE  $svc ($state): joined to $tname (${tid:0:12}), a different container from $GLUETUN (${gid:0:12})"
    elif is_no_such "$target"; then
        echo "  ZOMBIE  $svc ($state): joined to ${ref:0:12}, which no longer exists; $GLUETUN is now ${gid:0:12}"
    else
        echo "  ERROR   $svc: cannot inspect the container it is joined to (${ref:0:12}): $(oneline "$target")"
        n_errors=$((n_errors + 1))
        continue
    fi
    stranded="$stranded $svc"
    n_stranded=$((n_stranded + 1))
done

if [ "$n_stranded" -gt 0 ]; then
    echo ""
    echo "$n_stranded service(s) stranded outside $GLUETUN's current namespace:$stranded"
    echo "They have no working network, and \`docker restart\` cannot fix them: it"
    echo "re-joins the old ID. Restart them through compose so they bind to the"
    echo "current $GLUETUN (docs/TROUBLESHOOTING.md, \"After a Gluetun RECREATE\"):"
    echo ""
    echo "  docker compose -f docker-compose.arr-stack.yml up -d --no-deps --force-recreate$stranded"
    exit 1
fi

if [ "$n_errors" -gt 0 ]; then
    echo ""
    echo "ERROR: $n_errors service(s) could not be checked — see above"
    exit 2
fi

echo "OK: no VPN zombies — $n_joined service(s) in $GLUETUN's namespace (${gid:0:12}), $n_skipped skipped"
exit 0
