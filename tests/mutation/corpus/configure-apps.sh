# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/configure-apps.sh.
#
# Safe to run: tests/configure-apps.bats sources the script rather than
# executing it, answers every docker question from a fixture directory, points
# CONFIGURE_ENV_FILE and TMPDIR at throwaway paths, and keeps the stub harness
# on PATH. The two mutations that delete a --dry-run gate below therefore reach
# forbid() rather than a live `docker restart pihole` or a POST into a running
# qBittorrent.

mutation configure-apps-help-fixed-line-range \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: the help block is derived from the file, not a fixed length" \
  --why "restores the head -27 | tail -24 extractor this pass replaced. It was already wrong when it was found - the header runs to line 29, so --help silently dropped its last two lines - and a hardcoded range goes stale again the moment anyone edits the header, with nothing to say so" \
  --apply 'sed -i "s@^    awk .*self\"\$@    head -27 \"\$self\" | tail -24@" "$F"'

mutation configure-apps-unknown-option-tolerated \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: an unknown option is named and fails without exiting" \
  --why "prints the usage error and then reports success anyway, so a typo like --dryrun configures the whole stack for real while the operator reads a message telling them it did not" \
  --apply 'sed -i "/Usage: \$0 \[--dry-run\]/{n;s@^                return 1\$@                return 0@}" "$F"'

mutation configure-apps-env-value-cut-at-second-equals \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: env_value keeps everything after the first =" \
  --why "goes back to cut -d= -f2, which truncates any value containing an = at the second one. A qBittorrent password is exactly the kind of value that contains one, and the truncated half authenticates as cleanly as a wrong password does - which is to say not at all, with no clue why" \
  --apply 'sed -i "s@line=\"\${line#\*=}\"@line=\$(cut -d= -f2 <<< \"\$line\")@" "$F"'

mutation configure-apps-env-value-keeps-quotes \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: env_value strips one layer of double quotes" \
  --why "drops the quote stripping. .env files in this repo quote values as a matter of style, so the password was handed to qBittorrent with its quotes still attached and simply failed to log in - the failure surfaces as an auth error, which points at the credential rather than at the parser" \
  --apply 'sed -i "/^    line=\"\${line%/d" "$F"'

mutation configure-apps-env-file-read-relatively \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: .env is resolved from the script, not the working directory" \
  --why "reads the bare relative path .env again. Run from anywhere but the repo root the lookup silently finds nothing and falls through to scraping docker logs, so the configured password is ignored in favour of a first-boot temporary one that may no longer be valid" \
  --apply 'sed -i "s@env_value QBIT_PASSWORD \"\$CONFIGURE_ENV_FILE\"@env_value QBIT_PASSWORD .env@" "$F"'

mutation configure-apps-prereq-exits-instead-of-returning \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: check_prerequisites returns rather than exits, so main can report" \
  --why "puts back the bare exit 1. It looks identical from the shell - same status - but it kills the caller from inside a function, so main can never clean up its cookie file or print a summary, and the script becomes untestable without a subprocess per assertion" \
  --apply 'sed -i "/^check_prerequisites()/,/^}/ s@^        return 1\$@        exit 1@" "$F"'

mutation configure-apps-container-name-substring-match \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: a container whose name merely contains a required one does not count" \
  --why "drops -x from the running-container check, so it stops requiring a whole-line match. This NAS runs gluetun-exit alongside gluetun, so a substring match reports the VPN as present when only the exit-node tunnel is up, and the script then waits four minutes for services that share a namespace which does not exist" \
  --apply 'sed -i "s@grep -qx \"\$c\" <<< \"\$running\"@grep -q \"\$c\" <<< \"\$running\"@" "$F"'

mutation configure-apps-gluetun-health-unchecked \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: an unhealthy gluetun is named with its actual state" \
  --why "accepts any health state that is not the empty string, so starting, unhealthy and the literal unknown all read as ready. qBittorrent and the arrs share Gluetun's netns - the whole point of this check is that they cannot answer on any port until the tunnel is up" \
  --apply 'sed -i "s@if \[\[ \"\$health\" != \"healthy\" \]\]; then@if [[ -z \"\$health\" ]]; then@" "$F"'

mutation configure-apps-arr-key-missing-not-counted \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: a missing arr key is reported as a failure, not skipped silently" \
  --why "downgrades an undiscoverable API key from a counted failure to an informational line. Every later step for that service then fails for its own reasons, and the summary reports a pile of downstream errors with no mention of the one cause" \
  --apply 'sed -i "s@fail \"Could not discover \${svc^} API key\"@info \"Could not discover \${svc^} API key\"@" "$F"'

mutation configure-apps-sab-key-always-queried \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: SABnzbd's key is only looked for when SABnzbd is running" \
  --why "queries a container that may not exist. SABnzbd is optional here, and reaching into an absent container is how an optional dependency turns into a hard one" \
  --apply 'sed -i "/^discover_api_keys()/,/^}/ s@if \[\[ \"\$SABNZBD_RUNNING\" == true \]\]; then@if true; then@" "$F"'

mutation configure-apps-env-password-loses-to-dotenv \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: a QBIT_PASSWORD in the environment wins over everything else" \
  --why "removes the guard around the .env lookup, so the file overwrites a password the operator passed explicitly on the command line. The documented escape hatch for a changed password stops working, and it stops working silently" \
  --apply 'sed -i "0,/if \[\[ -z \"\$QBIT_PASSWORD\" \]\]; then/s@if \[\[ -z \"\$QBIT_PASSWORD\" \]\]; then@if true; then@" "$F"'

mutation configure-apps-log-scrape-takes-the-oldest-password \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: the most recent temp password in the logs is the one used" \
  --why "takes the first temporary password in the log instead of the last. qBittorrent mints a new one on every restart and never removes the old lines, so on any container that has restarted once this picks a password that expired days ago" \
  --apply 'sed -i "s@| tail -1 || true)@| head -1 || true)@" "$F"'

mutation configure-apps-failed-count-is-decorative \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: FAILED is not decorative — a failure makes the script exit non-zero" \
  --why "prints the failure count and then discards it, which is what the script did before this pass: it exited 0 whether it had configured everything or nothing. An accumulator that cannot change the outcome is the exact shape this repo keeps finding in its own guards" \
  --apply 'sed -i "s@^    (( FAILED == 0 ))\$@    return 0@" "$F"'

mutation configure-apps-sab-summary-step-always-shown \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: the SABnzbd manual step appears only when SABnzbd is running" \
  --why "tells every operator to go and enter usenet credentials into a container this stack may not run. A remaining-steps list that names steps that do not apply stops being read" \
  --apply 'sed -i "/^print_summary()/,/^}/ s@if \[\[ \"\$SABNZBD_RUNNING\" == true \]\]; then@if true; then@" "$F"'

mutation configure-apps-cookie-never-removed \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: the session cookie is a private temp file, removed on exit" \
  --why "removes the EXIT trap. The script has a dozen early returns and a prerequisite failure path, so without the trap a live qBittorrent session cookie is left on disk by most runs - and the cleanup being intended is not the same as it happening" \
  --apply 'sed -i "/^    trap .\[\[ -n \"\$QBIT_COOKIE\" \]\] && rm -f/d" "$F"'

mutation configure-apps-cookie-at-a-predictable-path \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: the session cookie is a private temp file, removed on exit" \
  --why "goes back to a fixed, predictable filename in a world-writable directory - one session cookie shared by every run, so two concurrent runs clobber each other's session and anything else on the box can read it. Scoped to TMPDIR here only so replaying the corpus does not litter the real /tmp; the defect is the fixed name, not the directory" \
  --apply 'sed -i "s@mktemp -t qbit_configure_cookie.XXXXXX@printf %s \"\${TMPDIR:-/tmp}/qbit_configure_cookie.txt\"@" "$F"'

mutation configure-apps-qbit-dry-run-gate-removed \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: --dry-run touches nothing in qBittorrent, the arrs, Bazarr or Pi-hole" \
  --why "drops the dry-run early return out of configure_qbittorrent, so --dry-run authenticates and POSTs categories and preferences into a live client. --dry-run is the flag an operator reaches for precisely because they are not sure yet" \
  --apply 'sed -i "/^configure_qbittorrent()/,/^}/ s@if \[\[ \"\$DRY_RUN\" == true \]\]; then@if false; then@" "$F"'

mutation configure-apps-pihole-dry-run-gate-removed \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: --dry-run touches nothing in qBittorrent, the arrs, Bazarr or Pi-hole" \
  --why "drops the dry-run early return out of configure_pihole, which rewrites upstream DNS and then restarts the container serving the whole house's DNS. Kept separate from the qBittorrent gate above because each configure_* function carries its own copy of the check - one gate being right says nothing about the other five" \
  --apply 'sed -i "/^configure_pihole()/,/^}/ s@if \[\[ \"\$DRY_RUN\" == true \]\]; then@if false; then@" "$F"'

# --- Entries below close gaps the generative sweep found, not gaps anyone
# --- thought of first. run-generated.sh reported them as survivors against the
# --- first 44 tests in tests/configure-apps.bats; each one is here because a
# --- test was then written for it.

mutation configure-apps-qbit-auth-inverted \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: a successful qBittorrent login proceeds to configure it" \
  --why "drops the negation on the auth check, so a successful login is reported as an authentication failure and every later step is skipped. Survived the first pass because the only tests reaching configure_qbittorrent were dry runs, which return before authenticating at all" \
  --apply 'sed -i "s@if ! qbit_auth @if qbit_auth @" "$F"'

mutation configure-apps-qbit-encryption-check-inverted \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: preferences already at the target values are left alone" \
  --why "inverts one comparison in the already-configured check, so a client that is already correct gets its whole preference set rewritten on every run. The script advertises itself as idempotent; this is the check that makes that true" \
  --apply 'sed -i "s@if p.get(.encryption., 0) != 1@if p.get(.encryption., 0) == 1@" "$F"'

mutation configure-apps-qbit-preference-stops-being-checked \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: one wrong preference is enough to rewrite the whole set" \
  --why "removes one field from the already-configured check. The script then reports the preferences as correct while that setting stays wrong forever, and re-running - the documented remedy - fixes nothing. Kept separate from the inverted comparison above because a dropped field fails in the opposite direction: silence rather than churn" \
  --apply 'sed -i "/^if p.get(.max_active_uploads., -1) != 5: sys.exit(1)\$/d" "$F"'

mutation configure-apps-qbit-cookie-left-behind \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: the session cookie is removed once qBittorrent is configured" \
  --why "leaves the live session cookie on disk once qBittorrent is configured. main's EXIT trap is the backstop, not the plan - configure_qbittorrent is also called on its own, and a cleanup that only happens when someone else remembers is not a cleanup" \
  --apply 'sed -i "/^    rm -f \"\$QBIT_COOKIE\"\$/d" "$F"'

mutation configure-apps-sabnzbd-name-substring-match \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: a container whose name merely contains sabnzbd is not sabnzbd" \
  --why "drops -x from the SABnzbd check, so any running container whose name contains 'sabnzbd' counts. SABNZBD_RUNNING gates both the API-key lookup and the manual step in the summary, so an unrelated container turns an optional service into one this script reaches into and reports a failure for - the same substring-match defect as the required-container check above, and the same one that reached production twice already" \
  --apply 'perl -pi -e "s/grep -qx \"sabnzbd\"/grep -q \"sabnzbd\"/" "$F"'

# The -P removal in this file is not cosmetic: the extraction it replaced could
# not fail on BSD grep (it exited 2 with the status discarded), so these two
# lines were only ever judged on a GNU host. Pin the shape the replacement has
# to keep.
mutation configure-apps-arr-key-extraction-prints-the-whole-file \
  --file scripts/configure-apps.sh \
  --bats tests/configure-apps.bats \
  --test "configure-apps: each arr key is read out of that service's own config.xml" \
  --why "drops -n from the extraction, so sed prints every line of config.xml and then the substitution output as well. The variable that carries the service's API key then holds the whole file: every later request authenticates with a value containing newlines, and the eight characters shown to the operator come from the XML prologue instead of the value itself" \
  --apply 'python3 -c "import sys;p=sys.argv[1];s=open(p).read();old=\"| sed -n \x27s|.*<ApiKey>\";new=\"| sed -e \x27s|.*<ApiKey>\";assert old in s, old;s=s.replace(old,new,1);open(p,\"w\").write(s)" "$F"'
