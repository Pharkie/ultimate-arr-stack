#!/bin/bash
# Shared test helpers for BATS tests

# Resolve paths
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Load BATS helpers
load "$TEST_DIR/bats-support/load"
load "$TEST_DIR/bats-assert/load"

# All compose files in the repo
get_compose_files() {
    local files=()
    for f in "$REPO_ROOT"/docker-compose*.yml; do
        [[ -f "$f" ]] && files+=("$f")
    done
    echo "${files[@]}"
}

# Extract all host ports from compose files (left side of "HOST:CONTAINER")
get_all_ports() {
    for f in $(get_compose_files); do
        grep -E '^\s+-\s*"?[0-9]+:[0-9]+"?\s*$' "$f" 2>/dev/null | \
            sed -E 's/^[[:space:]]*-[[:space:]]*"?([0-9]+):.*/\1/'
    done
}

# Extract all static IPs from compose files
get_all_ips() {
    for f in $(get_compose_files); do
        grep -oE 'ipv4_address:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$f" 2>/dev/null | \
            sed -E 's/ipv4_address:[[:space:]]*//'
    done
}

# Extract all image references from compose files
get_all_images() {
    for f in $(get_compose_files); do
        grep -E '^[[:space:]]+image:[[:space:]]' "$f" 2>/dev/null | \
            sed -E 's/^[[:space:]]+image:[[:space:]]*//'
    done
}

# Extract image references for services that are actually pulled from a
# registry — excludes services with a sibling `build:` directive, whose
# `image:` line is just a local tag name (e.g. magnetio-addon:local), not a
# real registry reference. Those can't be "pinned" or checked for existence
# against a registry the same way. Optional $1 restricts to a single file;
# defaults to every compose file.
get_pulled_images() {
    local files
    if [[ -n "${1:-}" ]]; then
        files="$1"
    else
        files=$(get_compose_files)
    fi
    for f in $files; do
        awk '
            /^  [a-zA-Z0-9_.-]+:[[:space:]]*$/ {
                if (svc != "" && !built) print img
                svc=$0; img=""; built=0; next
            }
            /^[[:space:]]+build:/ { built=1 }
            /^[[:space:]]+image:[[:space:]]/ {
                sub(/^[[:space:]]+image:[[:space:]]*/, "")
                img=$0
            }
            END { if (svc != "" && !built) print img }
        ' "$f"
    done
}
