#!/bin/bash
# Check for .lan names that Pi-hole's local DNS defines twice: twice in
# 02-local-dns.conf, or in both it and pihole.toml.
# Run on NAS after making DNS changes to catch conflicts.
# The parsing is shared with pre-commit check 8: scripts/lib/check-dns-duplicates.sh.
#
# DNSMASQ_CONF overrides the dnsmasq file to check (default: the stack's own).

set -e

# Colors
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(dirname "$SCRIPT_DIR")"

DNSMASQ_CONF="${DNSMASQ_CONF:-$STACK_DIR/pihole/dnsmasq.d/02-local-dns.conf}"

source "$SCRIPT_DIR/lib/check-dns-duplicates.sh"

echo "Checking for duplicate .lan domains..."
echo

if [[ ! -f "$DNSMASQ_CONF" ]]; then
    echo "Warning: $DNSMASQ_CONF not found"
    exit 0
fi

PIHOLE_TOML="$(mktemp)"
trap 'rm -f "$PIHOLE_TOML"' EXIT
pihole_toml="$PIHOLE_TOML"
if ! docker exec pihole cat /etc/pihole/pihole.toml > "$PIHOLE_TOML"; then
    echo "Warning: Could not read pihole.toml from container; checking 02-local-dns.conf alone"
    pihole_toml=""
fi

if report_dns_duplicates "$DNSMASQ_CONF" "$pihole_toml"; then
    exit 0
fi

echo
echo -e "${RED}CONFLICT: see the names above${NC}"
echo "Fix: Keep one definition per name. Stack domains belong in 02-local-dns.conf;"
echo "     remove copies from pihole.toml via the web UI (Local DNS Records)"
exit 1
