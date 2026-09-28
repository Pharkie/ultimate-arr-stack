#!/bin/bash
# Port and IP conflict detection for compose files
#
# Reads the RENDERED compose model of every docker-compose*.yml, with every
# profile, through compose-conflicts.py; see that file for what counts as a
# clash. It used to grep the YAML text for `- "HOST:CONTAINER"` with nothing
# after it, so a trailing comment, a /udp suffix or a host-IP prefix hid the
# line: it saw 3 of the 18 published ports, and giving Pi-hole qBittorrent's
# 8085 passed.
#
# Prints its own status line, like the YAML check. Without docker compose or
# a working python3 it says SKIPPED and returns 0: the hook must still run on
# such a machine, but must not print OK for ports it never looked at.
# Returns non-zero on a clash, or when a compose file cannot be rendered.

check_conflicts() {
    local repo_root lib_dir env_file
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root="."
    lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

    local files=() f
    for f in "$repo_root"/docker-compose*.yml; do
        [[ -f "$f" ]] && files+=("$f")
    done
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "    SKIP: No compose files found"
        return 0
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo "    SKIPPED: docker compose not available — ports and static IPs were not checked."
        return 0
    fi
    if ! python3 -c 'import json, subprocess' >/dev/null 2>&1; then
        echo "    SKIPPED: python3 not available — ports and static IPs were not checked."
        return 0
    fi

    # Placeholder values, so ${NAS_IP} and the like render. The checked repo's
    # own copy first; a throwaway repo without one borrows this checkout's.
    local env_args=()
    for env_file in "$repo_root/tests/fixtures/.env.test" "$lib_dir/../../tests/fixtures/.env.test"; do
        if [[ -f "$env_file" ]]; then
            env_args=(--env-file "$env_file")
            break
        fi
    done

    python3 "$lib_dir/compose-conflicts.py" ${env_args[@]+"${env_args[@]}"} "${files[@]}"
}
