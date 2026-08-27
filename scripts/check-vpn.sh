#!/bin/bash
set -euo pipefail
#
# Verify the VPN is actually carrying traffic — for Gluetun itself, and for
# every service that is supposed to be tunneled through it.
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. It only inspects and reports —
#     it changes nothing.
#
# WHAT CHANGED AND WHY (2026-08-15): this used to compare Gluetun's exit IP
# against the NAS's LAN IP from `hostname -I`. Those are a public address and a
# private one — a routable WAN address versus an RFC 1918 LAN address — so they
# could never be equal and
# the leak branch could never fire. It reported "OK: VPN is active" whether the
# tunnel was up, down or leaking.
#
# The comparison that means something is against the HOST's OWN EGRESS: what
# the internet sees when traffic does not go through the VPN. Sonarr is used to
# measure it because it is bridge-only by design (docs/MIGRATION-arr-off-vpn.md),
# so its egress is the host's egress.
#
# Per-service checks must assert EQUAL to Gluetun, not merely different from
# the host: a service escaping down some third route would also differ from the
# host while not being tunneled at all.
#
# WHAT CHANGED AND WHY (2026-08-27): a service whose egress could not be
# measured printed WARN, was skipped, and did not affect the exit code. So the
# run in which all four tunneled services had lost their network still ended on
# "OK: every tunneled service egresses through Gluetun", exit 0. Unmeasurable
# is now a failure. An unverified service is not a passing one.
#
# This is the shell counterpart to tests/e2e/vpn-security.spec.ts. Both
# implement the same comparison; keep them in step.
#
# Usage:
#   ./scripts/check-vpn.sh
#
# Exit codes:
#   0 = Gluetun is tunneling and no tunneled service is leaking
#   1 = a leak was detected, or the check could not run
#
# Use in cron or monitoring:
#   */5 * * * * /path/to/arr-stack/scripts/check-vpn.sh || notify "VPN leak!"

# Must match network_mode: "service:gluetun" in docker-compose.arr-stack.yml.
TUNNELED_SERVICES=(qbittorrent prowlarr sabnzbd flaresolverr)

# Container used to measure the host's non-VPN egress. Must be bridge-only.
HOST_EGRESS_PROBE=sonarr

# Images differ in which HTTP client they ship — Gluetun's Alpine base has only
# wget, LSIO images have curl — so try both in one shell invocation. The /ip
# path matters: ifconfig.me serves curl a bare IP at the root but serves wget
# (no Accept header) its HTML homepage. /ip is plain text for both.
egress_ip() {
    docker exec "$1" sh -c \
        'curl -s --max-time 5 https://ifconfig.me/ip || wget -qO- --timeout=5 https://ifconfig.me/ip' 2>/dev/null
}

echo "Measuring the host's own egress (via $HOST_EGRESS_PROBE, which is bridge-only)..."
HOST_IP=$(egress_ip "$HOST_EGRESS_PROBE") || HOST_IP=""
if [[ -z "$HOST_IP" ]]; then
    echo "ERROR: Could not determine host egress IP via $HOST_EGRESS_PROBE"
    echo "       Is it running, and is it still off the VPN?"
    exit 1
fi

echo "Checking Gluetun's exit IP..."
VPN_IP=$(egress_ip gluetun) || VPN_IP=""
if [[ -z "$VPN_IP" ]]; then
    echo "ERROR: Could not reach an IP-check service through Gluetun"
    echo "       Gluetun may be down or the VPN disconnected"
    exit 1
fi

if [[ "$VPN_IP" == "$HOST_IP" ]]; then
    echo "LEAK DETECTED: Gluetun's egress ($VPN_IP) matches the host's ($HOST_IP)"
    echo "               Gluetun is NOT routing through the VPN."
    exit 1
fi

echo "OK: Gluetun is tunneling"
echo "  host egress: $HOST_IP"
echo "  VPN egress:  $VPN_IP"
echo ""
echo "Checking tunneled services..."

leaked=0
for svc in "${TUNNELED_SERVICES[@]}"; do
    svc_ip=$(egress_ip "$svc") || svc_ip=""
    if [[ -z "$svc_ip" ]]; then
        # Not a warning to be scrolled past. A service whose egress cannot be
        # measured has not been shown to be tunneled, and calling that success
        # is the same mistake as the pre-2026-08-15 comparison this script was
        # rewritten to fix — it is just spelled `continue` instead of `==`.
        #
        # This is not hypothetical. On 2026-08-27, recreating Gluetun left all
        # four tunneled services attached to a namespace that no longer existed:
        # running, reported healthy, no network at all. Every egress probe here
        # returned empty, and this script ended on "OK: every tunneled service
        # egresses through Gluetun" and exit 0 — the one outcome that guarantees
        # nobody looks further. In cron, that silence is the whole product.
        #
        # scripts/detect-vpn-zombies.sh diagnoses this specific cause and is
        # worth running next; the job here is only to refuse to call it OK.
        echo "  FAIL: $svc — could not determine egress (container down, or attached to"
        echo "        a namespace that no longer exists — try scripts/detect-vpn-zombies.sh)"
        leaked=1
        continue
    fi
    if [[ "$svc_ip" == "$VPN_IP" ]]; then
        echo "  OK:   $svc egresses through Gluetun ($svc_ip)"
    else
        echo "  LEAK: $svc egress ($svc_ip) does NOT match Gluetun ($VPN_IP)"
        leaked=1
    fi
done

if [[ "$leaked" -eq 1 ]]; then
    echo ""
    echo "At least one tunneled service is not going through the VPN."
    exit 1
fi

echo ""
echo "OK: every tunneled service egresses through Gluetun"
