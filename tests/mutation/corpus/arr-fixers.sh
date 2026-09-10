# shellcheck shell=bash
# Corpus: scripts/queue-cleanup.sh, scripts/fix-*.sh and the three Python
# modules they call.
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
#
# These were heredocs and ad-hoc `.env` greps until 2026-09-01, with no test of
# any kind. Four of the defects catalogued for the coverage plan lived here, and
# every one of them was silent: --apply that renamed nothing, an API key
# truncated at an '=', a dry run that trimmed the log anyway, and a pagination
# loop with no exit. Each entry below reintroduces one and requires the test
# that now covers it to go red.
#
# The Python entries all name the same bats test, because tests/python-suite.bats
# is the bridge that runs pytest -- a failure anywhere under tests/python/ comes
# back through it. The pytest file and function are named in --why instead.

# --- fix_sonarr_folders.py: defect #4 -------------------------------------

mutation apply-argv-case \
  --file scripts/lib/fix_sonarr_folders.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "comparing argv against the literal \"True\" while the bash half writes lowercase \`true\` makes --apply inert: the script takes the dry-run branch, prints 'Would rename', and reports a summary that reads as a result - which is how it shipped (test_apply_flag_accepts_the_spelling_bash_actually_passes)" \
  --apply 'sed -i "s@^    return str(value).strip().lower() == \"true\"\$@    return str(value) == \"True\"@" "$F"'

mutation apply-flag-accepts-anything \
  --file scripts/lib/fix_sonarr_folders.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a flag parser that answers true for every input turns an unexpected argv value into a live folder rename across the whole library (test_apply_flag_is_false_for_anything_unrecognised)" \
  --apply 'sed -i "s@^    return str(value).strip().lower() == \"true\"\$@    return True@" "$F"'

mutation folder-token-order \
  --file scripts/lib/fix_sonarr_folders.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "substituting {Series TitleYear} after {Series Title} is only safe because the shorter token carries its own closing brace; reordering so the bare title runs against an already-substituted string is the live regression risk in this function (test_the_bare_title_token_does_not_eat_the_titleyear_token)" \
  --apply 'sed -i "s@^    result = result.replace(\"{Series TitleYear}\", \"%s (%d)\" % (title, year))\$@    result = result.replace(\"{Series TitleYear}\", title)@" "$F"'

# --- fix_radarr_paths.py --------------------------------------------------

mutation radarr-match-ignores-year \
  --file scripts/lib/fix_radarr_paths.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "without the year filter the loosest tier compares titles alone, so a remake is repointed at the original's directory and Radarr is told a film lives somewhere it does not (test_candidates_are_restricted_to_the_movies_own_year)" \
  --apply 'sed -i "s@^    candidates = \[d for d in disk_dirs if \"(%s)\" % year in d\]\$@    candidates = list(disk_dirs)@" "$F"'

mutation radarr-updates-a-movie-with-a-file \
  --file scripts/lib/fix_radarr_paths.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "hasFile means Radarr has already reconciled that movie; repointing it moves a working entry, and this guard is the only thing preventing it (test_a_movie_with_a_file_is_left_alone_even_if_the_path_looks_wrong)" \
  --apply 'sed -i "s@^        if m.get(\"hasFile\", False):\$@        if False:@" "$F"'

mutation radarr-rejection-counted-as-success \
  --file scripts/lib/fix_radarr_paths.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "treating any curl response as success counts a rejected PUT as a fix; curl prints nothing at all when it cannot connect, so a totally unreachable Radarr would report a clean run (test_an_empty_curl_response_is_a_failure_not_a_success)" \
  --apply 'sed -i "s@^        if code in (\"200\", \"202\"):\$@        if True:@" "$F"'

# --- queue_cleanup.py: defect #9 and the classifier -----------------------

mutation pagination-unbounded \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a page cap large enough to never be reached is the same as no cap: a service whose totalRecords grows at least as fast as the pages are consumed loops forever, inside a systemd unit, with no output and no timeout (test_the_default_page_bound_is_not_unlimited)" \
  --apply 'sed -i "s@^MAX_PAGES = 100\$@MAX_PAGES = 10 ** 9@" "$F"'

mutation pagination-empty-page-continues \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "inverting the empty-page guard stops the walk on the first page that HAS records, so the queue is read as empty and nothing is ever cleaned - the polarity of this test is the whole guard (test_a_single_page_queue_makes_exactly_one_request)" \
  --apply 'sed -i "s@^        if not records:\$@        if records:@" "$F"'

mutation pagination-cap-silent \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a truncation nobody is told about reads as a complete run; the cap must say what it did not examine (test_hitting_the_page_bound_is_reported_rather_than_silent)" \
  --apply 'sed -i "s@^            out(f\"  ! Stopped after {max_pages} pages ({len(all_records)} items);\"\$@            out(f\"\"@" "$F"'

mutation stale-threshold-inverted \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the 24-hour floor is what stops a download that started ten minutes ago being deleted from the client and blocklisted; comparing the wrong way round deletes exactly the healthy ones (test_zero_progress_becomes_stale_only_after_twenty_four_hours)" \
  --apply 'sed -i "0,/^        if age_hours is not None and age_hours > 24:\$/s@^        if age_hours is not None and age_hours > 24:\$@        if age_hours is not None and age_hours < 24:@" "$F"'

mutation error-removal-ignores-warning-status \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "without the warning-status gate any download whose message merely mentions a keyword is removed and blocklisted, including healthy ones (test_error_classification_requires_the_warning_status)" \
  --apply 'sed -i "s@^    if tracked_status == \"warning\":\$@    if True:@" "$F"'

mutation search-payload-shape \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "Radarr's MoviesSearch takes a list and Sonarr's SeriesSearch takes a scalar; posting the wrong shape is rejected, so every removed item is left with no replacement search - the removal still happened (test_radarr_search_takes_a_list_of_ids)" \
  --apply 'sed -i "s@^        return {\"name\": svc\[\"search_cmd\"\], svc\[\"search_key\"\]: \[target_id\]}\$@        return {\"name\": svc[\"search_cmd\"], svc[\"search_key\"]: target_id}@" "$F"'

mutation queue-url-separator \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "appending the apikey with '?' to a path that already has a query string produces a URL with two '?', which the arr APIs answer 404 - reported by the caller as 'Failed to fetch queue' rather than as the malformed URL it is (test_a_path_that_already_has_a_query_gets_an_ampersand)" \
  --apply 'sed -i "s@^    if \"?\" in url:\$@    if False:@" "$F"'

# --- scripts/lib/env-file.sh: defect #7 -----------------------------------

mutation env-value-truncated-at-equals \
  --file scripts/lib/env-file.sh \
  --bats tests/lib-env-file.bats \
  --test "keeps an equals sign in the middle of a value" \
  --why "taking the text after the LAST '=' rather than the first is the same class of bug as the \`cut -d= -f2\` it replaced: a base64 API key ending in '=' padding is silently truncated and the caller authenticates with a fragment" \
  --apply 'sed -i "s@^                value=\${line#\*=}\$@                value=\${line##*=}@" "$F"'

mutation env-quote-strip \
  --file scripts/lib/env-file.sh \
  --bats tests/lib-env-file.bats \
  --test "strips one surrounding pair of double quotes" \
  --why "a quoted value used with its quotes attached is passed straight into an API URL as %22...%22, which fails as a 401 that nothing reports as a configuration problem" \
  --apply 'sed -i "s@^    case \"\$value\" in\$@    case \"\" in@" "$F"'

mutation env-strips-every-quote \
  --file scripts/lib/env-file.sh \
  --bats tests/lib-env-file.bats \
  --test "keeps quotes that are part of the value" \
  --why "the sonarr script's old \`tr -d\` removed every quote anywhere in the value rather than a surrounding pair, silently corrupting any password that legitimately contained one" \
  --apply 'sed -i "s@^    case \"\$value\" in\$@    value=\$(printf %s \"\$value\" | tr -d \"\\\"\"); case \"\$value\" in@" "$F"'

mutation env-key-matched-as-prefix \
  --file scripts/lib/env-file.sh \
  --bats tests/lib-env-file.bats \
  --test "a key is not matched as a suffix of another" \
  --why "matching the key anywhere in the line rather than anchored at its start answers a request for KEY with OLD_KEY's value - a stale credential returned as if it were the live one" \
  --apply 'sed -i "s@^            \"\${key}=\"\*)\$@            *\"\${key}=\"*)@" "$F"'

# --- scripts/queue-cleanup.sh: defect #8 ----------------------------------

mutation log-trim-ignores-dry-run \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "a dry run does not trim the log" \
  --why "trimming the log outside --apply makes it the one thing a dry run changes on disk, and what it discards is the operator's record of previous runs - the thing they are reading when they dry-run to decide whether to apply" \
  --apply 'sed -i "s@^if \$APPLY && \[\[ -f \"\$LOG_FILE\" \]\]; then\$@if [[ -f \"\$LOG_FILE\" ]]; then@" "$F"'

mutation log-trim-temp-leaks \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "a failing trim leaves neither a temp file nor a truncated log" \
  --why "mktemp with no trap leaks a file on every failed trim, forever, in a directory nobody watches" \
  --apply 'sed -i "s@^    trap .rm -f \"\$TMPLOG\". EXIT\$@    :@" "$F"'

mutation log-trim-temp-in-tmp \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "the temp file is created beside the log, not in /tmp" \
  --why "a bare mktemp puts the temp in /tmp, a different filesystem from the log on the NAS, which turns the mv below it into a copy-then-unlink that can leave the log half-written rather than the atomic rename it reads as" \
  --apply 'sed -i "s@^    TMPLOG=\$(mktemp \"\${LOG_FILE}.XXXXXX\")\$@    TMPLOG=\$(mktemp)@" "$F"'

mutation queue-python-failure-ignored \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "a failing Python half is fatal and says so" \
  --why "the heredoc form inherited set -e; the extracted form is a subprocess, so without an explicit status check a Python half that died reads as a clean run and the webhook announces a cleanup that never happened" \
  --apply 'sed -i "s@^if ! python3 \"\${SCRIPT_DIR}/lib/queue_cleanup.py\" \\\\\$@if false; then :; elif false; then@" "$F"'

# --- scripts/fix-*.sh -----------------------------------------------------

mutation sonarr-apply-flag-not-passed \
  --file scripts/fix-sonarr-folders.sh \
  --bats tests/fix-arr-paths.bats \
  --test "--apply passes the lowercase true the Python half expects" \
  --why "an --apply that never reaches the Python half is defect #4 by another route: the operator is told 'Mode: APPLYING CHANGES' and nothing is renamed" \
  --apply 'sed -i "s@^  APPLY=true\$@  APPLY=false@" "$F"'

mutation radarr-tmpdir-not-cleaned \
  --file scripts/fix-radarr-paths.sh \
  --bats tests/fix-arr-paths.bats \
  --test "the temp directory is removed even when the fixer fails" \
  --why "the temp dir holds a full dump of the Radarr library including the API key in no file the user chose; without the EXIT trap it survives every failed run" \
  --apply 'sed -i "s@^trap .rm -rf \"\$TMPDIR\". EXIT\$@:@" "$F"'

# --- second round: the survivors of the first generative sweep -------------
#
# The sweep over these four targets killed 36 of 61. What survived was mostly
# one shape -- an assertion that a message reached the terminal but not WHICH
# stream -- so these entries pin the stream, and the errexit that stands
# between a failed step and a run that reports success anyway.

mutation queue-error-on-stdout \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "the fatal error goes to stderr, not stdout" \
  --why "this runs from cron with stdout redirected into a log; an error written there and nowhere else never reaches cron's mail, which is the only thing that tells anyone the weekly job stopped working" \
  --apply 'sed -i "s@^    echo \"ERROR: the queue cleanup exited non-zero; no webhook was sent.\" >\&2\$@    echo \"ERROR: the queue cleanup exited non-zero; no webhook was sent.\"@" "$F"'

mutation queue-webhook-body-dropped \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "the webhook carries the cleanup payload" \
  --why "-e sets a Referer header instead of a POST body, so Home Assistant fires a notification with nothing in it - and a test that only checks the URL was called passes either way" \
  --apply 'sed -i "s@^    -d \"{\\\\\"title\\\\\":\\\\\"Queue Cleanup@    -e \"{\\\\\"title\\\\\":\\\\\"Queue Cleanup@" "$F"'

mutation queue-no-errexit \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "a failing mktemp aborts rather than trimming to nowhere" \
  --why "without errexit the script carries on past the failed mktemp and redirects the tail into the empty string. It still exits non-zero - the failed redirect makes the enclosing if compound return 1 - so only the stream separates them: errexit aborts silently where the mutant leaves bash's own ': No such file or directory' in cron's mail" \
  --apply 'sed -i "s@^set -euo pipefail\$@set -uo pipefail@" "$F"'

mutation radarr-error-on-stdout \
  --file scripts/fix-radarr-paths.sh \
  --bats tests/fix-arr-paths.bats \
  --test "the fatal error goes to stderr, not stdout" \
  --why "same stream confusion as the queue cleanup: an error on stdout is indistinguishable from the script's normal chatter" \
  --apply 'sed -i "s@^    echo \"ERROR: the path fixer exited non-zero; nothing further was attempted.\" >\&2\$@    echo \"ERROR: the path fixer exited non-zero; nothing further was attempted.\"@" "$F"'

mutation radarr-no-errexit \
  --file scripts/fix-radarr-paths.sh \
  --bats tests/fix-arr-paths.bats \
  --test "a failed library dump aborts before the fixer runs" \
  --why "curl writes movies.json; without errexit a failed dump leaves it empty and the fixer concludes the library is empty rather than that it could not read it" \
  --apply 'sed -i "s@^set -euo pipefail\$@set -uo pipefail@" "$F"'

mutation radarr-env-not-a-file \
  --file scripts/fix-radarr-paths.sh \
  --bats tests/fix-arr-paths.bats \
  --test "an .env that is a directory is reported as a missing .env" \
  --why "-e accepts a directory as the .env, so the script reports a missing API key rather than the missing config file that is actually the problem" \
  --apply 'sed -i "s@^if \[ ! -f \"\$ENV_FILE\" \]; then\$@if [ ! -e \"\$ENV_FILE\" ]; then@" "$F"'

mutation radarr-movies-not-a-directory \
  --file scripts/fix-radarr-paths.sh \
  --bats tests/fix-arr-paths.bats \
  --test "a movies path that is a file is reported as a missing directory" \
  --why "-e accepts a regular file as the movies root; ls then lists the file itself and every movie is reported as having no match on disk" \
  --apply 'sed -i "s@^if \[ ! -d \"\$MOVIES_DIR\" \]; then\$@if [ ! -e \"\$MOVIES_DIR\" ]; then@" "$F"'

mutation radarr-media-root-abort \
  --file scripts/fix-radarr-paths.sh \
  --bats tests/fix-arr-paths.bats \
  --test "an .env with a key but no MEDIA_ROOT still explains itself" \
  --why "\`&& true\` inside the substitution propagates env_value's failure to the assignment, which errexit turns into a bare exit 1 with no message at all where the script used to say which directory it could not find" \
  --apply 'sed -i "s@^MEDIA_ROOT=\$(env_value \"\$ENV_FILE\" MEDIA_ROOT || true)\$@MEDIA_ROOT=\$(env_value \"\$ENV_FILE\" MEDIA_ROOT \&\& true)@" "$F"'

mutation sonarr-error-on-stdout \
  --file scripts/fix-sonarr-folders.sh \
  --bats tests/fix-arr-paths.bats \
  --test "the fatal error goes to stderr, not stdout" \
  --why "same stream confusion as its radarr sibling" \
  --apply 'sed -i "s@^    echo \"ERROR: the folder fixer exited non-zero; nothing further was attempted.\" >\&2\$@    echo \"ERROR: the folder fixer exited non-zero; nothing further was attempted.\"@" "$F"'

mutation env-file-accepts-a-directory \
  --file scripts/lib/env-file.sh \
  --bats tests/lib-env-file.bats \
  --test "a directory in place of the file reads as absent, quietly" \
  --why "-e gets as far as redirecting from a directory, which returns the same non-zero but prints a bash error from inside a library function - noise in a cron log from a call that is supposed to be a clean 'not configured'" \
  --apply 'sed -i "s@^    \[ -f \"\$file\" \] || return 1\$@    [ -e \"\$file\" ] || return 1@" "$F"'

mutation queue-trim-boundary-off-by-one \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "a log exactly at the limit is not rewritten" \
  --why "-ge rewrites the log every run once it reaches the limit and stays there, replacing a live file with a byte-identical copy - invisible to any content assertion, so only the fact that a temp file was made at all can catch it" \
  --apply 'sed -i "s@^  if \[\[ \"\$LINES\" -gt \"\$MAX_LOG_LINES\" \]\]; then\$@  if [[ \"\$LINES\" -ge \"\$MAX_LOG_LINES\" ]]; then@" "$F"'

mutation sonarr-no-errexit \
  --file scripts/fix-sonarr-folders.sh \
  --bats tests/fix-arr-paths.bats \
  --test "a missing library aborts rather than blaming the API key" \
  --why "without errexit a failed source is ignored, env_value is not a command, and the empty key makes the script report a missing SONARR_API_KEY - a confident wrong diagnosis that sends the operator to edit an .env that was fine" \
  --apply 'sed -i "s@^set -euo pipefail\$@set -uo pipefail@" "$F"'

mutation queue-log-not-a-file \
  --file scripts/queue-cleanup.sh \
  --bats tests/queue-cleanup.bats \
  --test "a directory in place of the log is skipped quietly" \
  --why "-e lets a directory through to \`wc -l <\`, which both prints a 0 and fails, so LINES becomes two lines and the arithmetic test throws - same exit status, same skipped trim, but a bash syntax error in the cron log where the guard was meant to read as 'nothing to trim'" \
  --apply 'sed -i "s@^if \$APPLY && \[\[ -f \"\$LOG_FILE\" \]\]; then\$@if \$APPLY \&\& [[ -e \"\$LOG_FILE\" ]]; then@" "$F"'

# --- queue_cleanup.py: the seam and the entry point -----------------------
#
# Everything below was found by the generative sweep, not by reading. All of it
# sat behind the same blind spot: run() and process_service() are always handed
# a FakeApi, so ArrApi -- the class that actually shells out to curl -- had
# never been constructed, and main() had never been called at all.

mutation queue-api-loses-the-url \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "curl with no URL exits 2, which the returncode check turns into None, which fetch_queue reports as 'Failed to fetch queue' - so a run that never asked for anything looks exactly like an arr service being down (test_get_shells_out_to_curl_with_the_built_url)" \
  --apply 'sed -i "s@^            \[\"curl\", \"-s\", \"-f\", build_url(port, path, key)\],\$@            [\"curl\", \"-s\", \"-f\"],@" "$F"'

mutation queue-api-ignores-curl-status \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "curl prints nothing on failure, so skipping the returncode check hands an empty string to json.loads and the whole run dies on a JSONDecodeError inside a systemd unit - instead of the one logged line the guard was written to produce (test_a_failed_curl_yields_none_rather_than_a_parse_error)" \
  --apply 'sed -i "0,/^        if result.returncode != 0:\$/s@^        if result.returncode != 0:\$@        if False:@" "$F"'

mutation queue-age-floored-to-whole-hours \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "flooring the age agrees with the real thing on every whole-hour test input, and differs only inside the last hour before the cutoff - a download 24.5 hours dead is left in the queue for another half hour on every subsequent run, because it floors to 24 every time (test_the_age_is_measured_in_fractional_hours_not_whole_ones)" \
  --apply 'sed -i "s@^        return (now - added).total_seconds() / 3600\$@        return (now - added).total_seconds() // 3600@" "$F"'

mutation queue-null-timestamp-unguarded \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "an absent \`added\` key yields \"\" and an \`added: null\` yields None; only the first survives fromisoformat, and the except clause catches ValueError and TypeError but not the AttributeError None raises - so one null timestamp anywhere in the queue aborts the whole cleanup (test_a_null_added_timestamp_is_not_stale_and_does_not_raise)" \
  --apply 'sed -i "s@^    if not added_str:\$@    if False:@" "$F"'

mutation queue-run-drops-the-injected-clock \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "run() forwarding stops at out=, so process_service falls back to datetime.now(); every classification test still passes because they assert through process_service directly, and the one thing that changes is that the clock is no longer the one the caller chose (test_run_forwards_the_injected_clock)" \
  --apply 'sed -i "s@^                                            out=out, now=now, sleep=sleep,\$@                                            out=out,@" "$F"'

mutation queue-summary-rule-dropped \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the rule is the only thing separating one service'\''s per-item lines from the totals in a log cron mails out; dropping it changes no status, no total and no message, and every summary assertion still passes (test_the_summary_is_introduced_by_a_rule)" \
  --apply 'sed -i "s@^    out(f.*40}.*\$@    pass@" "$F"'

mutation queue-applied-run-suggests-applying \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "telling an operator to re-run with --apply after a run that already applied invites a second pass over a queue that was just emptied; the dry-run tests cannot see it, because they only ever assert the hint is present (test_the_applied_summary_does_not_suggest_applying)" \
  --apply 'sed -i "s@^    if not apply_changes and total_removed > 0:\$@    if True and total_removed > 0:@" "$F"'

mutation queue-main-drops-the-apply-flag \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "run()'\''s next parameter is verbose, so dropping apply_changes at the call site silently promotes the verbose flag into it: \`--verbose\` alone would delete and blocklist for real, and no test that injects its own api could ever see it (test_main_maps_argv_onto_the_run_arguments)" \
  --apply 'sed -i "s@^    run(services(sonarr_key, radarr_key), ArrApi(), apply_changes, verbose)\$@    run(services(sonarr_key, radarr_key), ArrApi(), verbose)@" "$F"'

mutation queue-script-entry-inert \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "with the entry point gone the module imports, does nothing and exits 0 - which from the bash half is indistinguishable from a clean run over an empty queue, and no import-based test executes this line at all (test_the_module_actually_runs_when_executed_as_a_script)" \
  --apply 'sed -i "s@^    sys.exit(main(sys.argv))\$@    pass@" "$F"'

mutation queue-search-result-silent \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the summary counts searches attempted, not searches accepted, so a service rejecting every one still reports them as triggered - this per-item line is the only place the FAILED is visible, and removing it leaves an operator reading a clean report of work that did not happen (test_a_failed_search_says_so_against_the_item_it_failed_for)" \
  --apply 'sed -i "s@^                out(f\".*{status}.*\$@                pass@" "$F"'

mutation queue-dry-run-search-unnamed \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "a dry run's entire product is its output; the summary says how many searches would be triggered and only this line says for which items, so dropping it makes the dry run unable to answer the question it exists to answer (test_a_dry_run_names_each_search_it_would_have_triggered)" \
  --apply 'sed -i "s@^                out(f\".*.dry-run. Search.*\$@                pass@" "$F"'

mutation queue-import-pending-ignores-state \
  --file scripts/lib/queue_cleanup.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "the state and the status are two conditions and dropping the state one lets any warning-flagged record with an 'not an upgrade' message be treated as pending import - which deletes and blocklists releases that are still downloading (test_a_still_downloading_item_is_not_judged_by_the_import_pending_rule)" \
  --apply 'sed -i "s@^    if tracked_state == \"importPending\" and tracked_status == \"warning\":\$@    if True and tracked_status == \"warning\":@" "$F"'

# --- fix_sonarr_folders.py: the blank separator line -----------------------

mutation sonarr-blank-line-separator-removed \
  --file scripts/lib/fix_sonarr_folders.py \
  --bats tests/python-suite.bats \
  --test "the extracted modules pass their pytest suite" \
  --why "drops the blank line run() prints between the configured-format header and the per-series list. Only the FIRST occurrence is mutated: run() prints a second blank line before the summary, so a membership-style assertion would still pass with this one gone - which is why this survived the 2026-09-02 sweep untriaged. It changes stdout, so it is not an equivalent mutant (test_the_dry_run_summary_says_it_is_a_dry_run asserts lines[1] == \"\")" \
  --apply 'sed -i "0,/^    out(\"\")/s/^    out(\"\")/    pass/" "$F"'
