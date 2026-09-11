#!/bin/bash
# Hardcoded domain/hostname detection
# Scans ALL tracked files in repo (not just staged) for security

# Source common functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

check_hardcoded_domain() {
    local warnings=0

    # Get files to scan
    local files_to_check
    files_to_check=$(get_files_to_scan)

    if [[ -z "$files_to_check" ]]; then
        return 0
    fi

    # Get domain and hostname to check for
    local domain nas_hostname
    domain=$(get_domain)
    nas_hostname=$(get_nas_hostname)

    # Check for domain if configured
    if has_custom_domain; then
        local files_with_domain=""
        for file in $files_to_check; do
            is_binary_file "$file" && continue

            local content
            content=$(read_file_content "$file") || continue

            # Check for domain (case insensitive)
            if echo "$content" | grep -qi "$domain" 2>/dev/null; then
                local count
                # The fallback is a SEPARATE command, never a `||` inside the
                # substitution. `grep -c` prints 0 and then exits 1 when nothing
                # matches, so `$(... || echo 0)` does not replace the value, it
                # appends to it -- the report line would carry "0" twice, on two
                # stacked lines, and read "(0" newline "0 occurrences)".
                #
                # It cannot fire from here today, because the `-qi` guard above
                # already matched the same pattern against the same content, so
                # the count's grep always succeeds first. That coupling is the
                # only reason the old form went unnoticed, and it is not
                # something a later edit can be trusted to keep.
                count=$(echo "$content" | grep -ci "$domain" 2>/dev/null) || count=0
                files_with_domain+="      - $file ($count occurrences)"$'\n'
                warnings=$((warnings + 1))
            fi
        done

        if [[ -n "$files_with_domain" ]]; then
            echo "    WARNING: Your domain '$domain' is hardcoded in tracked files:"
            echo "$files_with_domain"
            echo "    Note: Some files (like Traefik dynamic configs) can't use \${DOMAIN}"
            echo "          Review to ensure this is intentional."
        fi
    else
        local repo_root
        repo_root=$(get_repo_root)
        if [[ ! -f "$repo_root/.env" && ! -f "$repo_root/.env.nas.backup" ]]; then
            echo "    SKIP: No .env or .env.nas.backup (can't determine domain)"
        else
            echo "    SKIP: No custom domain configured"
        fi
    fi

    # Check for NAS hostname (BLOCKS - this should never be committed)
    if [[ -n "$nas_hostname" ]]; then
        # No counter here: the report is built in files_with_hostname and the
        # emptiness of that string is what decides. A `hostname_errors` tally
        # used to sit alongside it, written and never once read -- its only
        # observable effect was that `((hostname_errors++))` returned 1 on the
        # first hit and killed the whole hook under `set -e`, mid-loop, before
        # this report could be printed.
        local files_with_hostname=""
        for file in $files_to_check; do
            is_binary_file "$file" && continue

            local content
            content=$(read_file_content "$file") || continue

            # Check for hostname (case insensitive)
            if echo "$content" | grep -qi "$nas_hostname" 2>/dev/null; then
                local count
                # Same shape as the domain half above: the fallback has to be a
                # separate command, because `grep -c` prints 0 AND exits 1, so a
                # `||` inside the substitution appends a second 0 instead of
                # replacing the first.
                count=$(echo "$content" | grep -ci "$nas_hostname" 2>/dev/null) || count=0
                files_with_hostname+="      - $file ($count occurrences)"$'\n'
            fi
        done

        if [[ -n "$files_with_hostname" ]]; then
            echo "    ERROR: NAS hostname '$nas_hostname' found in tracked files:"
            echo "$files_with_hostname"
            echo "    This is private info and should not be committed."
            return 1
        fi
    fi

    # Output OK if we checked something and found no issues
    if [[ $warnings -eq 0 ]] && has_custom_domain; then
        echo "    OK: No hardcoded domain/hostname found"
    fi

    return 0
}
