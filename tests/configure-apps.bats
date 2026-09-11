#!/usr/bin/env bats
# scripts/configure-apps.sh — the API-driven app configurator.
#
# This is the most destructive script in the repo that a test is allowed near:
# it POSTs configuration into six live services and restarts two containers.
# Everything here runs behind tests/helpers/stubs.bash, and the headline test is
# the one that drives the WHOLE script with --dry-run and asserts that forbid()
# was never tripped — i.e. that the dry-run gate really does sit in front of
# every mutation, rather than in front of most of them.
#
# The script is sourced rather than executed. Its `main` runs only under the
# BASH_SOURCE guard, so sourcing gives direct access to the eight functions the
# refactor split out.

setup() {
    load helpers/setup
    load helpers/stubs
    stub_init

    SCRIPT="$REPO_ROOT/scripts/configure-apps.sh"

    # Everything the docker stub answers with. One file per question, so a test
    # changes the world by writing a file rather than by rewriting the stub.
    FIX="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$FIX"
    printf '%s\n' gluetun qbittorrent sonarr radarr prowlarr bazarr > "$FIX/running"
    echo healthy > "$FIX/gluetun-health"
    printf '<Config>\n  <ApiKey>sonarrkey1234</ApiKey>\n</Config>\n' > "$FIX/sonarr.xml"
    printf '<Config>\n  <ApiKey>radarrkey1234</ApiKey>\n</Config>\n' > "$FIX/radarr.xml"
    printf '<Config>\n  <ApiKey>prowlarrkey12</ApiKey>\n</Config>\n' > "$FIX/prowlarr.xml"
    # What `docker exec bazarr grep '^\s*apikey:' ...` would print, not the
    # whole file: the stub stands in for the grep, not for the config.
    printf '  apikey: bazarrkey1234\n' > "$FIX/bazarr.yaml"
    printf 'api_key = sabkey12345\n' > "$FIX/sabnzbd.ini"
    : > "$FIX/qbit-logs"
    echo '192.168.8.100 10.0.0.5' > "$FIX/hostname"
    echo 200 > "$FIX/curl-out"
    export FIX

    stub_docker '
        case "$1" in
            ps)      cat "$FIX/running" ;;
            inspect)
                # configure-apps.sh:196 is the only inspect call in the script:
                #   docker inspect -f '{{.State.Health.Status}}' gluetun
                # Answering ANY inspect argv with canned content would let a broken
                # format string pass here and fail on real docker with a template
                # parse error -- the one thing this stub cannot check for itself.
                [ "$*" = "inspect -f {{.State.Health.Status}} gluetun" ] \
                    || { echo "unexpected docker inspect argv: $*" >&2; exit 125; }
                cat "$FIX/gluetun-health" ;;
            logs)    cat "$FIX/qbit-logs" ;;
            exec)
                case "$*" in
                    *config.xml*)  cat "$FIX/$2.xml"    2>/dev/null || exit 1 ;;
                    *config.yaml*) cat "$FIX/bazarr.yaml"  2>/dev/null || exit 1 ;;
                    *sabnzbd.ini*) cat "$FIX/sabnzbd.ini"  2>/dev/null || exit 1 ;;
                    *) echo "unexpected docker exec: $*" >&2; exit 126 ;;
                esac ;;
            *) echo "unexpected docker argv: $*" >&2; exit 125 ;;
        esac
    '
    # qBittorrent's real (non-dry) path talks to four endpoints with four
    # different response shapes, so the curl stub dispatches on the URL. Anything
    # else — every wait_for_service health poll — gets the default.
    printf 'Ok.\n200\n' > "$FIX/qbit-auth"
    echo 200 > "$FIX/qbit-category-code"
    echo 200 > "$FIX/qbit-setprefs-code"
    # The preference set the script considers already-correct. Identical to the
    # payload it would POST, which is the property the check exists to have.
    printf '%s\n' '{"auto_tmm_enabled":true,"upnp":false,"limit_utp_rate":true,"limit_lan_peers":true,"encryption":1,"max_inactive_seeding_time_enabled":true,"max_inactive_seeding_time":30,"max_ratio_act":0,"max_active_downloads":5,"max_active_torrents":10,"max_active_uploads":5}' > "$FIX/qbit-prefs.json"
    stub_curl '
        for a in "$@"; do
            case "$a" in
                */api/v2/auth/login)              cat "$FIX/qbit-auth";          exit 0 ;;
                */api/v2/torrents/createCategory) cat "$FIX/qbit-category-code"; exit 0 ;;
                */api/v2/app/preferences)         cat "$FIX/qbit-prefs.json";    exit 0 ;;
                */api/v2/app/setPreferences)      cat "$FIX/qbit-setprefs-code"; exit 0 ;;
            esac
        done
        cat "$FIX/curl-out"
    '
    stub_tool hostname 'cat "$FIX/hostname"'

    # mktemp -t honours TMPDIR, so pointing it at a per-test directory makes
    # "the cookie was cleaned up" an assertion about an empty directory rather
    # than a hunt through the real /tmp.
    TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    export TMPDIR

    ENV_FILE="$BATS_TEST_TMPDIR/env"
    : > "$ENV_FILE"
    export CONFIGURE_ENV_FILE="$ENV_FILE"

    # Source the script in a separate process and call one of its functions.
    # Separate because the script sets `-uo pipefail` and defines `skip()` —
    # which would shadow bats' own `skip` in the test shell.
    #
    # DRIVER_PRE is arbitrary shell run after the source and before the call,
    # so a test can set a global or override a function without the script
    # needing a seam for each one.
    DRIVER="$BATS_TEST_TMPDIR/drive"
    cat > "$DRIVER" <<'EOF'
#!/bin/bash
source "$SCRIPT"
[ -n "${DRIVER_PRE:-}" ] && eval "$DRIVER_PRE"
"$@"
EOF
    chmod +x "$DRIVER"
    export SCRIPT
}

# ---------------------------------------------------------------- print_usage

@test "configure-apps: --help prints the whole header block, not a line range" {
    run "$DRIVER" parse_args --help
    assert_success
    assert_output --partial "Automated app configuration for arr-stack"
    # The line the old `head -27 | tail -24` silently dropped.
    assert_output --partial "SABnzbd: usenet provider credentials + folder config"
    # ...and it must stop at the blank line, not run into the next block.
    refute_output --partial "No \`set -e\`, deliberately"
}

@test "configure-apps: the help block is derived from the file, not a fixed length" {
    # Independent derivation: grep -v '^#' DOES match a blank line, which is
    # exactly the property the script's awk relies on and a sed `/^[^#]/` range
    # does not have. If someone adds or removes a header line, this moves with
    # it; a hardcoded number would not.
    local end expected
    # tail -n +2 renumbers file line N as N-1, so the index of the first
    # non-comment line IS the file line of the last comment line.
    end=$(tail -n +2 "$SCRIPT" | grep -n -m1 -v '^#' | cut -d: -f1)
    [ "$end" -gt 20 ]
    expected=$(sed -n "2,${end}p" "$SCRIPT" | sed 's/^#\{1\} \{0,1\}//')

    run "$DRIVER" print_usage "$SCRIPT"
    assert_success
    # Whole content, not a line count: a count would still pass if the block
    # started or ended one line off.
    [ "$output" = "$expected" ]
}

@test "configure-apps: --help exits 0 without configuring anything" {
    run "$DRIVER" main --help
    assert_success
    assert_stub_not_called docker ''
    assert_nothing_forbidden
}

# ----------------------------------------------------------------- parse_args

@test "configure-apps: --dry-run sets the flag and nothing else" {
    run "$DRIVER" eval 'parse_args --dry-run; echo "DRY=$DRY_RUN VERBOSE=$VERBOSE"'
    assert_success
    assert_output "DRY=true VERBOSE=false"
}

@test "configure-apps: --verbose and -v are the same flag" {
    run "$DRIVER" eval 'parse_args --verbose; echo "V=$VERBOSE"'
    assert_output "V=true"
    run "$DRIVER" eval 'parse_args -v; echo "V=$VERBOSE"'
    assert_output "V=true"
}

@test "configure-apps: flags can be combined and order does not matter" {
    run "$DRIVER" eval 'parse_args -v --dry-run; echo "$DRY_RUN $VERBOSE"'
    assert_output "true true"
}

@test "configure-apps: an unknown option is named and fails without exiting" {
    # `return 1`, not `exit 1` — so a caller can report it. STILLHERE proves
    # the difference; the status alone cannot.
    run "$DRIVER" eval 'parse_args --wat; echo "RC=$?"; echo STILLHERE'
    assert_success
    assert_output --partial "Unknown option: --wat"
    assert_output --partial "RC=1"
    assert_output --partial "STILLHERE"
}

@test "configure-apps: main refuses to run when an argument is unknown" {
    run "$DRIVER" main --wat
    assert_failure
    assert_stub_not_called docker ''
    assert_nothing_forbidden
}

# ------------------------------------------------------------------ env_value

@test "configure-apps: env_value keeps everything after the first =" {
    printf 'QBIT_PASSWORD=a=b=c\n' > "$ENV_FILE"
    run "$DRIVER" env_value QBIT_PASSWORD "$ENV_FILE"
    assert_success
    assert_output "a=b=c"
}

@test "configure-apps: env_value strips one layer of double quotes" {
    printf 'QBIT_PASSWORD="s3cret"\n' > "$ENV_FILE"
    run "$DRIVER" env_value QBIT_PASSWORD "$ENV_FILE"
    assert_output "s3cret"
}

@test "configure-apps: env_value strips one layer of single quotes" {
    printf "QBIT_PASSWORD='s3cret'\n" > "$ENV_FILE"
    run "$DRIVER" env_value QBIT_PASSWORD "$ENV_FILE"
    assert_output "s3cret"
}

# Every fake password below spells "example" on purpose, and the pre-commit
# hook is why. check-secrets.sh Pattern 9 flags `_PASSWORD=<15+ non-space
# chars>` in any tracked file, and it exempts only `tests/fixtures/*`, not
# `tests/*.bats` -- so a plausible-looking fixture value here blocks every
# later commit in the repo, not just this file's. The pattern's own escape
# hatch is the placeholder allowlist `(your|here|example|placeholder|xxx)`,
# so naming the values as examples keeps the guard armed at full strength
# everywhere instead of widening the exemption to all of tests/.
@test "configure-apps: env_value matches the key at the start of the line only" {
    printf 'OLD_QBIT_PASSWORD=example-wrong\nQBIT_PASSWORD=example-right\n' > "$ENV_FILE"
    run "$DRIVER" env_value QBIT_PASSWORD "$ENV_FILE"
    assert_output "example-right"
}

@test "configure-apps: env_value fails on a missing key and a missing file" {
    printf 'OTHER=1\n' > "$ENV_FILE"
    run "$DRIVER" env_value QBIT_PASSWORD "$ENV_FILE"
    assert_failure
    run "$DRIVER" env_value QBIT_PASSWORD "$BATS_TEST_TMPDIR/nope"
    assert_failure
}

# --------------------------------------------------------- check_prerequisites

@test "configure-apps: check_prerequisites fails when docker is absent" {
    DRIVER_PRE='PATH=/nonexistent-for-tests' run "$DRIVER" check_prerequisites
    assert_failure
    assert_output --partial "docker not found"
}

@test "configure-apps: check_prerequisites fails when no NAS IP can be detected" {
    DRIVER_PRE='hostname() { return 0; }' run "$DRIVER" check_prerequisites
    assert_failure
    assert_output --partial "Could not detect NAS IP"
}

@test "configure-apps: check_prerequisites takes the first address hostname -I prints" {
    run "$DRIVER" eval 'check_prerequisites >/dev/null; echo "IP=$NAS_IP"'
    assert_output --partial "IP=192.168.8.100"
}

@test "configure-apps: every required container is checked and missing ones are named" {
    : > "$FIX/running"
    run "$DRIVER" check_prerequisites
    assert_failure
    local c
    for c in gluetun qbittorrent sonarr radarr prowlarr bazarr; do
        assert_output --partial " $c"
    done
    assert_output --partial "Required containers not running:"
}

@test "configure-apps: one missing container is enough to stop the run" {
    grep -v '^radarr$' "$FIX/running" > "$FIX/running.tmp" && mv "$FIX/running.tmp" "$FIX/running"
    run "$DRIVER" check_prerequisites
    assert_failure
    assert_output --partial "Required containers not running: radarr"
}

@test "configure-apps: a container whose name merely contains a required one does not count" {
    printf '%s\n' gluetun-exit qbittorrent sonarr radarr prowlarr bazarr > "$FIX/running"
    run "$DRIVER" check_prerequisites
    assert_failure
    assert_output --partial "Required containers not running: gluetun"
}

@test "configure-apps: an unhealthy gluetun is named with its actual state" {
    echo unhealthy > "$FIX/gluetun-health"
    run "$DRIVER" check_prerequisites
    assert_failure
    assert_output --partial "Gluetun is 'unhealthy' (need 'healthy')"
}

@test "configure-apps: check_prerequisites returns rather than exits, so main can report" {
    echo starting > "$FIX/gluetun-health"
    run "$DRIVER" eval 'check_prerequisites >/dev/null; echo "RC=$?"; echo STILLHERE'
    assert_success
    assert_output --partial "RC=1"
    assert_output --partial "STILLHERE"
}

@test "configure-apps: SABnzbd is optional and its absence is not a failure" {
    run "$DRIVER" eval 'check_prerequisites >/dev/null; echo "RC=$? SAB=$SABNZBD_RUNNING"'
    assert_output --partial "RC=0 SAB=false"
}

@test "configure-apps: SABNZBD_RUNNING is set when the container is up" {
    echo sabnzbd >> "$FIX/running"
    run "$DRIVER" eval 'check_prerequisites >/dev/null; echo "SAB=$SABNZBD_RUNNING"'
    assert_output --partial "SAB=true"
}

@test "configure-apps: a container whose name merely contains sabnzbd is not sabnzbd" {
    # The same substring-match defect as the required-container check above: with
    # `grep -q` instead of `-qx`, any name containing "sabnzbd" counts. This flag
    # gates the SABnzbd API-key lookup and the manual step in the summary, so
    # an unrelated container (sabnzbd-exporter, a sabnzbd-sidecar) turns an
    # optional service into one the script reaches into and reports a failure
    # for. This repo has already shipped this exact matcher twice.
    printf '%s\n' sabnzbd-exporter >> "$FIX/running"
    run "$DRIVER" eval 'check_prerequisites >/dev/null; echo "SAB=$SABNZBD_RUNNING"'
    assert_output --partial "SAB=false"
}

# ------------------------------------------------------------ API-key discovery

@test "configure-apps: each arr key is read out of that service's own config.xml" {
    run "$DRIVER" discover_api_keys
    assert_success
    assert_output --partial "Sonarr API key: sonarrke..."
    assert_output --partial "Radarr API key: radarrke..."
    assert_output --partial "Prowlarr API key: prowlarr..."
    assert_stub_called docker "exec sonarr cat /config/config.xml"
    assert_stub_called docker "exec radarr cat /config/config.xml"
    assert_stub_called docker "exec prowlarr cat /config/config.xml"
}

@test "configure-apps: a missing arr key is reported as a failure, not skipped silently" {
    rm "$FIX/radarr.xml"
    run "$DRIVER" eval 'discover_api_keys >/dev/null 2>&1; echo "FAILED=$FAILED"'
    assert_output --partial "FAILED=1"
}

@test "configure-apps: the Bazarr key comes off the apikey line of its yaml" {
    run "$DRIVER" discover_api_keys
    assert_output --partial "Bazarr API key: bazarrke..."
}

@test "configure-apps: a missing Bazarr key is a counted failure" {
    rm "$FIX/bazarr.yaml"
    run "$DRIVER" eval 'discover_api_keys >/dev/null 2>&1; echo "FAILED=$FAILED"'
    assert_output --partial "FAILED=1"
}

@test "configure-apps: SABnzbd's key is only looked for when SABnzbd is running" {
    run "$DRIVER" discover_api_keys
    assert_stub_not_called docker "sabnzbd.ini"
    DRIVER_PRE='SABNZBD_RUNNING=true' run "$DRIVER" discover_api_keys
    assert_output --partial "SABnzbd API key: sabkey12..."
}

@test "configure-apps: a QBIT_PASSWORD in the environment wins over everything else" {
    printf 'QBIT_PASSWORD=example-env-file\n' > "$ENV_FILE"
    QBIT_PASSWORD=example-environment \
        run "$DRIVER" eval 'discover_api_keys >/dev/null 2>&1; echo "PW=[$QBIT_PASSWORD]"'
    assert_output --partial "PW=[example-environment]"
    assert_stub_not_called docker "logs"
}

@test "configure-apps: the .env password is unquoted before use" {
    printf 'QBIT_PASSWORD="example-quoted"\n' > "$ENV_FILE"
    run "$DRIVER" eval 'discover_api_keys >/dev/null 2>&1; echo "PW=[$QBIT_PASSWORD]"'
    assert_output --partial "PW=[example-quoted]"
    assert_stub_not_called docker "logs"
}

@test "configure-apps: .env is resolved from the script, not the working directory" {
    # The old code read the bare relative path `.env`, so running from anywhere
    # but the repo root silently skipped this lookup and fell through to the
    # log scrape. Running from / is the cheapest way to prove it no longer does.
    printf 'QBIT_PASSWORD=example-anyway\n' > "$ENV_FILE"
    cd /
    run "$DRIVER" eval 'discover_api_keys >/dev/null 2>&1; echo "PW=[$QBIT_PASSWORD]"'
    assert_output --partial "PW=[example-anyway]"
}

@test "configure-apps: with no env and no .env the temp password is scraped from the logs" {
    echo 'A temporary password is provided for this session: abCD1234' > "$FIX/qbit-logs"
    run "$DRIVER" eval 'discover_api_keys >/dev/null 2>&1; echo "PW=[$QBIT_PASSWORD]"'
    assert_output --partial "PW=[abCD1234]"
    assert_stub_called docker "logs qbittorrent"
}

@test "configure-apps: the most recent temp password in the logs is the one used" {
    printf '%s\n%s\n' \
        'A temporary password is provided for this session: OLDpass1' \
        'A temporary password is provided for this session: NEWpass2' > "$FIX/qbit-logs"
    run "$DRIVER" eval 'discover_api_keys >/dev/null 2>&1; echo "PW=[$QBIT_PASSWORD]"'
    assert_output --partial "PW=[NEWpass2]"
}

@test "configure-apps: no password anywhere warns loudly instead of failing silently" {
    run "$DRIVER" discover_api_keys
    assert_output --partial "WARNING: Could not find qBittorrent password."
    assert_output --partial "Set QBIT_PASSWORD env var"
}

# -------------------------------------------------------------- print_summary

@test "configure-apps: the summary reports all three counters" {
    DRIVER_PRE='CONFIGURED=7; SKIPPED=3; FAILED=0' run "$DRIVER" print_summary
    assert_success
    assert_output --partial "Summary: 7 configured, 3 skipped, 0 failed"
}

@test "configure-apps: FAILED is not decorative — a failure makes the script exit non-zero" {
    DRIVER_PRE='FAILED=2' run "$DRIVER" print_summary
    assert_failure
    assert_output --partial "2 failed"
    assert_output --partial "Some steps failed."
}

@test "configure-apps: a clean run exits zero and says nothing about failures" {
    DRIVER_PRE='FAILED=0' run "$DRIVER" print_summary
    assert_success
    refute_output --partial "Some steps failed."
}

@test "configure-apps: the SABnzbd manual step appears only when SABnzbd is running" {
    run "$DRIVER" print_summary
    refute_output --partial "5. SABnzbd"
    DRIVER_PRE='SABNZBD_RUNNING=true' run "$DRIVER" print_summary
    assert_output --partial "5. SABnzbd: usenet provider credentials"
}

# ----------------------------------------------------------- the cookie file

@test "configure-apps: the session cookie is a private temp file, removed on exit" {
    # Observed from inside the run, after mktemp and before run_all: proving the
    # cleanup means proving the file existed first.
    export OBSERVED="$BATS_TEST_TMPDIR/observed"
    DRIVER_PRE='discover_api_keys() { ls "$TMPDIR" > "$OBSERVED"; }; run_all() { :; }' \
        run "$DRIVER" main --dry-run
    assert_success
    grep -q '^qbit_configure_cookie\.' "$OBSERVED"
    # ...and nothing is left behind.
    [ -z "$(ls -A "$TMPDIR")" ]
    # ...and the name is unpredictable, not the old fixed
    # /tmp/qbit_configure_cookie.txt that two concurrent runs shared.
    grep -qE '^qbit_configure_cookie\.[A-Za-z0-9]{6}$' "$OBSERVED"
}

# --------------------------------------------------------- the dry-run boundary

@test "configure-apps: a full --dry-run run reaches no mutating operation at all" {
    # THE test in this file. Every configure_* function has its own dry-run
    # early return; this drives all six through main and asserts the harness
    # never had to stop anything. A per-function assertion would pass even if
    # one function's gate were in the wrong place.
    echo sabnzbd >> "$FIX/running"
    printf 'QBIT_PASSWORD=whatever\n' > "$ENV_FILE"
    run "$DRIVER" main --dry-run
    assert_success
    assert_nothing_forbidden
    assert_output --partial "DRY RUN - no changes will be made"
    assert_output --partial "[dry-run] Would:"
}

@test "configure-apps: --dry-run touches nothing in qBittorrent, the arrs, Bazarr or Pi-hole" {
    printf 'QBIT_PASSWORD=whatever\n' > "$ENV_FILE"
    run "$DRIVER" main --dry-run
    assert_success
    # The named mutations, one per service, asserted on the argv actually used.
    assert_stub_not_called curl "createCategory"
    assert_stub_not_called curl "setPreferences"
    assert_stub_not_called curl "rootfolder"
    assert_stub_not_called curl "downloadclient"
    assert_stub_not_called docker "restart"
    assert_stub_not_called docker "pihole-FTL"
    assert_nothing_forbidden
}

@test "configure-apps: --dry-run still names every step it would have taken" {
    printf 'QBIT_PASSWORD=whatever\n' > "$ENV_FILE"
    run "$DRIVER" main --dry-run
    assert_output --partial "Would: Create category 'tv'"
    assert_output --partial "Would: Add root folder /data/media/tv"
    assert_output --partial "Would: Add root folder /data/media/movies"
    assert_output --partial "Would: Set Pi-hole upstream DNS"
}

@test "configure-apps: main reports failure when a dry run could not do its job" {
    # No password anywhere: qBittorrent counts a failure even in a dry run, and
    # that has to survive all the way out to main's exit status.
    run "$DRIVER" main --dry-run
    assert_failure
    assert_output --partial "no password available"
    assert_nothing_forbidden
}

@test "configure-apps: main stops at prerequisites and configures nothing" {
    echo unhealthy > "$FIX/gluetun-health"
    run "$DRIVER" main
    assert_failure
    assert_output --partial "Gluetun is 'unhealthy'"
    refute_output --partial "Discovering API keys"
    assert_nothing_forbidden
}

# ------------------------------------------------ configure_qbittorrent, for real
#
# The only place in this file that drives a configure_* function with DRY_RUN
# off. These endpoints are not on the denylist (they carry no -X POST), which is
# deliberate: the harness stops the operations a test must never perform, and
# qBittorrent's own API against a stub is not one of them.

# Set up the globals configure_qbittorrent reads and run it. The cookie file is
# created first so its removal at the end is observable.
run_qbit() {
    COOKIE="$BATS_TEST_TMPDIR/cookie"
    export COOKIE
    : > "$COOKIE"
    DRIVER_PRE='NAS_IP=10.0.0.1; QBIT_PASSWORD=pw; QBIT_COOKIE="$COOKIE"' \
        run "$DRIVER" configure_qbittorrent
}

@test "configure-apps: a successful qBittorrent login proceeds to configure it" {
    run_qbit
    assert_output --partial "created category 'tv'"
    assert_output --partial "created category 'movies'"
    refute_output --partial "authentication failed"
}

@test "configure-apps: a rejected qBittorrent login is reported and stops the service" {
    printf 'Fails.\n200\n' > "$FIX/qbit-auth"
    run_qbit
    assert_output --partial "authentication failed (check QBIT_USERNAME/QBIT_PASSWORD)"
    assert_stub_not_called curl "createCategory"
    assert_stub_not_called curl "setPreferences"
}

@test "configure-apps: each category is created at its own save path" {
    run_qbit
    assert_stub_called curl "category=tv"
    assert_stub_called curl "savePath=/data/torrents/tv"
    assert_stub_called curl "category=movies"
    assert_stub_called curl "savePath=/data/torrents/movies"
}

@test "configure-apps: a category that already exists is a skip, not a failure" {
    echo 409 > "$FIX/qbit-category-code"
    run_qbit
    assert_output --partial "category 'tv' (already configured)"
    refute_output --partial "✗ qBittorrent: create category"
}

@test "configure-apps: any other category status is a counted failure naming the code" {
    echo 403 > "$FIX/qbit-category-code"
    DRIVER_PRE='NAS_IP=10.0.0.1; QBIT_PASSWORD=pw; QBIT_COOKIE=$(mktemp)' \
        run "$DRIVER" eval 'configure_qbittorrent; echo "FAILED=$FAILED"'
    assert_output --partial "create category 'tv' (HTTP 403)"
    assert_output --partial "FAILED=2"
}

@test "configure-apps: preferences already at the target values are left alone" {
    # Kills the whole block of !=-comparisons at once: flip any one of them and
    # an already-correct client gets its preferences rewritten on every run.
    run_qbit
    assert_output --partial "qBittorrent: preferences (already configured)"
    assert_stub_not_called curl "setPreferences"
}

@test "configure-apps: one wrong preference is enough to rewrite the whole set" {
    # Every field in the block is load bearing, so wrecking any single one must
    # trigger the write. Looping over all eleven is what makes flipping one
    # comparison from != to == a failing test rather than a survivor.
    #
    # The wrong value is named per field rather than shared: the flags are
    # checked for truthiness and the numbers for equality, so one sentinel
    # cannot break both — a truthy string sails straight through `if not
    # p.get(...)` and the test would silently cover only half the block.
    cp "$FIX/qbit-prefs.json" "$FIX/prefs-correct.json"
    local pair field wrong
    for pair in auto_tmm_enabled=false upnp=true limit_utp_rate=false \
                limit_lan_peers=false encryption=0 \
                max_inactive_seeding_time_enabled=false \
                max_inactive_seeding_time=31 max_ratio_act=1 \
                max_active_downloads=6 max_active_torrents=11 \
                max_active_uploads=6; do
        field="${pair%%=*}"
        wrong="${pair#*=}"
        python3 -c "
import json, sys
p = json.load(open(sys.argv[1]))
p[sys.argv[3]] = json.loads(sys.argv[4])
json.dump(p, open(sys.argv[2], 'w'))
" "$FIX/prefs-correct.json" "$FIX/qbit-prefs.json" "$field" "$wrong"
        : > "$STUB_LOG"
        run_qbit
        # Named in the failure message, or eleven identical failures tell you
        # nothing about which field stopped being checked.
        [[ "$output" == *"set preferences"* ]] || {
            echo "a wrong $field did not trigger a preferences write"
            echo "$output"
            return 1
        }
        assert_stub_called curl "setPreferences"
    done
}

@test "configure-apps: a rejected preferences write is a counted failure" {
    python3 -c "
import json
p = json.load(open('$FIX/qbit-prefs.json'))
p['encryption'] = 0
json.dump(p, open('$FIX/qbit-prefs.json', 'w'))
"
    echo 500 > "$FIX/qbit-setprefs-code"
    DRIVER_PRE='NAS_IP=10.0.0.1; QBIT_PASSWORD=pw; QBIT_COOKIE=$(mktemp)' \
        run "$DRIVER" eval 'configure_qbittorrent; echo "FAILED=$FAILED"'
    assert_output --partial "set preferences (HTTP 500)"
    assert_output --partial "FAILED=1"
}

@test "configure-apps: the session cookie is removed once qBittorrent is configured" {
    run_qbit
    assert_success
    [ ! -e "$COOKIE" ]
}
