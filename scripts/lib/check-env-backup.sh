#!/bin/bash
# Check if local .env.nas.backup matches NAS .env
# Warns if out of sync (non-blocking)

# Source common functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

check_env_backup() {
    local repo_root backup_file
    repo_root=$(get_repo_root)
    backup_file="$repo_root/.env.nas.backup"

    # Skip if no backup file
    if [[ ! -f "$backup_file" ]]; then
        echo "    SKIP: No .env.nas.backup file"
        return 0
    fi

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

    # Get NAS .env via SSH (|| true prevents set -e from exiting on SSH failure)
    local nas_env
    nas_env=$(ssh_to_nas "cat /volume1/docker/arr-stack/.env") || true

    # Skip if SSH failed
    if [[ -z "$nas_env" ]]; then
        echo "    SKIP: Could not fetch NAS .env (SSH auth failed)"
        return 0
    fi

    # Compare
    local local_env nas_host nas_user
    local_env=$(cat "$backup_file")
    nas_host=$(get_nas_host)
    nas_user=$(get_nas_user)

    if [[ "$nas_env" != "$local_env" ]]; then
        echo "    WARNING: .env.nas.backup differs from NAS .env"
        echo "             Run: scp $nas_user@$nas_host:/volume1/docker/arr-stack/.env .env.nas.backup"
        return 0  # Warning only, don't block
    fi

    echo "    OK: .env.nas.backup matches NAS"
    return 0
}
