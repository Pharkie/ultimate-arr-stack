#!/usr/bin/env bats
# scripts/check-network.sh — the orphaned-network reporter.
#
# The interesting half of this script is the branch a test must NOT complete:
# `docker network rm`. Everything here runs behind tests/helpers/stubs.bash, so
# the one test that deliberately drives the removal path asserts the breadcrumb
# forbid() leaves rather than the removal happening.
#
# The script is sourced rather than executed for most tests. Its `main` runs
# only under the BASH_SOURCE guard, so sourcing gives direct access to
# check_one_network() without going through four networks first.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    SCRIPT="$REPO_ROOT/scripts/check-network.sh"

    # One file per network that EXISTS. Its contents are what
    # `docker network inspect -f '{{range .Containers}}...'` returns, so an
    # empty file is an existing-but-empty network and a missing file is a
    # network that was never created.
    NETDIR="$BATS_TEST_TMPDIR/networks"
    mkdir -p "$NETDIR"
    export NETDIR

    stub_docker '
        [ "$1" = network ] || { echo "unexpected docker argv: $*" >&2; exit 125; }
        case "$2" in
            inspect)
                [ -f "$NETDIR/$3" ] || exit 1
                if [ "${4:-}" = "-f" ]; then cat "$NETDIR/$3"; fi
                ;;
            ls) printf "NAME\tDRIVER\tSCOPE\n" ;;
            *)  echo "unexpected docker network verb: $2" >&2; exit 126 ;;
        esac
    '

    # Sourcing the script and calling one of its functions, with the tty seam
    # forced. FAKE_TTY=1 is the interactive branch; anything else is not.
    #
    # A separate process rather than sourcing into the bats shell: the script
    # sets `-euo pipefail`, and inheriting nounset into bats' own machinery is
    # a way to make unrelated tests fail for reasons that have nothing to do
    # with the script under test.
    DRIVER="$BATS_TEST_TMPDIR/drive"
    cat > "$DRIVER" <<'EOF'
#!/bin/bash
source "$SCRIPT"
if [ "${FAKE_TTY:-0}" = 1 ]; then
    stdin_is_tty() { return 0; }
else
    stdin_is_tty() { return 1; }
fi
"$@"
EOF
    chmod +x "$DRIVER"
    export SCRIPT
}

exists_with() { printf '%s' "$2" > "$NETDIR/$1"; }
exists_empty() { : > "$NETDIR/$1"; }

# The networks this repo's compose files CREATE, read off the compose files
# themselves. A top-level `networks:` block only; a key carrying
# `external: true` is joined, not created, and does not belong to us.
created_networks() {
    local f
    for f in "$REPO_ROOT"/docker-compose*.yml; do
        awk '
            /^networks:$/ { inb = 1; next }
            inb && /^[^[:space:]]/ { inb = 0 }
            !inb { next }
            /^  [^ #][^:]*:[[:space:]]*$/ {
                if (name != "") print name "\t" ext
                name = $0; sub(/^  /, "", name); sub(/:.*$/, "", name); ext = 0
                next
            }
            /external:[[:space:]]*true/ { ext = 1 }
            END { if (name != "") print name "\t" ext }
        ' "$f"
    done | awk -F'\t' '$2 == 0 { print $1 }' | sort -u
}

@test "check-network: a network that does not exist reports OK and touches nothing" {
    run "$DRIVER" check_one_network arr-core
    assert_success
    assert_output --partial "arr-core doesn't exist (will be created on deploy)"
    assert_nothing_forbidden
    # The report arm must not go on to ask what is attached to a network that
    # is not there.
    assert_stub_not_called docker "inspect arr-core -f"
}

@test "check-network: a network with containers names them and is never offered for removal" {
    exists_with vpn-net "gluetun qbittorrent "
    run "$DRIVER" check_one_network vpn-net
    assert_success
    assert_output --partial "vpn-net exists with containers: gluetun qbittorrent"
    refute_output --partial "orphaned"
    assert_nothing_forbidden
}

@test "check-network: a network with no containers is reported as possibly orphaned" {
    exists_empty magnetio-net
    run "$DRIVER" check_one_network magnetio-net
    assert_success
    assert_output --partial "WARNING"
    assert_output --partial "magnetio-net network exists but has no containers attached"
    assert_output --partial "This may be orphaned from a previous deployment"
    assert_nothing_forbidden
}

@test "check-network: a separator-only inspect result is not mistaken for a network in use" {
    # The template emits a trailing space per name, so the empty case is "" —
    # but a template edit that left a bare separator behind would make every
    # orphan read as in-use and quietly retire this script's only real job.
    exists_with traefik-lan "   "
    run "$DRIVER" check_one_network traefik-lan
    assert_success
    assert_output --partial "no containers attached"
    refute_output --partial "exists with containers"
}

@test "check-network: a container-list inspect that fails does not kill the report" {
    # The existence check and the container-list check are two separate
    # `docker network inspect` calls and they can disagree: the network can be
    # removed between them, or the daemon can fail one and not the other. A
    # half-finished cleanup is the state this script is run in, so that is the
    # moment it must not die. `|| true` keeps a failed substitution from
    # becoming a fatal assignment under `set -e`; with `&& true` the assignment
    # carries docker's status, the script exits 1 having printed nothing about
    # the network, and every network after it goes unexamined.
    stub_docker '
        [ "$1" = network ] || { echo "unexpected docker argv: $*" >&2; exit 125; }
        case "$2" in
            inspect)
                # It exists, and then cannot be asked what is attached to it.
                [ "${4:-}" = "-f" ] && exit 1
                exit 0
                ;;
            ls) printf "NAME\tDRIVER\tSCOPE\n" ;;
            *)  echo "unexpected docker network verb: $2" >&2; exit 126 ;;
        esac
    '
    run "$DRIVER" main
    assert_success
    assert_nothing_forbidden
    # The list is worked to the end rather than stopping at the first network
    # whose container list could not be read.
    assert_stub_called docker "network inspect traefik-lan -f"
}

@test "check-network: a non-interactive run prints the manual command and removes nothing" {
    exists_empty arr-core
    FAKE_TTY=0 run "$DRIVER" check_one_network arr-core
    assert_success
    assert_output --partial "Run interactively to remove, or use: docker network rm arr-core"
    assert_nothing_forbidden
    assert_stub_not_called docker "network rm"
}

@test "check-network: the real stdin_is_tty seam is false when stdin is not a terminal" {
    # The override above is only trustworthy if the thing it overrides agrees
    # with it by default. This runs the script for real, no seam override, with
    # bats' own non-tty stdin.
    exists_empty vpn-net
    run "$SCRIPT" < /dev/null
    assert_success
    assert_output --partial "Run interactively to remove, or use: docker network rm vpn-net"
    assert_nothing_forbidden
}

@test "check-network: answering y reaches docker network rm" {
    exists_empty arr-core
    FAKE_TTY=1 run "$DRIVER" check_one_network arr-core <<< "y"
    # Asserted on the argv, not on the rule name: `rm` and `network rm` are both
    # in the denylist and the first one to match wins, so pinning the rule would
    # make this test a statement about the order of an unrelated array.
    assert_forbidden "argv: network rm arr-core"
    [ "$status" -eq 99 ]
}

@test "check-network: answering Y reaches docker network rm" {
    exists_empty arr-core
    FAKE_TTY=1 run "$DRIVER" check_one_network arr-core <<< "Y"
    assert_forbidden "argv: network rm arr-core"
    [ "$status" -eq 99 ]
}

@test "check-network: answering n removes nothing and says how to do it by hand" {
    exists_empty arr-core
    FAKE_TTY=1 run "$DRIVER" check_one_network arr-core <<< "n"
    assert_success
    assert_output --partial "Skipped. You can remove it manually with: docker network rm arr-core"
    assert_nothing_forbidden
    assert_stub_not_called docker "network rm"
}

@test "check-network: pressing enter removes nothing - the default is No" {
    exists_empty arr-core
    FAKE_TTY=1 run "$DRIVER" check_one_network arr-core <<< ""
    assert_success
    assert_output --partial "Skipped."
    assert_nothing_forbidden
}

@test "check-network: closed input removes nothing and does not abort the run" {
    # Ctrl-D at the prompt. `read` returns non-zero, and the script runs under
    # `set -e`, so the safe branch has to be reached deliberately rather than
    # by the script dying before it gets there.
    exists_empty arr-core
    FAKE_TTY=1 run "$DRIVER" check_one_network arr-core < /dev/null
    assert_success
    assert_output --partial "Skipped."
    assert_nothing_forbidden
}

@test "check-network: main checks every network in OWNED_NETWORKS" {
    run "$DRIVER" main
    assert_success
    # shellcheck disable=SC1090
    local net
    for net in $(bash -c 'source "$1"; printf "%s\n" "${OWNED_NETWORKS[@]}"' _ "$SCRIPT"); do
        assert_output --partial "$net doesn't exist"
        assert_stub_called docker "network inspect $net"
    done
}

@test "check-network: OWNED_NETWORKS is exactly the set the compose files create" {
    local declared derived
    declared=$(bash -c 'source "$1"; printf "%s\n" "${OWNED_NETWORKS[@]}"' _ "$SCRIPT" | sort -u)
    derived=$(created_networks)
    [ -n "$derived" ] || fail "derived no networks from the compose files - the parser broke"
    if [ "$declared" != "$derived" ]; then
        fail "$(printf 'OWNED_NETWORKS has drifted from the compose files\n--- declared ---\n%s\n--- created by compose ---\n%s' "$declared" "$derived")"
    fi
}

@test "check-network: main lists every docker network and points at prune" {
    run "$DRIVER" main
    assert_success
    assert_output --partial "All Docker networks:"
    assert_stub_called docker "network ls --format"
    assert_output --partial "Tip: To clean up all unused networks: docker network prune"
}

@test "check-network: no escape sequences when stdout is not a terminal" {
    exists_with arr-core "sonarr "
    exists_empty vpn-net
    run "$DRIVER" main
    assert_success
    if printf '%s' "$output" | grep -q $'\033'; then
        fail "colour escapes leaked into a non-terminal run"
    fi
}
