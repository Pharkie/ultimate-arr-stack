# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/common.sh.
#
# This file is why the mutation framework exists. It was swept once on the
# theory that being sourced by three tested files made it covered: 78 mutants
# generated, 78 survived, 0 killed. Every entry below is a defect that sweep
# could not have distinguished from correct code.
#
# Safe to run: the oracle drives every NAS-facing helper through PATH stubs
# under $BATS_TEST_TMPDIR, so no mutation here can open a connection.

mutation common-filename-through-echo-e \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: DEFECT - a backslash in a filename is data, not an escape" \
  --why "restores echo -e over a list of PATHS. Git quotes a name containing a tab on the way out, so what arrives is the two characters backslash and t - which echo -e collapses into a real tab, handing every caller a path that is neither the real filename nor the one git named" \
  --apply 'sed -i "s@printf .%s.n%s.n. \"\$staged\" \"\$tracked\"@echo -e \"\$staged\\\\n\$tracked\"@" "$F"'

mutation common-loaded-flag-executed \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: DEFECT - the loaded flag is compared, not executed" \
  --why "restores the bare if \$_NAS_CONFIG_LOADED, which RUNS the variable's value as a command - unquoted, so it word-splits too. A flag is data; executing it is a command-execution path through a variable in exchange for nothing" \
  --apply 'sed -i "s@if \[\[ \"\$_NAS_CONFIG_LOADED\" == true \]\]; then@if \$_NAS_CONFIG_LOADED; then@" "$F"'

mutation common-domain-flag-executed \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: DEFECT - the domain loaded flag is compared, not executed" \
  --why "the same defect in load_domain_config. Two sites, so a fix applied to one and not the other would leave the other live - which is what a second entry is for" \
  --apply 'sed -i "s@if \[\[ \"\$_DOMAIN_LOADED\" == true \]\]; then@if \$_DOMAIN_LOADED; then@" "$F"'

mutation common-value-truncated-at-second-equals \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: a value containing = survives the split" \
  --why "restores cut -f2, which stops at the SECOND delimiter and truncates any value with an = in it - base64 padding being the everyday example. The value is not reported as bad, it is silently shortened" \
  --apply 'sed -i "s@cut -d= -f2- @cut -d= -f2 @g" "$F"'

mutation common-ssh-host-interpolated \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: DEFECT - the host is data to bash -c, never code" \
  --why "restores the host interpolated into the string bash -c parses, so bash sees the host name before /dev/tcp does. The only thing between a host name and command execution was a grep in load_nas_config - a guarantee living in a different function" \
  --apply 'sed -i "s@timeout 2 bash -c .exec 3<>/dev/tcp/.\$1./22. _ \"\$nas_host\"@timeout 2 bash -c \"exec 3<>/dev/tcp/\$nas_host/22\"@" "$F"'

mutation common-ssh-pass-unbound \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: an unset NAS_SSH_PASS is not an unbound variable" \
  --why "restores the bare \$NAS_SSH_PASS, which aborts instantly under any caller running set -u. scripts/pre-commit does not set -u today, which is exactly how a latent trap stays latent until the first caller that does" \
  --apply 'sed -i "s@\${NAS_SSH_PASS:-}@\$NAS_SSH_PASS@" "$F"'

mutation common-repo-root-cache-bypassed \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: get_repo_root asks git exactly once, then serves the cache" \
  --why "removes the cache guard, so every caller forks git again. The answer stays correct, which is the point: a test asserting only the VALUE would pass, and the one property this function exists for - being cheap enough to call from eleven checks - would be gone with nothing to notice" \
  --apply 'sed -i "s@if \[\[ -z \"\$_REPO_ROOT\" \]\]; then@if true; then@" "$F"'

mutation common-reachable-pings-empty-host \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: is_nas_reachable is false with no host, and never pings" \
  --why "drops the empty-host guard, so an unconfigured repo pings the empty string. ping resolves it against the local search domain rather than failing outright, which turns an unconfigured checkout into a wait" \
  --apply 'sed -i "s@\[\[ -n \"\$nas_host\" \]\] && ping@ping@" "$F"'

mutation common-ssh-opts-dropped \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: ssh_to_nas builds the argv the NAS actually needs" \
  --why "drops SSH_OPTS from the argv. Every call still works against a reachable NAS - and against an unreachable one BatchMode and ConnectTimeout are gone, so a commit hangs on a password prompt nobody is watching. Nothing about the return value changes; only the argv does, which is why the assertion is on the argv" \
  --apply 'sed -i "s@ssh \$SSH_OPTS @ssh @g" "$F"'

mutation common-tracked-includes-root-dotenv \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: get_all_tracked_files lists tracked files and drops the root .env" \
  --why "stops excluding a tracked root .env from the scan list. The exclusion is deliberate: .env is the one file whose secrets are expected, and feeding it to the secret scanner makes every commit noisy enough to be waved through" \
  --apply 'sed -i "s@git ls-files 2>/dev/null | grep -v .^..env\$.@git ls-files 2>/dev/null@" "$F"'

mutation common-staged-includes-deletions \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: get_staged_files returns only staged additions and modifications" \
  --why "drops --diff-filter=ACM, so deleted paths join the list every content check then tries to read. read_file_content returns 1 on a missing file, and two of those checks are called BARE under set -e" \
  --apply 'sed -i "s@--diff-filter=ACM @@" "$F"'

# The pair below is one guard read two ways, and each entry is here because the
# other would not have caught it. Both leave the file green without the test
# named in --test: the only is_ssh_available test there asserted the no-host
# path, and a guard that returns 1 unconditionally fails that path exactly as a
# correct guard does.
#
# The `'"'"'` sequences are only so this value can be single-quoted in a file
# that bash sources AND single-quoted again for `bash -c` at replay time; the
# `\$` is what makes perl see a literal $nas_host instead of interpolating an
# empty variable and matching nothing.

mutation common-ssh-available-rejects-configured-host \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: is_ssh_available is true when the host is set and the port answers" \
  --why "is_ssh_available now returns 1 for a host that IS configured, so it can never report an open port. Every caller is the same shape - 'if ! is_ssh_available; then SKIP' in check-env-backup.sh, check-dns-duplicates.sh and check-uptime-monitors.sh - so the NAS checks do not fail, they report OK without looking, on a NAS that is up" \
  --apply 'perl -pi -e '"'"'s/\[\[ -z "\$nas_host" \]\] && return 1/\[\[ -n "\$nas_host" \]\] && return 1/'"'"' "$F"'

mutation common-ssh-available-guard-negated \
  --file scripts/lib/common.sh \
  --bats tests/lib-common.bats \
  --test "common: is_ssh_available is true when the host is set and the port answers" \
  --why "the same always-fails outcome reached from the other side: '|| return 1' fires whenever the host is NOT empty, and falls through to a connect on the empty string when it is (which fails anyway). A test that only ever asserts failure cannot tell a guard that works from a guard that always fires" \
  --apply 'perl -pi -e '"'"'s/\[\[ -z "\$nas_host" \]\] && return 1/\[\[ -z "\$nas_host" \]\] || return 1/'"'"' "$F"'
