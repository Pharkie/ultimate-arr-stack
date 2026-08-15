#!/bin/bash
# Check for and optionally clean orphaned Docker networks
#
# Run this before deployment if you've had failed attempts.
# Usage: ./scripts/check-network.sh

set -euo pipefail

# Color output (disabled if not interactive)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

echo ""
echo "Checking Docker networks..."
echo ""

# Check if arr-core exists
if docker network inspect arr-core &>/dev/null; then
    # Check if it's being used
    CONTAINERS=$(docker network inspect arr-core -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)
    if [[ -z "$CONTAINERS" ]]; then
        echo -e "${YELLOW}WARNING${NC}: arr-core network exists but has no containers attached."
        echo "         This may be orphaned from a previous deployment."
        echo ""
        if [[ -t 0 ]]; then
            read -p "Remove it? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                docker network rm arr-core
                echo -e "${GREEN}OK${NC}: Removed arr-core"
            else
                echo "Skipped. You can remove it manually with: docker network rm arr-core"
            fi
        else
            echo "Run interactively to remove, or use: docker network rm arr-core"
        fi
    else
        echo -e "${GREEN}OK${NC}: arr-core exists with containers: $CONTAINERS"
    fi
else
    echo -e "${GREEN}OK${NC}: arr-core doesn't exist (will be created on deploy)"
fi

# arr-stack was the network's name before the arr-core rename (network
# segmentation phase). Docker doesn't auto-delete it - flag it as a leftover
# so it doesn't linger unnoticed once every container has moved to arr-core.
if docker network inspect arr-stack &>/dev/null; then
    LEFTOVER_CONTAINERS=$(docker network inspect arr-stack -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)
    if [[ -z "$LEFTOVER_CONTAINERS" ]]; then
        echo -e "${YELLOW}NOTE${NC}: old 'arr-stack' network still exists (renamed to arr-core) and is unused."
        echo "      Safe to remove once the arr-core migration is confirmed working: docker network rm arr-stack"
    else
        echo -e "${YELLOW}WARNING${NC}: old 'arr-stack' network still has containers attached: $LEFTOVER_CONTAINERS"
        echo "         These haven't been recreated onto arr-core yet."
    fi
fi

# Check for other potentially orphaned networks
echo ""
echo "All Docker networks:"
docker network ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}"

echo ""
echo "Tip: To clean up all unused networks: docker network prune"
echo ""
