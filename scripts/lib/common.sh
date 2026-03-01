#!/bin/bash
# Shared functions for pre-commit checks
# Source this at the top of each check script

# Get repository root (cached for performance)
_REPO_ROOT=""
get_repo_root() {
    if [[ -z "$_REPO_ROOT" ]]; then
        _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || _REPO_ROOT="."
    fi
    echo "$_REPO_ROOT"
}

# Get all tracked files in the repo (for security scanning)
# Returns: newline-separated list of file paths
get_all_tracked_files() {
    git ls-files 2>/dev/null | grep -v '^\.env$'
}

# Get staged files (for change-specific checks)
# Returns: newline-separated list of file paths
get_staged_files() {
    git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -v '^\.env$'
}

# Combine staged and tracked files, deduplicated
# Returns: newline-separated list of unique file paths
get_files_to_scan() {
    local staged tracked
    staged=$(get_staged_files)
    tracked=$(get_all_tracked_files)
    echo -e "$staged\n$tracked" | sort -u | grep -v '^$'
}

# Read file content safely
# Args: $1 = file path
# Returns: file content or empty on error
read_file_content() {
    local file="$1"
    cat "$file" 2>/dev/null
}

# Check if file is binary (should skip scanning)
# Args: $1 = file path
# Returns: 0 if binary (skip), 1 if text (scan)
is_binary_file() {
    local file="$1"
    case "$file" in
        *.png|*.jpg|*.jpeg|*.gif|*.ico|*.woff|*.woff2|*.ttf|*.eot|*.svg) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================
# NAS Configuration (from .claude/config.local.md)
# ============================================

_NAS_CONFIG_LOADED=false
_NAS_HOST=""
_NAS_USER=""
_NAS_HOSTNAME=""  # Just the hostname part without .local

# Load NAS config from .claude/config.local.md
# Call this once before using get_nas_* functions
load_nas_config() {
    if $_NAS_CONFIG_LOADED; then
        return 0
    fi

    local repo_root config_local
    repo_root=$(get_repo_root)
    config_local="$repo_root/.claude/config.local.md"

    if [[ -f "$config_local" ]]; then
        # Extract hostname.local format
        _NAS_HOST=$(grep -oE '[a-zA-Z0-9_-]+\.local' "$config_local" 2>/dev/null | head -1)
        # Extract just the hostname (without .local)
        _NAS_HOSTNAME=$(echo "$_NAS_HOST" | sed 's/\.local$//')
        # Extract username from "SSH: user@host" or table "SSH User | `user`" pattern
        _NAS_USER=$(grep -oE 'SSH:\s*[a-zA-Z0-9_-]+@' "$config_local" 2>/dev/null | sed 's/SSH:\s*//' | sed 's/@$//' | head -1)
        # Fallback: try table format "SSH User | `username`"
        if [[ -z "$_NAS_USER" ]]; then
            _NAS_USER=$(grep -i 'SSH User' "$config_local" 2>/dev/null | grep -oE '`[a-zA-Z0-9_-]+`' | tr -d '`' | head -1)
        fi
    fi

    # Default user if not found
    [[ -z "$_NAS_USER" ]] && _NAS_USER="admin"

    _NAS_CONFIG_LOADED=true
}

# Get NAS host (e.g., "mynas.local")
get_nas_host() {
    load_nas_config
    echo "$_NAS_HOST"
}

# Get NAS hostname without .local (e.g., "mynas")
get_nas_hostname() {
    load_nas_config
    echo "$_NAS_HOSTNAME"
}

# Get NAS SSH user
get_nas_user() {
    load_nas_config
    echo "$_NAS_USER"
}

# Check if NAS config is available
has_nas_config() {
    load_nas_config
    [[ -n "$_NAS_HOST" ]]
}

# Get NAS IP from .env.nas.backup (for DNS queries to Pi-hole)
get_nas_ip() {
    local repo_root env_backup
    repo_root=$(get_repo_root)
    env_backup="$repo_root/.env.nas.backup"

    if [[ -f "$env_backup" ]]; then
        grep -E '^NAS_IP=' "$env_backup" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'"
    fi
}

# ============================================
# Domain Configuration (from .env or .env.nas.backup)
# ============================================

_DOMAIN_LOADED=false
_DOMAIN=""

# Load domain from .env or .env.nas.backup
load_domain_config() {
    if $_DOMAIN_LOADED; then
        return 0
    fi

    local repo_root env_file env_backup secrets_file
    repo_root=$(get_repo_root)
    env_file="$repo_root/.env"
    env_backup="$repo_root/.env.nas.backup"

    # Prefer .env, fallback to .env.nas.backup
    if [[ -f "$env_file" ]]; then
        secrets_file="$env_file"
    elif [[ -f "$env_backup" ]]; then
        secrets_file="$env_backup"
    fi

    if [[ -n "$secrets_file" ]]; then
        _DOMAIN=$(grep -E '^DOMAIN=' "$secrets_file" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
    fi

    _DOMAIN_LOADED=true
}

# Get configured domain
get_domain() {
    load_domain_config
    echo "$_DOMAIN"
}

# Check if custom domain is configured (not placeholder)
has_custom_domain() {
    load_domain_config
    [[ -n "$_DOMAIN" && "$_DOMAIN" != "yourdomain.com" ]]
}

# ============================================
# SSH Connection Helpers
# ============================================

# Standard SSH options for non-interactive, fast-fail connections
SSH_OPTS="-n -o StrictHostKeyChecking=accept-new -o ConnectTimeout=2 -o ConnectionAttempts=1 -o BatchMode=yes -o LogLevel=ERROR"

# Check if NAS is reachable (quick ping)
# Returns: 0 if reachable, 1 if not
is_nas_reachable() {
    local nas_host
    nas_host=$(get_nas_host)
    [[ -n "$nas_host" ]] && ping -c 1 -W 1 "$nas_host" &>/dev/null
}

# Check if SSH port is open on NAS (with 2-second timeout)
# Returns: 0 if open, 1 if not
is_ssh_available() {
    local nas_host
    nas_host=$(get_nas_host)
    [[ -z "$nas_host" ]] && return 1
    # Use timeout to prevent hanging on slow/blocked connections
    timeout 2 bash -c "exec 3<>/dev/tcp/$nas_host/22" 2>/dev/null
}

# Run SSH command on NAS (with timeout to prevent hanging)
# Args: $1 = command to run
# Returns: command output, or empty on failure
ssh_to_nas() {
    local cmd="$1"
    local nas_host nas_user
    nas_host=$(get_nas_host)
    nas_user=$(get_nas_user)

    if [[ -n "$NAS_SSH_PASS" ]] && command -v sshpass &>/dev/null; then
        timeout 10 sshpass -p "$NAS_SSH_PASS" ssh $SSH_OPTS "$nas_user@$nas_host" "$cmd" 2>/dev/null
    else
        # Use BatchMode for non-interactive, but allow SSH agent keys
        timeout 10 ssh $SSH_OPTS "$nas_user@$nas_host" "$cmd" 2>/dev/null
    fi
}
