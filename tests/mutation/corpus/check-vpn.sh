# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/check-vpn.sh.
#
# Safe to run: tests/check-vpn.bats drives the script with the stub harness on
# PATH, so every `docker exec` is answered from a tmpdir of fake egress IPs and
# nothing reaches a container.

mutation check-vpn-compares-the-lan-address \
  --file scripts/check-vpn.sh \
  --bats tests/check-vpn.bats \
  --test "check-vpn: DEFECT - Gluetun egressing on the household WAN IP is a leak" \
  --why "restores the comparison this script shipped with: Gluetun's egress against the NAS's own LAN address from hostname -I. Every IP here comes from ifconfig.me, which reports the PUBLIC source address it sees, so behind NAT it can never equal a 192.168.x.x address. The headline leak check becomes incapable of firing, and a cron entry that has never once alerted looks exactly like a cron entry that has never needed to" \
  --apply 'sed -i "s@^WAN_IP=\$(egress_ip \"\$BRIDGE_REF\") || WAN_IP=\"\"@WAN_IP=\$(hostname -I 2>/dev/null | awk \x27{print \$1}\x27)@" "$F"'

mutation check-vpn-skip-reads-as-ok \
  --file scripts/check-vpn.sh \
  --bats tests/check-vpn.bats \
  --test "check-vpn: a missing WAN reference SKIPS that comparison, loudly" \
  --why "prints the OK line for a comparison that was never made. The reference container being down is common and transient; a run that says the VPN is active without having checked is worse than one that says nothing, because it is the line a human greps for" \
  --apply 'sed -i "s@      SKIPPED: Gluetun-vs-WAN comparison (is \$BRIDGE_REF running?)@OK: VPN is active@" "$F"'

mutation check-vpn-first-leak-breaks-the-loop \
  --file scripts/check-vpn.sh \
  --bats tests/check-vpn.bats \
  --test "check-vpn: a leak does not stop the remaining services being checked" \
  --why "stops at the first leaking dependent. The exit status is identical, so cron sees no difference at all, while the report silently covers one service instead of four - and the ones it stopped short of are exactly the ones nobody then goes looking at" \
  --apply 'sed -i "s@^        leaked=1\$@        leaked=1; break@" "$F"'

mutation check-vpn-leaked-flag-never-read \
  --file scripts/check-vpn.sh \
  --bats tests/check-vpn.bats \
  --test "check-vpn: one leaking dependent fails the run and names it" \
  --why "compares the accumulator against a value it can never hold, so a detected leak is printed and then exits 0. The script still says LEAK DETECTED in its output; the only consumer that matters, a \`|| notify\` wrapper in cron, never fires" \
  --apply 'sed -i "s@if \[\[ \"\$leaked\" -eq 1 \]\]@if [[ \"\$leaked\" -eq 2 ]]@" "$F"'

mutation check-vpn-empty-answer-is-a-pass \
  --file scripts/check-vpn.sh \
  --bats tests/check-vpn.bats \
  --test "check-vpn: an empty answer from Gluetun is an error, not a pass" \
  --why "drops the empty-response guard. An empty VPN_IP then compares unequal to everything, so the WAN check passes and every dependent is reported as leaking - a wall of false positives produced by one unanswered request, and the opposite of the quiet failure the other mutations cause" \
  --apply 'sed -i "/^if \[\[ -z \"\$VPN_IP\" \]\]; then\$/,/^fi\$/d" "$F"'

mutation check-vpn-down-dependent-is-a-leak \
  --file scripts/check-vpn.sh \
  --bats tests/check-vpn.bats \
  --test "check-vpn: PINNED - a dependent that is down warns but does not fail" \
  --why "treats an unreachable container as a leak. This runs from cron every five minutes; a container that is not running is not leaking, and alerting on it is how a monitor gets muted" \
  --apply 'sed -i "s@^        continue\$@        leaked=1; continue@" "$F"'

mutation check-vpn-tunneled-list-drifts-from-the-e2e \
  --file scripts/check-vpn.sh \
  --bats tests/check-vpn.bats \
  --test "check-vpn: the tunneled list matches the e2e suite's" \
  --why "drops a service from the tunneled list. Nothing in this script can notice - the loop simply checks three services instead of four and reports OK - and the dropped one keeps leaking. The header says the two implementations must be kept in sync; this is the entry that proves the assertion, not the prose, is what keeps them that way" \
  --apply 'sed -i "s@^TUNNELED_SERVICES=(qbittorrent prowlarr sabnzbd flaresolverr)\$@TUNNELED_SERVICES=(qbittorrent prowlarr sabnzbd)@" "$F"'

mutation check-vpn-reference-is-itself-tunneled \
  --file scripts/check-vpn.sh \
  --bats tests/check-vpn.bats \
  --test "check-vpn: the WAN reference container is one the e2e spec calls bridge-only" \
  --why "points the WAN reference at a container that is behind Gluetun. The headline check then compares the VPN against itself: the two IPs are always equal, so every single run reports a leak - or, had the comparison been written the other way round, none ever would. Either way the reference stops being a reference and nothing in the script's own output says so" \
  --apply 'sed -i "s@^BRIDGE_REF=\"\${BRIDGE_REF:-sonarr}\"\$@BRIDGE_REF=\"\${BRIDGE_REF:-qbittorrent}\"@" "$F"'

# Two tests, one operator: the fallback test is the one named here, and
# 'a working curl is not followed by wget' pins the same `||` from the other
# side - with `&&` a successful curl is followed by wget, so the egress IP is
# two answers concatenated and the comparisons below are made against both.
mutation check-vpn-wget-fallback-becomes-a-requirement \
  --file scripts/check-vpn.sh \
  --bats tests/check-vpn.bats \
  --test "check-vpn: the wget fallback still answers when curl is not installed" \
  --why "turns the wget fallback into a second requirement. Gluetun has no curl, only wget - the comment above egress_ip says so and that is the only reason it can read an IP from the VPN side at all - so with && the fallback runs only after curl has already succeeded, every run ends at 'Could not reach an IP-check service through Gluetun', and the bridge-only containers keep answering normally, which makes the whole thing look like one unreachable container rather than a broken check" \
  --apply 'perl -pi -e '"'"'s/\|\| wget -qO-/&& wget -qO-/'"'"' "$F"'
