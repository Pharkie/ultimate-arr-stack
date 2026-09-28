#!/bin/bash
# Check for .lan names that Pi-hole's local DNS defines twice:
#   - twice in pihole/dnsmasq.d/02-local-dns.conf, for the same address family
#     (an A line and an AAAA line for one name are not a duplicate), or
#   - in 02-local-dns.conf and also in pihole.toml's dns.hosts (the web UI's
#     Local DNS Records).
# Returns warnings only - does not block commits.
#
# Both files are fetched raw over SSH and parsed here with awk, so nothing
# depends on the NAS's grep (the old `grep -P` needed GNU grep there). The
# parsing lives in report_dns_duplicates, which takes two local files: it is
# tested without SSH (tests/dns-duplicates.bats) and shared with
# scripts/check-dns-duplicates.sh, which runs on the NAS.

# Source common functions
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# stdin: a dnsmasq config. stdout: "NAME FAMILY" for each .lan name on each
# active `address=/NAME.lan/.../ADDRESS` line, NAME lower-cased and without
# ".lan", FAMILY v6 if ADDRESS has a colon, else v4. Catch-alls such as
# `address=/lan/::` name no host and print nothing.
dnsmasq_lan_names() {
    awk -F/ '
        /^[ \t]*address=\// {
            family = ($NF ~ /:/) ? "v6" : "v4"
            for (i = 2; i < NF; i++) {
                name = tolower($i)
                if (name ~ /\.lan$/) { sub(/\.lan$/, "", name); print name, family }
            }
        }'
}

# stdin: pihole.toml. stdout: each .lan name, lower-cased and without ".lan",
# in any uncommented "IP NAME [NAME ...]" string, which is the form dns.hosts
# entries take. Comment lines are skipped: pihole.toml's own help text quotes
# examples in that form.
pihole_toml_lan_names() {
    awk '
        /^[ \t]*#/ { next }
        {
            line = $0
            while (match(line, /"[0-9A-Fa-f]*[.:][0-9A-Fa-f.:]*[ \t]+[^"]*"/)) {
                n = split(substr(line, RSTART + 1, RLENGTH - 2), field, /[ \t]+/)
                line = substr(line, RSTART + RLENGTH)
                for (i = 2; i <= n; i++) {
                    name = tolower(field[i])
                    if (name ~ /\.lan$/) { sub(/\.lan$/, "", name); print name }
                }
            }
        }'
}

# report_dns_duplicates DNSMASQ_CONF [PIHOLE_TOML]
# Prints what it found. Returns 1 if any .lan name is defined twice, else 0.
# With no PIHOLE_TOML (pihole.toml couldn't be read), 02-local-dns.conf is
# checked against itself only, and the OK line says so.
report_dns_duplicates() {
    local dnsmasq_conf="$1" pihole_toml="${2:-}"
    local entries names twice="" both="" toml_names="" found=0

    entries=$(dnsmasq_lan_names < "$dnsmasq_conf")
    if [[ -z "$entries" ]]; then
        echo "    SKIP: No address=/NAME.lan/ lines in 02-local-dns.conf"
        return 0
    fi
    names=$(printf '%s\n' "$entries" | cut -d' ' -f1 | sort -u)
    twice=$(printf '%s\n' "$entries" | sort | uniq -d | cut -d' ' -f1 | sort -u)

    if [[ -n "$pihole_toml" ]]; then
        toml_names=$(pihole_toml_lan_names < "$pihole_toml" | sort -u)
        if [[ -n "$toml_names" ]]; then
            both=$(comm -12 <(printf '%s\n' "$names") <(printf '%s\n' "$toml_names"))
        fi
    fi

    if [[ -n "$twice" ]]; then
        echo "    WARNING: .lan names defined more than once in 02-local-dns.conf:"
        printf '%s\n' "$twice" | sed 's/.*/      - &.lan/'
        found=1
    fi
    if [[ -n "$both" ]]; then
        echo "    WARNING: .lan names defined in both 02-local-dns.conf and pihole.toml:"
        printf '%s\n' "$both" | sed 's/.*/      - &.lan/'
        found=1
    fi
    [[ $found -eq 0 ]] || return 1

    local n_conf n_toml
    n_conf=$(printf '%s\n' "$names" | wc -l | tr -d ' ')
    if [[ -n "$pihole_toml" ]]; then
        n_toml=0
        [[ -z "$toml_names" ]] || n_toml=$(printf '%s\n' "$toml_names" | wc -l | tr -d ' ')
        echo "    OK: No duplicate .lan names ($n_conf in 02-local-dns.conf, $n_toml in pihole.toml)"
    else
        echo "    OK: No .lan name defined twice in 02-local-dns.conf ($n_conf names; pihole.toml not compared)"
    fi
    return 0
}

check_dns_duplicates() {
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

    local stack_dir tmp pihole_toml
    stack_dir=$(get_nas_stack_dir)
    if ! tmp=$(mktemp -d); then
        echo "    SKIP: Could not create a temporary directory"
        return 0
    fi

    if ! ssh_to_nas "cat '$stack_dir/pihole/dnsmasq.d/02-local-dns.conf'" > "$tmp/02-local-dns.conf"; then
        echo "    SKIP: Could not read $stack_dir/pihole/dnsmasq.d/02-local-dns.conf on the NAS"
        rm -rf "$tmp"
        return 0
    fi

    pihole_toml="$tmp/pihole.toml"
    if ! ssh_to_nas "docker exec pihole cat /etc/pihole/pihole.toml" > "$pihole_toml"; then
        echo "    SKIP: Could not read pihole.toml from the pihole container, so it isn't compared"
        pihole_toml=""
    fi

    report_dns_duplicates "$tmp/02-local-dns.conf" "$pihole_toml" || true  # Warning only, don't block
    rm -rf "$tmp"
    return 0
}
