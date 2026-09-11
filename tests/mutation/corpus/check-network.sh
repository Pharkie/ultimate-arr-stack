# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/check-network.sh.
#
# Safe to run: tests/check-network.bats sources the script rather than executing
# it, answers `docker network inspect` from a throwaway fixture directory, and
# keeps the stub harness on PATH - so the one path that reaches
# `docker network rm` trips forbid() instead of deleting a network the whole
# house's DNS is attached to.

mutation check-network-only-checks-arr-core \
  --file scripts/check-network.sh \
  --bats tests/check-network.bats \
  --test "check-network: OWNED_NETWORKS is exactly the set the compose files create" \
  --why "narrows the script back to the single network it checked before this pass. vpn-net, magnetio-net and traefik-lan are created by this repo's compose files too, and an orphaned one blocks a deploy in exactly the same way - a cleaner that silently covers a quarter of what it claims to cover is the failure this list exists to prevent" \
  --apply 'sed -i "s@^OWNED_NETWORKS=(arr-core vpn-net magnetio-net traefik-lan)\$@OWNED_NETWORKS=(arr-core)@" "$F"'

mutation check-network-first-network-only \
  --file scripts/check-network.sh \
  --bats tests/check-network.bats \
  --test "check-network: main checks every network in OWNED_NETWORKS" \
  --why "reports on the first entry and stops, so the list can be complete and correct while three quarters of it is never read. Kept separate from the list-drift mutation above because the two fail in the same visible way - a short report - for entirely different reasons" \
  --apply 'sed -i "s#OWNED_NETWORKS\[@\]#OWNED_NETWORKS[0]#" "$F"'

mutation check-network-absent-reads-as-orphan \
  --file scripts/check-network.sh \
  --bats tests/check-network.bats \
  --test "check-network: a network that does not exist reports OK and touches nothing" \
  --why "drops the negation on the existence check, so a network that was never created falls through to the orphan report and gets offered for removal. On the first deploy to a rebuilt NAS every network is absent, which would make the script offer to delete four networks that do not exist" \
  --apply 'sed -i "s@^    if ! docker network inspect \"\$net\" &>/dev/null; then\$@    if docker network inspect \"\$net\" \&>/dev/null; then@" "$F"'

mutation check-network-separator-reads-as-in-use \
  --file scripts/check-network.sh \
  --bats tests/check-network.bats \
  --test "check-network: a separator-only inspect result is not mistaken for a network in use" \
  --why "tests the raw inspect output instead of stripping separators first. A template that emits a bare space for an empty network then reads as in-use, and the script reports OK on every orphan forever - the guard-that-cannot-fire shape this repo keeps finding in its own checks" \
  --apply 'sed -i "s@if \[\[ -n \"\${containers// /}\" \]\]; then@if [[ -n \"\$containers\" ]]; then@" "$F"'

mutation check-network-prompts-without-a-terminal \
  --file scripts/check-network.sh \
  --bats tests/check-network.bats \
  --test "check-network: a non-interactive run prints the manual command and removes nothing" \
  --why "removes the terminal gate around the prompt. bash prints no prompt when stdin is not a terminal, so a piped or cron-driven run would silently consume a line of its own input and act on it - a destructive branch entered with no human ever having seen a question" \
  --apply 'sed -i "s@^    if ! stdin_is_tty; then\$@    if false; then@" "$F"'

mutation check-network-n-also-removes \
  --file scripts/check-network.sh \
  --bats tests/check-network.bats \
  --test "check-network: answering n removes nothing and says how to do it by hand" \
  --why "widens the confirmation regex to accept the refusals as well. The prompt says [y/N] and the one answer that must never delete anything is the one people type when they mean no" \
  --apply 'sed -i "s@\^\[Yy\]\\\$@^[YyNn]\$@" "$F"'

mutation check-network-default-is-yes \
  --file scripts/check-network.sh \
  --bats tests/check-network.bats \
  --test "check-network: pressing enter removes nothing - the default is No" \
  --why "inverts the confirmation into a refusal test, so bare Enter - and a closed stdin - delete the network. [y/N] states that the empty answer is No; this makes the safe-looking keypress the destructive one" \
  --apply 'sed -i "s@if \[\[ \"\${REPLY:-}\" =~ \^\[Yy\]\\\$ \]\]; then@if [[ ! \"\${REPLY:-}\" =~ ^[Nn]\$ ]]; then@" "$F"'

mutation check-network-removal-never-reached \
  --file scripts/check-network.sh \
  --bats tests/check-network.bats \
  --test "check-network: answering y reaches docker network rm" \
  --why "turns the removal into an echo. The test that drives the y path asserts the harness STOPPED a real call, so without this entry it would pass just as happily against a script that never removes anything - proving the test observes the destructive call rather than merely surviving it" \
  --apply 'sed -i "s@^        docker network rm \"\$net\"\$@        echo docker network rm \"\$net\"@" "$F"'

mutation check-network-failed-inspect-kills-the-run \
  --file scripts/check-network.sh \
  --bats tests/check-network.bats \
  --test "check-network: a container-list inspect that fails does not kill the report" \
  --why "makes a failed container-list inspect fatal. The existence check and the templated check are two separate docker calls and they can disagree - the network can be removed between them, or the daemon can fail the second one - and a half-finished cleanup is the state this script is run in. Without the status captured on the assignment, the bare substitution carries docker's own status into the script's errexit, which exits 1 having said nothing about that network and never looks at the rest of the list, so an orphan further down is reported by nobody" \
  --apply 'perl -pi -e '"'"'s{ \|\| inspect_rc=\$\?}{}'"'"' "$F"'

mutation check-network-failed-inspect-read-as-empty \
  --file scripts/check-network.sh \
  --bats tests/check-network.bats \
  --test "check-network: a failed container-list inspect is not read as an empty network" \
  --why "swallows the inspect failure, which is how this shipped: the container list comes back empty, an empty list is what the orphan branch reports, and the operator is offered the removal of a live network on nothing worse than a failed docker call. The two states are byte-identical on stdout - the templated inspect prints nothing for a network with no containers and nothing for a call that failed - so the only thing that separates them is the status" \
  --apply 'perl -pi -e '"'"'s{ \|\| inspect_rc=\$\?}{ || true}'"'"' "$F"'
