#!/bin/bash
# Check for broken internal links in markdown documentation
# Returns errors for broken file references and anchor links

# Source common functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Convert a markdown heading to its GitHub anchor ID
# e.g., "## Step 4: Configure Each App" → "step-4-configure-each-app"
_heading_to_anchor() {
    local heading="$1"
    echo "$heading" \
        | sed 's/^#* *//' \
        | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9 _-]//g' \
        | sed 's/ /-/g'
}

# Extract all anchors (heading IDs) from a markdown file
# Args: $1 = file path
# Returns: newline-separated list of anchor IDs
_get_file_anchors() {
    local file="$1"
    grep -E '^#{1,6} ' "$file" 2>/dev/null | while IFS= read -r line; do
        _heading_to_anchor "$line"
    done
}

check_doc_links() {
    local repo_root errors
    repo_root=$(get_repo_root)
    errors=0

    # Find all markdown files tracked by git
    local md_files
    md_files=$(git ls-files '*.md' 2>/dev/null | grep -v '^node_modules/')

    if [[ -z "$md_files" ]]; then
        echo "    SKIP: No markdown files found"
        return 0
    fi

    while IFS= read -r md_file; do
        [[ -z "$md_file" ]] && continue

        local file_dir
        file_dir=$(dirname "$md_file")

        # Extract all markdown link targets with line numbers
        # grep for ](something) patterns, output line numbers
        # Skip lines inside code blocks by checking for ``` context
        local in_code_block=false
        local line_num=0
        while IFS= read -r line; do
            ((line_num++))

            # Track fenced code blocks
            if [[ "$line" == '```'* ]]; then
                if $in_code_block; then
                    in_code_block=false
                else
                    in_code_block=true
                fi
                continue
            fi
            $in_code_block && continue

            # Extract link targets using grep -o and process each
            local targets
            targets=$(echo "$line" | grep -o ']([^)]*)' 2>/dev/null | sed 's/^](//' | sed 's/)$//')
            [[ -z "$targets" ]] && continue

            while IFS= read -r target; do
                [[ -z "$target" ]] && continue

                # Skip external links
                case "$target" in
                    http://*|https://*|mailto:*) continue ;;
                esac

                # Skip image references
                case "$target" in
                    *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.webp) continue ;;
                esac

                # Split target into file path and anchor
                local target_file="" target_anchor=""
                if [[ "$target" == *"#"* ]]; then
                    target_file="${target%%#*}"
                    target_anchor="${target#*#}"
                else
                    target_file="$target"
                fi

                # Skip empty targets
                [[ -z "$target_file" && -z "$target_anchor" ]] && continue

                # Only check .md file links (skip .sh, .yml, .env, etc.)
                if [[ -n "$target_file" ]]; then
                    case "$target_file" in
                        *.md) ;; # Check these
                        *) continue ;; # Skip non-markdown
                    esac
                fi

                # Determine the full path to check
                local check_file
                if [[ -z "$target_file" ]]; then
                    # Anchor-only link (#section) — check in current file
                    check_file="$md_file"
                else
                    # Resolve relative path from the file's directory
                    check_file="$file_dir/$target_file"
                    # Normalize: remove ./ segments and resolve ../
                    # Use Python for portable path normalization (available on macOS and Linux)
                    check_file=$(python3 -c "import os.path; print(os.path.normpath('$check_file'))" 2>/dev/null || echo "$check_file")
                fi

                # Check if target file exists
                if [[ -n "$target_file" ]]; then
                    if [[ ! -f "$repo_root/$check_file" ]]; then
                        echo "    ERROR: $md_file:$line_num — broken link to '$target_file' (file not found)"
                        ((errors++))
                        continue
                    fi
                fi

                # Check if anchor exists in target file
                if [[ -n "$target_anchor" ]]; then
                    local anchors
                    anchors=$(_get_file_anchors "$repo_root/$check_file")
                    if ! echo "$anchors" | grep -qFx -- "$target_anchor"; then
                        echo "    ERROR: $md_file:$line_num — broken anchor '#$target_anchor' in '$(basename "$check_file")'"
                        ((errors++))
                    fi
                fi
            done <<< "$targets"
        done < "$repo_root/$md_file"
    done <<< "$md_files"

    if [[ $errors -eq 0 ]]; then
        echo "    OK: All internal doc links valid"
    fi

    return $errors
}
