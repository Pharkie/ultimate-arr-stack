#!/usr/bin/env bats
# Port and IP conflict tests against real compose files

setup() {
    load helpers/setup
}

@test "no duplicate ports across compose files" {
    local all_ports=""
    for f in $(get_compose_files); do
        local ports
        ports=$(grep -E '^\s+-\s*"?[0-9]+:[0-9]+"?\s*$' "$f" 2>/dev/null | \
            sed -E 's/^[[:space:]]*-[[:space:]]*"?([0-9]+):.*/\1/')
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            all_ports+="$p"$'\n'
        done <<< "$ports"
    done
    local dup_ports
    dup_ports=$(echo "$all_ports" | sort | uniq -d | grep -v '^$') || true
    if [[ -n "$dup_ports" ]]; then
        fail "Duplicate ports found across compose files: $dup_ports"
    fi
}

@test "no duplicate IPs across compose files" {
    local all_ips=""
    for f in $(get_compose_files); do
        local ips
        ips=$(grep -oE 'ipv4_address:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$f" 2>/dev/null | \
            sed -E 's/ipv4_address:[[:space:]]*//')
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            all_ips+="$ip"$'\n'
        done <<< "$ips"
    done
    local dup_ips
    dup_ips=$(echo "$all_ips" | sort | uniq -d | grep -v '^$') || true
    if [[ -n "$dup_ips" ]]; then
        fail "Duplicate IPs found across compose files: $dup_ips"
    fi
}

@test "all static IPs within 172.20.0.0/24, 172.22.0.0/24, or 10.8.1.0/24 range" {
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        [[ "$ip" == *'${'* ]] && continue
        if [[ "$ip" =~ ^172\.20\.0\.[0-9]+$ ]] || [[ "$ip" =~ ^172\.22\.0\.[0-9]+$ ]] || [[ "$ip" =~ ^10\.8\.1\.[0-9]+$ ]]; then
            continue
        fi
        fail "Static IP $ip is outside expected ranges (172.20.0.0/24, 172.22.0.0/24, or 10.8.1.0/24)"
    done < <(get_all_ips)
}
