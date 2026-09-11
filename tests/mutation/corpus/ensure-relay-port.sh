# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/ensure-tailscale-relay-port.sh.
#
# Safe to run: tests/ensure-relay-port.bats drives the script with the stub
# harness on PATH, and `tailscale set` is on the denylist, so a mutant that
# decides to re-apply trips forbid() instead of reaching node 1. Node 1 carries
# SSH and the UGOS admin UI on its own subnet route.

mutation relay-port-colon-whitespace-narrowed \
  --file scripts/ensure-tailscale-relay-port.sh \
  --bats tests/ensure-relay-port.bats \
  --test "ensure-relay-port: space BEFORE the colon is recognised" \
  --why "requires the colon to sit flush against the key, which is what the pattern did until 2026-09-01 while a comment above it claimed robustness to extra whitespace. A pref that is already correct then reads as missing forever: the script re-applies on every timer tick and the OK branch becomes unreachable, all while the port is in fact right" \
  --apply 'sed -i "s@grep -oE .\"RelayServerPort\"\[\[:space:\]\]\*:@grep -oE '"'"'\"RelayServerPort\":@" "$F"'

mutation relay-port-quoted-value-rejected \
  --file scripts/ensure-tailscale-relay-port.sh \
  --bats tests/ensure-relay-port.bats \
  --test "ensure-relay-port: a quoted value is recognised" \
  --why "stops accepting a JSON-string port. Same silent-forever failure as the whitespace one, and the one most likely to arrive on its own: nothing in this repo controls how tailscale types that field in debug output" \
  --apply 'sed -i "s@\[\[:space:\]\]\*\"?\[0-9\]+@[[:space:]]*[0-9]+@" "$F"'

mutation relay-port-key-match-unanchored \
  --file scripts/ensure-tailscale-relay-port.sh \
  --bats tests/ensure-relay-port.bats \
  --test "ensure-relay-port: a different key ENDING in RelayServerPort is not read as this one" \
  --why "drops the opening quote from the key, so any longer key ending in RelayServerPort matches. This is the only failure direction that is genuinely dangerous rather than merely wasteful: the script reports OK while the pref it was supposed to check is untouched, and the peer-relay port stays wrong until someone notices Android clients failing" \
  --apply 'sed -i "s@grep -oE .\"RelayServerPort\"@grep -oE '"'"'RelayServerPort\"@" "$F"'

mutation relay-port-running-check-inverted \
  --file scripts/ensure-tailscale-relay-port.sh \
  --bats tests/ensure-relay-port.bats \
  --test "ensure-relay-port: a stopped container is skipped, not an error" \
  --why "inverts the running check, so the script interrogates a container precisely when it is down and skips when it is up. The exit status is 0 in both directions, so nothing in the timer's journal would show it" \
  --apply 'sed -i "s@^if ! docker inspect@if docker inspect@" "$F"'

mutation relay-port-absent-container-is-a-failure \
  --file scripts/ensure-tailscale-relay-port.sh \
  --bats tests/ensure-relay-port.bats \
  --test "ensure-relay-port: a missing container is skipped, not an error" \
  --why "turns a not-yet-running container into a unit failure. This runs on a systemd timer during boot, when the container legitimately is not up yet; a non-zero exit there puts the unit in failed state and buries the real failures it is supposed to report" \
  --apply 'sed -i "/tailscale container not running/{n;s@^  exit 0@  exit 1@}" "$F"'

mutation relay-port-reads-the-exit-node \
  --file scripts/ensure-tailscale-relay-port.sh \
  --bats tests/ensure-relay-port.bats \
  --test "ensure-relay-port: it only ever asks for node 1, never the exit node" \
  --why "reads prefs from the second Tailscale node. There are two on this NAS and only one of them is the one this pref belongs to; asking the wrong one returns a shape that parses fine and is about the wrong container entirely" \
  --apply 'sed -i "s@docker exec tailscale tailscale debug prefs@docker exec tailscale-exit tailscale debug prefs@" "$F"'

mutation relay-port-failed-apply-reads-as-success \
  --file scripts/ensure-tailscale-relay-port.sh \
  --bats tests/ensure-relay-port.bats \
  --test "ensure-relay-port: a failed re-apply exits 1 and reports it" \
  --why "exits 0 after a failed re-apply. The header of this script documents exit 1 as its one failure signal, and it is the only thing that would ever surface in the timer's journal - without it the unit reports success while the port stays unset and Android clients keep failing to relay" \
  --apply 'sed -i "/FAILED to re-apply/{n;s@^  exit 1@  exit 0@}" "$F"'

mutation relay-port-failure-line-moved-to-stdout \
  --file scripts/ensure-tailscale-relay-port.sh \
  --bats tests/ensure-relay-port.bats \
  --test "ensure-relay-port: the FAILED line is on stderr and not on stdout" \
  --why "moves the one failure this script can report onto stdout, where every other line already goes. It is the only thing that separates a reportable failure from ordinary output for a caller that reads the streams apart - an out=\$(...) capture, 2>/dev/null, or a stdout-only logger all lose the message - and the test named for that stream could not see it, because bats' run merges the two streams" \
  --apply 'perl -pi -e '"'"'s/" >&2$/"/'"'"' "$F"'
