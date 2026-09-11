# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/check-image-versions.sh.
#
# Safe to run: every test in tests/lib-image-versions.bats that drives
# check_image_versions or the registry queries installs a curl stub on PATH
# first, so no mutation here can reach hub.docker.com or ghcr.io -- the two
# tests that examine a registry response hand that stub a fixture file.

mutation stat-bsd-flag \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a fresh cache returns the stored tag" \
  --why "restores the inline 'stat -f %m || stat -c %Y' chain, which reads as a portable BSD-then-GNU fallback but is not: -f is --file-system on GNU, a VALID flag printing a filesystem report to stdout while exiting 1, so the fallback appends the real mtime to that report and the arithmetic consuming it dies on a syntax error - aborting _cache_get, so the cache was never read at all and every commit re-queried 31 registries" \
  --apply 'perl -0pi -e "s/cache_age=\\\$\\(\\( \\\$\\(date \\+%s\\) - \\\$\\(_file_mtime \\\"\\\$_IMAGE_CACHE\\\"\\) \\)\\)/cache_age=\\\$((  \\\$(date +%s) - \\\$(stat -f %m \\\"\\\$_IMAGE_CACHE\\\" 2>\\/dev\\/null || stat -c %Y \\\"\\\$_IMAGE_CACHE\\\" 2>\\/dev\\/null || echo 0) ))/" "$F"'

mutation mtime-shape-unchecked \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a missing file reads as mtime 0, not as garbage" \
  --why "drops the fallback to 0, so an unreadable file yields an empty mtime and the staleness arithmetic silently treats the cache as written at the epoch - permanently stale rather than permanently fresh, which is the same class of invisible wrongness in the other direction" \
  --apply 'sed -i "s@^    echo 0\$@    :@" "$F"'

mutation find-latest-ignores-segment-depth \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: candidates with a different segment depth are rejected" \
  --why "without the dot-count match a two-segment tag competes with a three-segment pin, which is how 'redis 7-alpine -> 8' style noise becomes a recommendation to move to a tag that means something entirely different" \
  --apply 'sed -i "s@^        \[\[ \"\$tag_dots\" -ne \"\$current_dots\" \]\] \&\& continue\$@        :@" "$F"'

mutation find-latest-ignores-v-prefix \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a v-prefixed current tag only matches v-prefixed tags" \
  --why "mixing v-prefixed and bare tags makes the checker recommend a tag that does not exist under the name it printed, so the suggested pin fails to pull" \
  --apply 'perl -0pi -e "s/            \[\[ \\\"\\\$tag\\\" != v\\* \]\] && continue\n/            :\n/" "$F"'

# --- The function itself ----------------------------------------------------
#
# The helpers above were covered while check_image_versions was not, and the
# first full sweep priced that: 21 mutants inside it survived. These entries are
# the permanent half of the fix -- every one is a branch of the check that can
# be inverted without the run failing, because the check only ever warns.

mutation check-image-versions-offline-guard-inverted \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: an offline host skips the check instead of reporting no updates" \
  --why "drops the negation from the connectivity probe, so a host with no internet takes the registry path instead of the skip: it prints that it is checking the pinned images and then reports them up to date, which is the most confidently wrong answer this check can give" \
  --apply 'perl -pi -e "s/if ! curl -s --max-time 2/if curl -s --max-time 2/" "$F"'

mutation check-image-versions-empty-repo-guard-inverted \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a repo with no compose files skips instead of checking nothing" \
  --why "inverts the no-compose-files guard, so a repo whose glob matched nothing carries on to check zero images and prints the all-up-to-date line - success reported for having looked at nothing" \
  --apply 'perl -pi -e "s/compose_files\[@\]\} -eq 0/compose_files[@]} -ne 0/" "$F"'

mutation check-image-versions-brew-image-grep \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a pinned image with a newer tag is reported as an update" \
  --why "drops -E from the image-line pattern; in a BRE the + is a literal plus, so the pattern matches nothing and every run reports no pinned images found - the check stops checking and says so only in a line nobody reads as a failure" \
  --apply 'perl -pi -e "s/grep -E /grep /" "$F"'

mutation check-image-versions-file-images-guard-inverted \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a pinned image with a newer tag is reported as an update" \
  --why "inverts the per-file guard, so a compose file's images are only accumulated when that file has none" \
  --apply 'perl -pi -e "s/-n \\\"\\\$file_images\\\"/-z \\\"\\\$file_images\\\"/" "$F"'

mutation check-image-versions-pinned-images-guard-inverted \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: compose files with no pinned tags are a skip, not an empty check" \
  --why "inverts the empty-list guard, so a repo full of pinned images reports that it found none and skips the check entirely" \
  --apply 'perl -pi -e "s/-z \\\"\\\$all_images\\\"/-n \\\"\\\$all_images\\\"/" "$F"'

mutation check-image-versions-image-list-guard-inverted \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a pinned image with a newer tag is reported as an update" \
  --why "inverts the per-image guard, so every non-empty image reference is dropped and the array is empty by the time the loop that queries registries runs" \
  --apply 'perl -pi -e "s/-n \\\"\\\$img\\\"/-z \\\"\\\$img\\\"/" "$F"'

mutation check-image-versions-cache-hit-guard-inverted \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a cached newer tag is reported without querying the registry" \
  --why "inverts the cache-hit guard, so a stored answer is ignored and the registry is queried anyway: the 24-hour cache keeps being written and is never read, which is the same defect the stat fix closed on the other side" \
  --apply 'perl -pi -e "s/-n \\\"\\\$cached_latest\\\"/-z \\\"\\\$cached_latest\\\"/" "$F"'

mutation check-image-versions-cache-current-or \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a cache entry saying current is not an update" \
  --why "turns the cache comparison into OR; an entry recording current (meaning no update) then differs from the tag, so the cache becomes a source of false update warnings for every image it has already checked" \
  --apply 'perl -pi -e "s/\\\$tag\\\" && \\\"\\\$cached_latest/\\\$tag\\\" || \\\"\\\$cached_latest/" "$F"'

mutation check-image-versions-cache-equal-or \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a cache entry equal to the pinned tag is not an update" \
  --why "the same OR as above, caught by the other side of the comparison: a cached tag equal to the pinned one is reported as an update, which is an update warning for the version already in the compose file" \
  --apply 'perl -pi -e "s/\\\$tag\\\" && \\\"\\\$cached_latest/\\\$tag\\\" || \\\"\\\$cached_latest/" "$F"'

mutation check-image-versions-empty-tags-guard-inverted \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a registry that answers with nothing is counted as skipped" \
  --why "inverts the empty-response guard, so a registry that answered with nothing is not counted as skipped and the summary line hides the fact that part of the check never ran" \
  --apply 'perl -pi -e "s/-z \\\"\\\$tags_list\\\"/-n \\\"\\\$tags_list\\\"/" "$F"'

mutation check-image-versions-latest-guard-inverted \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a pinned image with a newer tag is reported as an update" \
  --why "inverts the found-an-update guard, so a newer tag is cached and then reported as up to date" \
  --apply 'perl -pi -e "s/-n \\\"\\\$latest\\\"/-z \\\"\\\$latest\\\"/" "$F"'

mutation check-image-versions-update-count-guard-inverted \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a pinned image with a newer tag is reported as an update" \
  --why "inverts the update counter, so a run that found updates prints the all-up-to-date line instead" \
  --apply 'perl -pi -e "s/updates -eq 0/updates -ne 0/" "$F"'

mutation check-image-versions-skip-line-always \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: nothing skipped means no skipped line is printed" \
  --why "changes the skipped comparison to -ge 0, which is true at zero too, so the skipped line is printed on every run whether or not anything was skipped - the counter stops carrying information" \
  --apply 'perl -pi -e "s/skipped -gt 0/skipped -ge 0/" "$F"'

mutation check-image-versions-mtime-trusts-stdout-gnu \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a stat that prints a number and fails is not trusted as an mtime" \
  --why "replaces the GNU stat chain's && with ||, so the integer check no longer guards the failure path: a stat that prints a number and exits non-zero is accepted as the mtime instead of degrading to 0, which is the documented reason the check exists" \
  --apply 'perl -pi -e "if ($. == 35) { s/&&/||/ }" "$F"'

mutation check-image-versions-mtime-trusts-stdout-bsd \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a stat that prints a number and fails is not trusted as an mtime" \
  --why "the same || substitution on the BSD line, which is the one that runs on macOS - the platform whose stat -f is the reason the integer check is there at all" \
  --apply 'perl -pi -e "if ($. == 36) { s/&&/||/ }" "$F"'

mutation check-image-versions-ttl-boundary \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: a cache exactly at the TTL boundary is still fresh" \
  --why "changes the staleness comparison to -ge, so a cache written exactly _CACHE_TTL ago is deleted and every commit re-queries all 31 registries from then on" \
  --apply 'perl -pi -e "s/cache_age -gt/cache_age -ge/" "$F"'

mutation check-image-versions-dockerhub-brew-grep \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: _query_dockerhub reads tag names out of the registry JSON" \
  --why "drops -E from the tag-name pattern; in a BRE the + is a literal plus, so no tag name is ever extracted and every Docker Hub image reports no update available, silently and for good" \
  --apply 'perl -pi -e "if ($. == 80) { s/-oE/-o/ }" "$F"'

mutation check-image-versions-ghcr-brew-grep \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: _query_ghcr keeps versioned tags and drops prereleases" \
  --why "drops -E from the GHCR tag pattern, where the ? in [v]? becomes a literal question mark in a BRE, so no GHCR or lscr.io tag is ever extracted" \
  --apply 'perl -pi -e "if ($. == 98) { s/-oE/-o/ }" "$F"'

mutation check-image-versions-query-status-and \
  --file scripts/lib/check-image-versions.sh \
  --bats tests/lib-image-versions.bats \
  --test "image-versions: _query_dockerhub reads tag names out of the registry JSON" \
  --why "turns the failed-query early return into &&, so a query that SUCCEEDED returns 1 before printing anything and every registry response is thrown away - the function fails on exactly the runs that worked" \
  --apply 'perl -pi -e "if ($. == 77) { s/\\|\\| return 1/&& return 1/ }" "$F"'
