#!/bin/bash
# Secret detection for pre-commit hook
# Scans ALL tracked files in repo (not just staged) for security

# Source common functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

check_secrets() {
    local errors=0

    # Get files to scan
    local files_to_check
    files_to_check=$(get_files_to_scan)

    if [[ -z "$files_to_check" ]]; then
        return 0
    fi

    for file in $files_to_check; do
        # Skip binary files, .env, and the check scripts themselves (contain example patterns)
        case "$file" in
            *.png|*.jpg|*.gif|*.ico|*.woff|*.woff2|*.ttf|*.eot) continue ;;
            .env) continue ;;  # .env should be gitignored anyway
            scripts/lib/check-*.sh) continue ;;  # These contain example patterns
            scripts/lib/common.sh) continue ;;
            scripts/configure-apps.sh) continue ;;  # Contains $PASSWORD variable refs, not secrets
            tests/fixtures/*) continue ;;  # Test fixtures contain intentional fake secrets
            *.md) continue ;;  # Documentation may contain examples
        esac

        # Get file content
        local content
        content=$(read_file_content "$file") || continue

        # Pattern 1: WireGuard private key (44-char base64 ending in =)
        if echo "$content" | grep -qE '(WIREGUARD_PRIVATE_KEY|PRIVATE_KEY)=[A-Za-z0-9+/]{40,}=' 2>/dev/null; then
            local match
            match=$(echo "$content" | grep -oE '(WIREGUARD_PRIVATE_KEY|PRIVATE_KEY)=[A-Za-z0-9+/]{40,}=')
            if ! echo "$match" | grep -qiE '(your|here|example|placeholder|xxx)'; then
                echo "    ERROR: Possible WireGuard private key in $file"
                ((errors++))
            fi
        fi

        # Pattern 2: Cloudflare API token (alphanumeric, 35-45 chars)
        if echo "$content" | grep -qE 'CF_DNS_API_TOKEN=[A-Za-z0-9_-]{35,45}$' 2>/dev/null; then
            local match
            match=$(echo "$content" | grep -oE 'CF_DNS_API_TOKEN=[A-Za-z0-9_-]{35,45}$')
            if ! echo "$match" | grep -qiE '(your|here|example|placeholder|xxx|token)'; then
                echo "    ERROR: Possible Cloudflare API token in $file"
                ((errors++))
            fi
        fi

        # Pattern 3: Cloudflare tunnel token (JWT format)
        if echo "$content" | grep -qE 'TUNNEL_TOKEN=eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' 2>/dev/null; then
            echo "    ERROR: Possible Cloudflare tunnel token in $file"
            ((errors++))
        fi

        # Pattern 4: Real bcrypt hashes (60 chars after $2a$XX$ or $2y$XX$)
        if echo "$content" | grep -qE '\$2[aby]\$[0-9]{2}\$[A-Za-z0-9./]{50,}' 2>/dev/null; then
            local match
            match=$(echo "$content" | grep -oE '\$2[aby]\$[0-9]{2}\$[A-Za-z0-9./]{50,}')
            if ! echo "$match" | grep -qiE '(your|here|example|placeholder)'; then
                echo "    ERROR: Possible bcrypt password hash in $file"
                ((errors++))
            fi
        fi

        # Pattern 5: PEM private key blocks
        if echo "$content" | grep -qE '^-----BEGIN (RSA |EC |OPENSSH |DSA |)PRIVATE KEY-----' 2>/dev/null; then
            echo "    ERROR: Private key block detected in $file"
            ((errors++))
        fi

        # Pattern 6: Generic high-entropy secrets (long base64 in value position)
        if echo "$content" | grep -qE '(PASSWORD|SECRET|API_KEY)=[A-Za-z0-9+/=]{30,}$' 2>/dev/null; then
            local match
            match=$(echo "$content" | grep -oE '(PASSWORD|SECRET|API_KEY)=[A-Za-z0-9+/=]{30,}$')
            if ! echo "$match" | grep -qiE '(your|here|example|placeholder|xxx)'; then
                echo "    WARNING: Possible secret value in $file"
                ((errors++))
            fi
        fi

        # Pattern 7: OpenVPN credentials (non-placeholder values)
        if echo "$content" | grep -qE 'OPENVPN_(USER|PASSWORD)=.{30,}' 2>/dev/null; then
            local match
            match=$(echo "$content" | grep -oE 'OPENVPN_(USER|PASSWORD)=.{30,}')
            if ! echo "$match" | grep -qiE '(your|here|example|placeholder|xxx)'; then
                echo "    ERROR: Possible OpenVPN credential in $file"
                ((errors++))
            fi
        fi

        # Pattern 8: Bearer/Auth tokens in non-example files
        if echo "$content" | grep -qE '(Authorization|Bearer|TOKEN):\s*(Bearer\s+)?[A-Za-z0-9._-]{20,}' 2>/dev/null; then
            local match
            match=$(echo "$content" | grep -oE '(Authorization|Bearer|TOKEN):\s*(Bearer\s+)?[A-Za-z0-9._-]{20,}')
            if ! echo "$match" | grep -qiE '(your|here|example|placeholder|xxx)'; then
                echo "    ERROR: Possible auth token in $file"
                ((errors++))
            fi
        fi

        # Pattern 9: SSH/generic passwords (15+ chars, non-placeholder)
        if echo "$content" | grep -qE '(SSH_PASS|_PASSWORD|_PASSWD)=[^[:space:]]{15,}' 2>/dev/null; then
            local match
            match=$(echo "$content" | grep -oE '(SSH_PASS|_PASSWORD|_PASSWD)=[^[:space:]]{15,}')
            if ! echo "$match" | grep -qiE '(your|here|example|placeholder|xxx)'; then
                echo "    WARNING: Possible password in $file"
                ((errors++))
            fi
        fi
    done

    return $errors
}
