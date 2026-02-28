#!/bin/bash
set -euo pipefail
#
# Verify VPN is working — confirms Gluetun's exit IP differs from NAS IP.
#
# Usage:
#   ./scripts/check-vpn.sh
#
# Exit codes:
#   0 = VPN is active (IPs differ)
#   1 = VPN leak detected (IPs match) or check failed
#
# Use in cron or monitoring to catch VPN failures:
#   */5 * * * * /volume1/docker/arr-stack/scripts/check-vpn.sh || notify "VPN leak!"

# Detect NAS LAN IP
NAS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$NAS_IP" ]]; then
    echo "ERROR: Could not detect NAS IP"
    exit 1
fi

# Get Gluetun's exit IP
echo "Checking VPN exit IP..."
VPN_IP=$(docker exec gluetun wget -qO- https://ipinfo.io/ip 2>/dev/null) || {
    echo "ERROR: Could not reach ipinfo.io through Gluetun"
    echo "       Gluetun may be down or VPN disconnected"
    exit 1
}

if [[ -z "$VPN_IP" ]]; then
    echo "ERROR: Empty response from IP check"
    exit 1
fi

# Compare
if [[ "$VPN_IP" == "$NAS_IP" ]]; then
    echo "LEAK DETECTED: VPN IP ($VPN_IP) matches NAS IP ($NAS_IP)"
    echo "               Gluetun is not routing through VPN!"
    exit 1
fi

echo "OK: VPN is active"
echo "  NAS IP: $NAS_IP"
echo "  VPN IP: $VPN_IP"
