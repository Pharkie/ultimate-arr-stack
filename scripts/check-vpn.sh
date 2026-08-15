#!/bin/bash
set -euo pipefail
#
# Verify VPN is working — confirms Gluetun's exit IP differs from NAS IP,
# and that every VPN-tunneled dependent's egress IP matches Gluetun's (not
# leaking via a fallback route). This is the bash/cron-friendly counterpart
# to tests/e2e/vpn-security.spec.ts's egress-IP checks — both implement the
# same comparison and should be kept in sync.
#
# Usage:
#   ./scripts/check-vpn.sh
#
# Exit codes:
#   0 = VPN is active and no tunneled dependent is leaking
#   1 = VPN leak detected (an IP matched the NAS's, or Gluetun unreachable)
#
# Use in cron or monitoring to catch VPN failures:
#   */5 * * * * /path/to/arr-stack/scripts/check-vpn.sh || notify "VPN leak!"

TUNNELED_SERVICES=(qbittorrent prowlarr sabnzbd flaresolverr)

egress_ip() {
    docker exec "$1" sh -c 'curl -s --max-time 5 https://ifconfig.me || wget -qO- --timeout=5 https://ifconfig.me' 2>/dev/null
}

# Detect NAS LAN IP
NAS_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -z "$NAS_IP" ]]; then
    echo "ERROR: Could not detect NAS IP"
    exit 1
fi

# Get Gluetun's exit IP
echo "Checking VPN exit IP..."
VPN_IP=$(egress_ip gluetun) || {
    echo "ERROR: Could not reach an IP-check service through Gluetun"
    echo "       Gluetun may be down or VPN disconnected"
    exit 1
}

if [[ -z "$VPN_IP" ]]; then
    echo "ERROR: Empty response from IP check"
    exit 1
fi

if [[ "$VPN_IP" == "$NAS_IP" ]]; then
    echo "LEAK DETECTED: VPN IP ($VPN_IP) matches NAS IP ($NAS_IP)"
    echo "               Gluetun is not routing through VPN!"
    exit 1
fi

echo "OK: VPN is active"
echo "  NAS IP: $NAS_IP"
echo "  VPN IP: $VPN_IP"

# Check each VPN-tunneled dependent's egress IP matches Gluetun's exactly —
# not just "differs from NAS IP", since a dependent leaking via some other
# non-VPN route would also differ from NAS_IP without actually being tunneled.
echo ""
echo "Checking tunneled services..."
leaked=0
for svc in "${TUNNELED_SERVICES[@]}"; do
    svc_ip=$(egress_ip "$svc") || svc_ip=""
    if [[ -z "$svc_ip" ]]; then
        echo "  WARN: $svc — could not determine egress IP (container down or unreachable)"
        continue
    fi
    if [[ "$svc_ip" == "$VPN_IP" ]]; then
        echo "  OK: $svc egress IP matches Gluetun ($svc_ip)"
    else
        echo "  LEAK DETECTED: $svc egress IP ($svc_ip) does NOT match Gluetun ($VPN_IP)"
        leaked=1
    fi
done

if [[ "$leaked" -eq 1 ]]; then
    exit 1
fi
