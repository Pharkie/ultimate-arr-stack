#!/bin/bash
# Check Uptime Kuma monitors match expected services
# Returns warnings only - does not block commits

# Source common functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

check_uptime_monitors() {
    # Expected monitors (services that should be monitored)
    local expected=(
        "Bazarr"
        "duc"
        "FlareSolverr"
        "Jellyfin"
        "Jellyseerr"
        "Pi-hole"
        "Prowlarr"
        "qBittorrent"
        "qbit-scheduler"
        "Radarr"
        "Sonarr"
        "Traefik"
        "WireGuard"
    )

    # Skip if NAS config not available
    if ! has_nas_config; then
        echo "    SKIP: No NAS host in .claude/config.local.md"
        return 0
    fi

    # Check if NAS is reachable
    if ! is_nas_reachable; then
        echo "    SKIP: NAS not reachable"
        return 0
    fi

    # Check if SSH port is open
    if ! is_ssh_available; then
        echo "    SKIP: SSH port not reachable"
        return 0
    fi

    # Get actual monitors from Uptime Kuma (|| true prevents set -e from exiting on SSH failure)
    local actual
    actual=$(ssh_to_nas "docker exec uptime-kuma sqlite3 /app/data/kuma.db \"SELECT name FROM monitor ORDER BY name;\"") || true

    if [[ -z "$actual" ]]; then
        echo "    SKIP: Could not query Uptime Kuma (docker access failed)"
        return 0
    fi

    local warnings=0

    # Check for missing monitors
    for service in "${expected[@]}"; do
        local service_lower=$(echo "$service" | tr '[:upper:]' '[:lower:]')
        local found=0
        while IFS= read -r monitor; do
            local monitor_lower=$(echo "$monitor" | tr '[:upper:]' '[:lower:]')
            if [[ "$monitor_lower" == "$service_lower" ]]; then
                found=1
                break
            fi
        done <<< "$actual"
        if [[ $found -eq 0 ]]; then
            echo "    WARNING: Missing monitor for '$service'"
            ((warnings++))
        fi
    done

    # Check for unexpected monitors (excluding known extras like Home Assistant, Reolink)
    local known_extras=("Home Assistant" "Reolink NVR")
    while IFS= read -r monitor; do
        [[ -z "$monitor" ]] && continue
        local found=0
        local monitor_lower=$(echo "$monitor" | tr '[:upper:]' '[:lower:]')
        for service in "${expected[@]}" "${known_extras[@]}"; do
            local service_lower=$(echo "$service" | tr '[:upper:]' '[:lower:]')
            if [[ "$monitor_lower" == "$service_lower" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            echo "    WARNING: Unknown monitor '$monitor' (removed service?)"
            ((warnings++))
        fi
    done <<< "$actual"

    if [[ $warnings -eq 0 ]]; then
        echo "    OK: Monitors match expected services"
    fi

    return 0
}
