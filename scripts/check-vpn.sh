#!/bin/bash
#
# Verify the VPN end to end:
#   1. DNS resolves inside gluetun.
#   2. gluetun exits to the internet from a different IP than the host's own
#      connection, measured from a container on the ordinary bridge (sonarr).
#   3. Every service bound into gluetun's network namespace exits from
#      gluetun's IP. The list comes from the compose files: every service with
#      network_mode "service:gluetun" (or "container:gluetun").
#   4. When gluetun cannot reach the internet, why: its log says whether it is
#      cycling through servers that never answer (an expired subscription, a
#      revoked key or blocked UDP: WireGuard cannot tell them apart), stuck on
#      one server, or failing along with the host's own connection.
#
# Usage: ./scripts/check-vpn.sh                  run every check
#        ./scripts/check-vpn.sh --list-tunnelled print the services it would check
#
# Exit 0 means every check ran and passed. Anything else is a problem, and the
# FAIL lines say what. Cron relies on that: it pings the Uptime Kuma push
# monitor only on exit 0 (docs/UTILITIES.md), so a check that could not run,
# or a service whose egress could not be measured, is a failure, never a skip.
#
# Environment overrides:
#   GLUETUN_CONTAINER  the VPN container (default: gluetun)
#   HOST_PROBE         a container on the plain bridge, used to measure the
#                      host's own egress (default: sonarr)
#   ARR_STACK_DIR      directory holding the compose files. By default it is
#                      read from gluetun's compose labels, so the script also
#                      works when piped in (`... | ssh nas bash -s`), then
#                      falls back to the checkout this script lives in.
#   DNS_TEST_NAME      name resolved inside gluetun (default: cloudflare.com)
#   VPN_NO_ANSWER_MINUTES  how long gluetun must have gone without a server
#                      answering before the check blames the account rather
#                      than a passing outage (default: 5)
#   VPN_CHECK_PUSH_URL the Uptime Kuma push URL, without its query. When set
#                      here or in the stack's .env, a failing run pushes
#                      status=down with the reason, so Kuma's down notice
#                      names the cause. The success push stays in cron
#                      (docs/UTILITIES.md).
#
# It only reads: docker inspect and docker logs, and docker exec of
# getent/nslookup and of curl/wget against public IP-echo services. It
# restarts and changes nothing. The one thing it sends is that down push.
#
# ⚠️  This script was generated with LLM assistance and human-reviewed.
#     Read and understand it before running. Do not execute scripts you
#     don't understand on your system. It only inspects and reports —
#     it changes nothing.
#

# No `set -e`: a failed probe is a result to report, not a reason to stop
# before the remaining checks have run.
set -uo pipefail

GLUETUN="${GLUETUN_CONTAINER:-gluetun}"
HOST_PROBE="${HOST_PROBE:-sonarr}"
DNS_TEST_NAME="${DNS_TEST_NAME:-cloudflare.com}"
PROBE_TIMEOUT=10
NO_ANSWER_MINUTES="${VPN_NO_ANSWER_MINUTES:-5}"
# gluetun retries every ~6 s while no server answers. A longer silence than
# this between two restarts means the earlier run of them had ended.
RUN_GAP=180

# IPv4-only answers, and only IPv4 is accepted from them. If one side of a
# comparison came back IPv6 and the other IPv4 they would always differ, and
# a gluetun that was leaking the host's IPv4 would pass as "not the host".
IP_ECHO_URLS="https://api.ipify.org https://ipv4.icanhazip.com https://ipinfo.io/ip"

FAILURES=0
FIRST_FAIL=""
DIAG=""
ok()   { printf '  OK    %s\n' "$*"; }
fail() {
    printf '  FAIL  %s\n' "$*"
    FAILURES=$((FAILURES + 1))
    [ -n "$FIRST_FAIL" ] || FIRST_FAIL="$*"
}

# One line, whitespace squeezed: docker's multi-line errors stay readable.
oneline() { printf '%s' "$*" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'; }

is_ipv4() {
    local re='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
    [[ $1 =~ $re ]]
}

# The host's real IP goes to logs; keep only enough of it to recognise.
mask() { printf '%s' "$1" | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+\.[0-9]+$/\1.x.x/'; }

# A wedged container can hang `docker exec` itself, past any timeout given to
# the command inside it, and a hung cron job never reports anything.
dexec() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 45 docker exec "$@"
    else
        docker exec "$@"
    fi
}

dlogs() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 docker logs "$@"
    else
        docker logs "$@"
    fi
}

# ---------------------------------------------------------------------------
# Which services are tunnelled: read from how the compose files bind them.
# ---------------------------------------------------------------------------

# Prints the container name (container_name, else the service key) of every
# service whose network_mode is service:gluetun or container:gluetun. Reads
# the services: block of each file, whatever its indent width.
tunnelled_from_compose() {
    awk -v g="$GLUETUN" '
        function flush() {
            if (svc != "" && bound) print (cname != "" ? cname : svc)
            svc = ""; cname = ""; bound = 0
        }
        FNR == 1 { flush(); in_svcs = 0 }
        /^[^[:space:]#]/ { flush(); in_svcs = ($0 ~ /^services:[[:space:]]*(#.*)?$/); sindent = -1; next }
        !in_svcs || /^[[:space:]]*(#.*)?$/ { next }
        {
            match($0, /^[[:space:]]*/); ind = RLENGTH
            line = substr($0, ind + 1)
            key = line; sub(/:.*/, "", key)
            val = line; sub(/^[^:]*:[[:space:]]*/, "", val)
            sub(/[[:space:]]+#.*$/, "", val); sub(/[[:space:]]+$/, "", val)
            gsub(/^["\047]|["\047]$/, "", val)
            if (sindent < 0) sindent = ind
            if (ind == sindent) { flush(); svc = key; pindent = -1; next }
            if (svc == "") next
            if (pindent < 0) pindent = ind
            if (ind != pindent) next          # a key of the service itself
            if (key == "container_name") cname = val
            if (key == "network_mode" && (val == "service:" g || val == "container:" g)) bound = 1
        }
        END { flush() }
    ' "$@"
}

# Sets STACK_DIR to the directory holding the compose files, or "".
resolve_stack_dir() {
    local d src
    STACK_DIR=""
    if [ -n "${ARR_STACK_DIR:-}" ]; then
        STACK_DIR="$ARR_STACK_DIR"
        return
    fi
    # Where gluetun was actually deployed from: compose stamps it on the
    # container, and it is the only source available when piped to `bash -s`.
    d=$(docker inspect --type container \
        -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$GLUETUN" 2>/dev/null)
    if [ -n "$d" ] && [ -d "$d" ]; then
        STACK_DIR="$d"
        return
    fi
    src="${BASH_SOURCE[0]:-}"
    if [ -n "$src" ] && [ -f "$src" ]; then
        STACK_DIR="$(cd "$(dirname "$src")/.." && pwd)"
    fi
}

# Sets TUNNELLED (space-separated), TUNNELLED_COUNT and STACK_DIR, or sets
# LOAD_ERR and returns 1.
load_tunnelled() {
    local f files=()
    TUNNELLED="" TUNNELLED_COUNT=0 LOAD_ERR=""
    resolve_stack_dir
    if [ -z "$STACK_DIR" ] || [ ! -d "$STACK_DIR" ]; then
        LOAD_ERR="cannot find the stack's compose files (set ARR_STACK_DIR)"
        return 1
    fi
    for f in "$STACK_DIR"/docker-compose*.yml; do
        [ -f "$f" ] && files+=("$f")
    done
    if [ ${#files[@]} -eq 0 ]; then
        LOAD_ERR="no docker-compose*.yml in $STACK_DIR"
        return 1
    fi
    TUNNELLED=$(tunnelled_from_compose "${files[@]}" | sort -u | tr '\n' ' ')
    TUNNELLED="${TUNNELLED% }"
    # An empty list would make "every tunnelled service is fine" true of
    # nothing. A parser that stops matching must fail loudly, not pass.
    if [ -z "$TUNNELLED" ]; then
        LOAD_ERR="no service in $STACK_DIR/docker-compose*.yml is bound to $GLUETUN's network namespace"
        return 1
    fi
    for f in $TUNNELLED; do TUNNELLED_COUNT=$((TUNNELLED_COUNT + 1)); done
}

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

# Sets EGRESS to the public IPv4 CONTAINER exits from, or sets EGRESS_ERR and
# returns 1.
measure_egress() {
    local c="$1" state tool url out rc last=""
    EGRESS="" EGRESS_ERR=""
    if ! state=$(docker inspect --type container -f '{{.State.Status}}' "$c" 2>&1); then
        EGRESS_ERR=$(oneline "$state")
        return 1
    fi
    if [ "$state" != running ]; then
        EGRESS_ERR="container is $state"
        return 1
    fi
    # curl where the image has it; gluetun only has busybox wget.
    tool=$(dexec "$c" sh -c 'command -v curl || command -v wget' 2>&1)
    case "$tool" in
        */curl) tool=curl ;;
        */wget) tool=wget ;;
        *) EGRESS_ERR="no curl or wget found in it${tool:+ ($(oneline "$tool"))}"; return 1 ;;
    esac
    for url in $IP_ECHO_URLS; do
        if [ "$tool" = curl ]; then
            out=$(dexec "$c" curl -fsS -m "$PROBE_TIMEOUT" "$url" 2>&1)
        else
            out=$(dexec "$c" wget -qO- -T "$PROBE_TIMEOUT" "$url" 2>&1)
        fi
        rc=$?
        out=$(printf '%s' "$out" | tr -d '[:space:]')
        if [ $rc -eq 0 ] && is_ipv4 "$out"; then
            EGRESS="$out"
            return 0
        fi
        last="$url -> exit $rc${out:+: $(printf '%s' "$out" | cut -c1-80)}"
    done
    EGRESS_ERR="no IP-echo service answered (last: $last)"
    return 1
}

# Prints the addresses NAME resolves to inside CONTAINER; returns 1 if none.
resolve_in() {
    local c="$1" name="$2" out
    if out=$(dexec "$c" getent hosts "$name" 2>&1) && [ -n "$out" ]; then
        printf '%s' "$out" | awk '{print $1}' | tr '\n' ' '
        return 0
    fi
    # No getent: busybox nslookup. Its exit status is unreliable across
    # versions, so require an address after the "Name:" line.
    out=$(dexec "$c" nslookup "$name" 2>&1)
    out=$(printf '%s\n' "$out" | awk '/^Name:/ {n=1; next} n && /^Address/ {print $NF}' | tr '\n' ' ')
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Why gluetun has no internet: its own log
# ---------------------------------------------------------------------------

# Reads `docker logs -t` of gluetun on stdin and prints the run of VPN
# restarts still going on at NOW, or nothing if there is none, as
#   RESTARTS START LAST SERVERS FIRST_SERVER TRUNCATED
# A run is gluetun's "restarting VPN because it failed to pass the
# healthcheck" repeating with no gap over GAP seconds, and no "Public IP
# address is" between, which gluetun logs only once a server has answered.
# Each restart counts against the server it was on: the last "Connecting to"
# before it. TRUNCATED is 1 when nothing older than the run survives in the
# log, so it may have started earlier. Timestamps are docker's, always UTC.
restart_run() {
    awk -v now="$1" -v gap="$RUN_GAP" '
        function epoch(ts,   y, m, d, era, yoe, doy, doe) {
            y = substr(ts, 1, 4) + 0; m = substr(ts, 6, 2) + 0; d = substr(ts, 9, 2) + 0
            if (m <= 2) y--
            era = int(y / 400); yoe = y - era * 400
            doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
            doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
            return (era * 146097 + doe - 719468) * 86400 \
                + substr(ts, 12, 2) * 3600 + substr(ts, 15, 2) * 60 + substr(ts, 18, 2)
        }
        $1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { next }
        { t = epoch($1) }
        t > now { exit }
        /\[ip getter\] Public IP address is / { events++; n = 0; next }
        / Running version / { events++; next }
        /\[wireguard\] Connecting to / {
            srv = $0; sub(/.*Connecting to /, "", srv); sub(/[ \r].*/, "", srv); next
        }
        /\[vpn\] restarting VPN because / {
            if (n == 0 || t - last > gap) {
                n = 0; start = t; nsrv = 0; first = ""; split("", seen)
                trunc = (events == 0)
            }
            events++; n++; last = t
            if (srv != "" && !(srv in seen)) { seen[srv] = 1; nsrv++; if (first == "") first = srv }
        }
        END {
            if (n > 0 && now - last <= gap)
                print n, start, last, nsrv, (first == "" ? "-" : first), (trunc ? 1 : 0)
        }
    '
}

human_duration() {
    if [ "$1" -lt 60 ]; then echo "under a minute"
    elif [ "$1" -lt 5400 ]; then echo "$(($1 / 60)) min"
    elif [ "$1" -lt 172800 ]; then echo "$((($1 + 1800) / 3600)) h"
    else echo "$((($1 + 43200) / 86400)) days"
    fi
}

thousands() {
    awk -v n="$1" 'BEGIN { s = n ""; o = ""
        while (length(s) > 3) { o = "," substr(s, length(s) - 2) o; s = substr(s, 1, length(s) - 3) }
        print s o }'
}

# Sets VPN_NAME and ACCOUNT_PAGE from the provider gluetun is running with.
# The template prints that one variable; the private key never leaves docker.
vpn_account() {
    local p
    p=$(docker inspect --type container -f \
        '{{range .Config.Env}}{{$kv := split . "="}}{{if eq (index $kv 0) "VPN_SERVICE_PROVIDER"}}{{index $kv 1}}{{end}}{{end}}' \
        "$GLUETUN" 2>/dev/null)
    ACCOUNT_PAGE="the provider's website"
    case "$p" in
        surfshark) VPN_NAME=Surfshark;    ACCOUNT_PAGE=my.surfshark.com ;;
        mullvad)   VPN_NAME=Mullvad;      ACCOUNT_PAGE=mullvad.net/account ;;
        nordvpn)   VPN_NAME=NordVPN;      ACCOUNT_PAGE=my.nordaccount.com ;;
        protonvpn) VPN_NAME="Proton VPN"; ACCOUNT_PAGE=account.protonvpn.com ;;
        "")        VPN_NAME=VPN ;;
        *)         VPN_NAME="$p" ;;
    esac
}

# Sets DIAG to the likeliest cause when gluetun has no internet, from what
# the host probe saw and gluetun's log. Leaves it empty when neither says.
diagnose() {
    local now out n start last nsrv first trunc secs dur port tries servers
    DIAG=""
    # The host cannot get out either, so no VPN server could answer. Without
    # DNS it fails the same way, and Pi-hole resolves for both.
    case "$HOST_ERR" in
        "no IP-echo service answered"*)
            DIAG="The NAS's own connection is failing too ($HOST_PROBE reached no IP-echo service), so this is not the VPN: check the internet connection and DNS (Pi-hole) first"
            return ;;
    esac
    now=$(date +%s)
    out=$(dlogs -t "$GLUETUN" 2>&1 | restart_run "$now")
    [ -n "$out" ] || return 0
    read -r n start last nsrv first trunc <<< "$out"
    secs=$((now - start))
    dur=$(human_duration "$secs")
    [ "$trunc" = 1 ] && dur="at least $dur"
    tries="$(thousands "$n") attempts"
    [ "$n" -eq 1 ] && tries="1 attempt"
    servers="$nsrv servers"
    [ "$nsrv" -eq 1 ] && servers="1 server"
    port="${first##*:}"
    vpn_account
    if [ "$nsrv" -eq 0 ]; then
        # Not WireGuard, or a log without its "Connecting to" lines.
        DIAG="No VPN server has passed gluetun's health check for $dur ($tries). If it goes on, check the $VPN_NAME subscription ($ACCOUNT_PAGE) first"
    elif [ "$secs" -lt $((NO_ANSWER_MINUTES * 60)) ]; then
        DIAG="The VPN has not connected for $dur ($tries across $servers, none answered). Too soon to rule out a passing outage; if it lasts, check the $VPN_NAME subscription ($ACCOUNT_PAGE) first, then outbound UDP $port"
    elif [ "$nsrv" -eq 1 ]; then
        DIAG="VPN server $first has not answered for $dur ($tries) and gluetun has tried no other. If the server selection allows only that one, widen it (SERVER_COUNTRIES, SERVER_CITIES, SERVER_HOSTNAMES); if not, check the $VPN_NAME subscription ($ACCOUNT_PAGE)"
    else
        DIAG="No VPN server has answered for $dur across $servers ($tries). Most likely the $VPN_NAME subscription has expired or the WireGuard key was revoked: check $ACCOUNT_PAGE. If the account is active, check that outbound UDP $port is not blocked. WireGuard never says why, so the three look the same from here"
    fi
}

# Pushes status=down with the reason to Uptime Kuma, when VPN_CHECK_PUSH_URL
# is set in the environment or the stack's .env. Kuma puts the message in its
# down notice, so the notice says what is wrong instead of "No heartbeat".
# shellcheck disable=SC2329  # called from the EXIT trap
report_down() {
    local url="${VPN_CHECK_PUSH_URL:-}" msg out
    if [ -z "$url" ]; then
        [ -n "${STACK_DIR:-}" ] || resolve_stack_dir
        if [ -n "$STACK_DIR" ] && [ -f "$STACK_DIR/.env" ]; then
            url=$(sed -n 's/^VPN_CHECK_PUSH_URL=//p' "$STACK_DIR/.env" | tail -n 1 | tr -d "\"'")
        fi
    fi
    [ -n "$url" ] || return 0
    # The cron line's URL carries ?status=up&msg=OK; a second status would win.
    url="${url%%\?*}"
    msg="${DIAG:-${FIRST_FAIL:-check-vpn.sh failed}}"
    # Kuma's notice template adds ". " and the monitor's description after it.
    msg="${msg%.}"
    if out=$(curl -fsS -m 10 -G --data-urlencode status=down --data-urlencode "msg=$msg" "$url" 2>&1); then
        echo "  Reported down to Uptime Kuma"
    else
        echo "  NOTE  could not report to Uptime Kuma: $(oneline "$out" | cut -c1-120)"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-}" in
    -h|--help)
        sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0" 2>/dev/null || echo "see the header of scripts/check-vpn.sh"
        exit 0 ;;
    --list-tunnelled)
        if ! load_tunnelled; then echo "ERROR: $LOAD_ERR"; exit 2; fi
        for svc in $TUNNELLED; do echo "$svc"; done
        exit 0 ;;
    "") ;;
    *) echo "Unknown argument: $1 (try --help)"; exit 2 ;;
esac

# Every failing exit from here on reports the reason to Kuma, if configured.
trap 'rc=$?; [ "$rc" -eq 0 ] || report_down; exit "$rc"' EXIT

if ! command -v docker >/dev/null 2>&1; then
    FIRST_FAIL="docker not found on PATH, so nothing was checked"
    echo "FAIL: $FIRST_FAIL"
    exit 2
fi

echo "VPN check — $(date '+%Y-%m-%d %H:%M:%S')"

# gluetun must be there and running; every other check goes through it.
if ! g_state=$(docker inspect --type container -f '{{.State.Status}} {{.Id}}' "$GLUETUN" 2>&1); then
    fail "cannot inspect $GLUETUN: $(oneline "$g_state")"
    echo "FAIL: nothing else can be checked without $GLUETUN"
    exit 1
fi
if [ "${g_state%% *}" != running ]; then
    fail "$GLUETUN is ${g_state%% *}, not running"
    echo "FAIL: nothing else can be checked without $GLUETUN"
    exit 1
fi
g_id="${g_state#* }"

if ! load_tunnelled; then
    fail "$LOAD_ERR"
    echo "FAIL: no list of tunnelled services, so none can be verified"
    exit 1
fi
echo "  gluetun ${g_id:0:12}; tunnelled services from $STACK_DIR: $TUNNELLED"

# 1. DNS inside gluetun. gluetun's own health check deliberately avoids DNS
# (docker-compose.arr-stack.yml), so this is the only thing watching it.
if addrs=$(resolve_in "$GLUETUN" "$DNS_TEST_NAME"); then
    ok "DNS inside $GLUETUN: $DNS_TEST_NAME -> ${addrs% }"
else
    fail "DNS inside $GLUETUN: $DNS_TEST_NAME did not resolve"
fi

# 2. gluetun versus the host's own connection. If gluetun exits as the host,
# the tunnel is not carrying its traffic, and nothing behind it is private.
G_IP="" H_IP="" HOST_ERR=""
if measure_egress "$GLUETUN"; then
    G_IP="$EGRESS"
else
    fail "cannot measure $GLUETUN's egress: $EGRESS_ERR"
fi

# The probe has to be off the VPN, or "host" and "VPN" are the same thing and
# a real leak would read as a pass.
p_mode=$(docker inspect --type container -f '{{.HostConfig.NetworkMode}}' "$HOST_PROBE" 2>/dev/null)
case "$p_mode" in
    container:*)
        fail "HOST_PROBE=$HOST_PROBE shares another container's network namespace; it cannot measure the host's own egress" ;;
    *)
        if measure_egress "$HOST_PROBE"; then
            H_IP="$EGRESS"
        else
            HOST_ERR="$EGRESS_ERR"
            fail "cannot measure the host's own egress via $HOST_PROBE: $EGRESS_ERR (without it a leak is indistinguishable from the VPN)"
        fi ;;
esac

if [ -n "$G_IP" ] && [ -n "$H_IP" ]; then
    if [ "$G_IP" = "$H_IP" ]; then
        fail "LEAK: $GLUETUN exits as the host's own IP ($(mask "$H_IP")) — the tunnel is not carrying its traffic"
    else
        ok "$GLUETUN exits as $G_IP; the host exits as $(mask "$H_IP") (via $HOST_PROBE)"
    fi
fi

# 4. gluetun has no way out: say why, before the tunnelled services' lines,
# which all fail the same way and say nothing about the cause.
if [ -z "$G_IP" ]; then
    diagnose
    [ -z "$DIAG" ] || fail "$DIAG"
fi

# 3. Each tunnelled service must exit exactly where gluetun does.
for svc in $TUNNELLED; do
    if ! measure_egress "$svc"; then
        fail "$svc: cannot measure its egress: $EGRESS_ERR"
    elif [ -n "$H_IP" ] && [ "$EGRESS" = "$H_IP" ]; then
        fail "LEAK: $svc exits as the host's own IP ($(mask "$H_IP")), not through $GLUETUN"
    elif [ -z "$G_IP" ]; then
        fail "$svc exits as $EGRESS, but $GLUETUN's own egress is unknown, so it cannot be compared"
    elif [ "$EGRESS" = "$G_IP" ]; then
        ok "$svc exits through $GLUETUN ($G_IP)"
    else
        fail "$svc exits as $EGRESS, not $GLUETUN's $G_IP (if gluetun reconnected mid-check, re-run)"
    fi
done

if [ "$FAILURES" -gt 0 ]; then
    echo "FAIL: $FAILURES problem(s) — see the FAIL lines above"
    exit 1
fi
echo "PASS: VPN verified — DNS resolves, $GLUETUN is not exiting as the host, and all $TUNNELLED_COUNT tunnelled services exit through it"
exit 0
