#!/bin/bash
# Check that .lan domains and external domains are accessible
# Returns warnings only - does not block commits

# Source common functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

check_domains() {
    local warnings=0

    # Skip if NAS config not available
    if ! has_nas_config; then
        echo "    SKIP: No NAS config in .claude/config.local.md"
        return 0
    fi

    # Skip if dig is not available
    if ! command -v dig &>/dev/null; then
        echo "    SKIP: dig not installed"
        return 0
    fi

    # Get Pi-hole IP (NAS IP)
    local pihole_ip
    pihole_ip=$(get_nas_ip)
    if [[ -z "$pihole_ip" ]]; then
        echo "    SKIP: Could not determine NAS IP"
        return 0
    fi

    # Get domain from .env or .env.nas.backup
    local domain
    domain=$(get_domain)

    # .lan domains to check (via Pi-hole DNS)
    local lan_domains=(
        "jellyfin.lan"
        "seerr.lan"
        "jellyseerr.lan"
        "sonarr.lan"
        "radarr.lan"
        "prowlarr.lan"
        "bazarr.lan"
        "qbit.lan"
        "sabnzbd.lan"
        "traefik.lan"
        "pihole.lan"
        "uptime.lan"
        "duc.lan"
        "beszel.lan"
    )

    # Check .lan domains (parallel for speed)
    echo "    Checking .lan domains (via Pi-hole at $pihole_ip)..."
    local lan_ok=0
    local lan_fail=0
    local tmpdir
    tmpdir=$(mktemp -d)

    for domain_name in "${lan_domains[@]}"; do
        (
            result=$(dig +short +time=2 +tries=1 "$domain_name" @"$pihole_ip" 2>/dev/null)
            if [[ -n "$result" ]]; then
                touch "$tmpdir/${domain_name}.ok"
            else
                touch "$tmpdir/${domain_name}.fail"
            fi
        ) &
    done
    wait

    for domain_name in "${lan_domains[@]}"; do
        if [[ -f "$tmpdir/${domain_name}.ok" ]]; then
            lan_ok=$((lan_ok + 1))
        else
            echo "      FAIL: $domain_name does not resolve"
            lan_fail=$((lan_fail + 1))
            warnings=$((warnings + 1))
        fi
    done
    rm -rf "$tmpdir"

    if [[ $lan_fail -eq 0 ]]; then
        echo "      OK: All ${lan_ok} .lan domains resolve"
    fi

    # External domains to check (only ones exposed via Cloudflare Tunnel)
    if [[ -n "$domain" ]]; then
        local external_domains=(
            "jellyfin.$domain"
            "seerr.$domain"
        )

        echo "    Checking external domains..."
        local ext_ok=0
        local ext_fail=0
        local ext_tmpdir
        ext_tmpdir=$(mktemp -d)

        for ext_domain in "${external_domains[@]}"; do
            (
                result=$(dig +short +time=2 +tries=1 "$ext_domain" 2>/dev/null | head -1)
                if [[ -n "$result" ]]; then
                    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://$ext_domain" 2>/dev/null)
                    if [[ "$http_code" =~ ^(200|301|302|303|307|308|401|403)$ ]]; then
                        touch "$ext_tmpdir/${ext_domain}.ok"
                    else
                        echo "$http_code" > "$ext_tmpdir/${ext_domain}.fail"
                    fi
                else
                    touch "$ext_tmpdir/${ext_domain}.nodns"
                fi
            ) &
        done
        wait

        for ext_domain in "${external_domains[@]}"; do
            if [[ -f "$ext_tmpdir/${ext_domain}.ok" ]]; then
                ext_ok=$((ext_ok + 1))
            elif [[ -f "$ext_tmpdir/${ext_domain}.fail" ]]; then
                local code
                code=$(cat "$ext_tmpdir/${ext_domain}.fail")
                echo "      FAIL: $ext_domain - HTTP $code"
                ext_fail=$((ext_fail + 1))
                warnings=$((warnings + 1))
            else
                echo "      FAIL: $ext_domain does not resolve"
                ext_fail=$((ext_fail + 1))
                warnings=$((warnings + 1))
            fi
        done
        rm -rf "$ext_tmpdir"

        if [[ $ext_fail -eq 0 ]]; then
            echo "      OK: All ${ext_ok} external domains accessible"
        fi
    else
        echo "    SKIP: No domain found in config.local.md"
    fi

    if [[ $warnings -eq 0 ]]; then
        echo "    OK: All domains accessible"
    fi

    return 0
}
