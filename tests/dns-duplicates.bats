#!/usr/bin/env bats
# Tests for hook check 8 (scripts/lib/check-dns-duplicates.sh) and for
# scripts/check-dns-duplicates.sh, which shares its parsing.
#
# check_dns_duplicates runs end to end with ssh_to_nas replaced by a local
# shell that plays the NAS. That shell's PATH has a `grep` that rejects -P, as
# BusyBox's does, and a `docker` that serves $TOML as pihole.toml, or fails as
# it would with the pihole container down when $TOML doesn't exist. A check
# that leans on the NAS's grep, or reads an unreadable pihole.toml as "no
# duplicates", fails here.

setup() {
    load helpers/setup
    source "$REPO_ROOT/scripts/lib/check-dns-duplicates.sh"

    NAS="$BATS_TEST_TMPDIR/nas"
    CONF="$NAS/stack/pihole/dnsmasq.d/02-local-dns.conf"
    TOML="$NAS/pihole.toml"
    DOCKER_LOG="$NAS/docker.log"
    export TOML DOCKER_LOG
    mkdir -p "$NAS/bin" "$(dirname "$CONF")"

    cat > "$NAS/bin/grep" <<SHIM
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        --) break ;;
        -P*|-[!-]*P*|--perl-regexp) echo "grep: unrecognized option: P" >&2; exit 2 ;;
    esac
done
exec $(command -v grep) "\$@"
SHIM
    cat > "$NAS/bin/docker" <<'SHIM'
#!/bin/bash
echo "$*" >> "$DOCKER_LOG"
[ "$*" = "exec pihole cat /etc/pihole/pihole.toml" ] || { echo "fake docker: refusing '$*'" >&2; exit 99; }
[ -f "$TOML" ] || { echo "Error response from daemon: container pihole is not running" >&2; exit 1; }
cat "$TOML"
SHIM
    chmod +x "$NAS/bin/grep" "$NAS/bin/docker"

    # The NAS is up, answers SSH, and runs what it's sent with its own PATH.
    has_nas_config() { return 0; }
    is_nas_reachable() { return 0; }
    is_ssh_available() { return 0; }
    get_nas_stack_dir() { echo "$NAS/stack"; }
    ssh_to_nas() { PATH="$NAS/bin:$PATH" bash -c "$1" 2>/dev/null; }
}

# A clean 02-local-dns.conf of five names, plus any lines given.
conf_fixture() {
    { cat <<'EOF'
# Local .lan domains
address=/jellyfin.lan/192.168.1.11
address=/seerr.lan/192.168.1.11
address=/jellyseerr.lan/192.168.1.11
address=/sonarr.lan/192.168.1.11
address=/radarr.lan/192.168.1.11
#address=/sonarr.lan/192.168.1.12

# Return empty AAAA for .lan
address=/lan/::
EOF
      printf '%s\n' "$@"
    } > "$CONF"
}

# A pihole.toml whose dns.hosts holds the given entries. Its help text and
# its dhcp.hosts both mention sonarr.lan; neither is a DNS record.
toml_fixture() {
    local e
    { cat <<'EOF'
[dns]
  # Array of custom DNS records
  #
  # Example: [ "127.0.0.1 mylocal", "192.168.1.11 sonarr.lan" ]
EOF
      if [ $# -eq 0 ]; then
          echo '  hosts = []'
      else
          echo '  hosts = ['
          for e in "$@"; do echo "    \"$e\","; done
          echo '  ] ### CHANGED, default = []'
      fi
      cat <<'EOF'

[dhcp]
  hosts = [ "aa:bb:cc:dd:ee:ff,192.168.1.50,sonarr.lan" ]
EOF
    } > "$TOML"
}

# ---------------------------------------------------------------------------
# report_dns_duplicates: local files, no SSH
# ---------------------------------------------------------------------------

@test "report FAILS: a name defined twice in 02-local-dns.conf" {
    conf_fixture "address=/sonarr.lan/192.168.1.12"
    toml_fixture
    run report_dns_duplicates "$CONF" "$TOML"
    assert_failure 1
    assert_output "    WARNING: .lan names defined more than once in 02-local-dns.conf:
      - sonarr.lan"
}

@test "report FAILS: a name in both 02-local-dns.conf and pihole.toml, whatever its case" {
    conf_fixture
    toml_fixture "192.168.1.20 nas.lan" "192.168.1.11 other.lan Radarr.LAN"
    run report_dns_duplicates "$CONF" "$TOML"
    assert_failure 1
    assert_output "    WARNING: .lan names defined in both 02-local-dns.conf and pihole.toml:
      - radarr.lan"
}

@test "report: both kinds at once are both listed" {
    conf_fixture "address=/jellyfin.lan/192.168.1.12"
    toml_fixture "192.168.1.11 sonarr.lan"
    run report_dns_duplicates "$CONF" "$TOML"
    assert_failure 1
    assert_output --partial "more than once in 02-local-dns.conf:
      - jellyfin.lan"
    assert_output --partial "in both 02-local-dns.conf and pihole.toml:
      - sonarr.lan"
}

@test "report: clean files are OK, with what was counted on each side" {
    conf_fixture
    toml_fixture "192.168.1.20 nas.lan"
    run report_dns_duplicates "$CONF" "$TOML"
    assert_success
    assert_output "    OK: No duplicate .lan names (5 in 02-local-dns.conf, 1 in pihole.toml)"
}

@test "report: A plus AAAA, the .lan catch-all, comments, near-names and DHCP hosts are not duplicates" {
    conf_fixture "address=/jellyfin.lan/fd00::11"
    toml_fixture "192.168.1.30 seer.lan"
    run report_dns_duplicates "$CONF" "$TOML"
    assert_success
    assert_output "    OK: No duplicate .lan names (5 in 02-local-dns.conf, 1 in pihole.toml)"
}

@test "report: without pihole.toml, 02-local-dns.conf is still checked and the OK line says so" {
    conf_fixture "address=/radarr.lan/192.168.1.12"
    run report_dns_duplicates "$CONF" ""
    assert_failure 1
    assert_output --partial "      - radarr.lan"

    conf_fixture
    run report_dns_duplicates "$CONF" ""
    assert_success
    assert_output "    OK: No .lan name defined twice in 02-local-dns.conf (5 names; pihole.toml not compared)"
}

@test "report: no .lan address lines at all is a SKIP, never OK" {
    printf '# nothing here\naddress=/lan/::\n' > "$CONF"
    toml_fixture
    run report_dns_duplicates "$CONF" "$TOML"
    assert_success
    assert_output "    SKIP: No address=/NAME.lan/ lines in 02-local-dns.conf"
}

# ---------------------------------------------------------------------------
# check_dns_duplicates (hook check 8): over the fake NAS
# ---------------------------------------------------------------------------

@test "check 8 FAILS on a NAS whose grep has no -P: both duplicates still found" {
    conf_fixture "address=/sonarr.lan/192.168.1.12"
    toml_fixture "192.168.1.11 radarr.lan"
    run check_dns_duplicates
    assert_success  # warns, never blocks
    assert_output --partial "more than once in 02-local-dns.conf:
      - sonarr.lan"
    assert_output --partial "in both 02-local-dns.conf and pihole.toml:
      - radarr.lan"
    refute_output --partial "SKIP"
}

@test "check 8 on clean files: OK with counts, and docker only asked for pihole.toml" {
    conf_fixture
    toml_fixture
    run check_dns_duplicates
    assert_success
    assert_output "    OK: No duplicate .lan names (5 in 02-local-dns.conf, 0 in pihole.toml)"
    assert_equal "$(cat "$DOCKER_LOG")" "exec pihole cat /etc/pihole/pihole.toml"
}

@test "check 8 with the pihole container down: says pihole.toml wasn't compared, never a plain OK" {
    conf_fixture
    run check_dns_duplicates
    assert_success
    assert_output --partial "SKIP: Could not read pihole.toml from the pihole container, so it isn't compared"
    assert_output --partial "OK: No .lan name defined twice in 02-local-dns.conf (5 names; pihole.toml not compared)"
    refute_output --partial "OK: No duplicate .lan names"
}

@test "check 8 with no 02-local-dns.conf: a SKIP naming the path" {
    toml_fixture
    run check_dns_duplicates
    assert_success
    assert_output "    SKIP: Could not read $NAS/stack/pihole/dnsmasq.d/02-local-dns.conf on the NAS"
}

# ---------------------------------------------------------------------------
# scripts/check-dns-duplicates.sh, run as on the NAS
# ---------------------------------------------------------------------------

@test "check-dns-duplicates.sh FAILS: a duplicate exits 1 and is named" {
    conf_fixture "address=/sonarr.lan/192.168.1.12"
    toml_fixture "192.168.1.11 radarr.lan"
    run env PATH="$NAS/bin:$PATH" DNSMASQ_CONF="$CONF" "$REPO_ROOT/scripts/check-dns-duplicates.sh"
    assert_failure 1
    assert_output --partial "      - sonarr.lan"
    assert_output --partial "      - radarr.lan"
    assert_output --partial "CONFLICT"
}

@test "check-dns-duplicates.sh: clean files exit 0" {
    conf_fixture
    toml_fixture
    run env PATH="$NAS/bin:$PATH" DNSMASQ_CONF="$CONF" "$REPO_ROOT/scripts/check-dns-duplicates.sh"
    assert_success
    assert_output --partial "OK: No duplicate .lan names (5 in 02-local-dns.conf, 0 in pihole.toml)"
}
