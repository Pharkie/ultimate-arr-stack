# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/check-doc-links.sh.
#
# Safe to run: the tests in tests/lib-doc-links.bats build a throwaway docs tree
# under $BATS_TEST_TMPDIR and override both `git ls-files` and get_repo_root, so
# no mutation here reads the repo's own markdown -- except the entry at the
# bottom, which deliberately does: it breaks a link in a real doc, and the
# runner restores that file from a byte copy like any other target.

mutation doc-links-count-as-exit-status \
  --file scripts/lib/check-doc-links.sh \
  --bats tests/lib-doc-links.bats \
  --test "doc-links: DEFECT - the count lives in the message, the status is a boolean" \
  --why "restores 'return \$errors', which puts an unbounded count into a one-byte exit status. At exactly 256 broken links the hook is told the docs are fine - and the worse the docs get, the more likely that is. The only caller, scripts/pre-commit:174, reads the value as a boolean, so the count was never reaching anyone through the status in the first place" \
  --apply 'perl -0pi -e "s/    echo \\\"    ERROR: \\\$errors broken internal doc link\\(s\\)\\\"\n    return 1\n/    return \\\$errors\n/" "$F"'

mutation doc-links-path-in-python-string \
  --file scripts/lib/check-doc-links.sh \
  --bats tests/lib-doc-links.bats \
  --test "doc-links: DEFECT - a path is data to python, never code" \
  --why "puts the path back inside the python -c string literal. The path comes from git ls-files, so it is whatever anyone could commit, and inside the -c string it is code rather than data. Note what the FIRST version of this entry taught: an apostrophe alone proves nothing, because normpath returns such a path unchanged and the || echo fallback lands on the same answer. Only a payload with a side effect separates the two" \
  --apply 'perl -0pi -e "s/    check_file=\\\$\\(python3 -c \\\\\n                        .import os.path, sys; print\\(os.path.normpath\\(sys.argv\\[1\\]\\)\\). \\\\\n                        \\\"\\\$check_file\\\" 2>\\/dev\\/null \|\| echo \\\"\\\$check_file\\\"\\)/    check_file=\\\$(python3 -c \\\"import os.path; print(os.path.normpath(\x27\\\$check_file\x27))\\\" 2>\/dev\/null || echo \\\"\\\$check_file\\\")/" "$F"'

mutation doc-links-fence-is-one-way \
  --file scripts/lib/check-doc-links.sh \
  --bats tests/lib-doc-links.bats \
  --test "doc-links: the fence toggles, so a link after the closing fence IS checked" \
  --why "makes the code-fence flag set-only. Every link below the first fenced block in a file then stops being checked, which is invisible in a green run: the check keeps reporting OK while covering less and less of each document as examples are added" \
  --apply 'perl -0pi -e "s/                if \\\$in_code_block; then\n                    in_code_block=false\n                else\n                    in_code_block=true\n                fi\n/                in_code_block=true\n/" "$F"'

mutation doc-links-anchor-substring-match \
  --file scripts/lib/check-doc-links.sh \
  --bats tests/lib-doc-links.bats \
  --test "doc-links: an anchor must match a heading exactly, not as a substring" \
  --why "drops the whole-line match, so any anchor that is a substring of a real one is accepted. '#sec' would validate against '#section-two' and the reader lands somewhere else on the page - a broken link that reports as working" \
  --apply 'sed -i "s@grep -qFx -- \"\$target_anchor\"@grep -qF -- \"\$target_anchor\"@" "$F"'

mutation doc-links-anchor-as-regex \
  --file scripts/lib/check-doc-links.sh \
  --bats tests/lib-doc-links.bats \
  --test "doc-links: an anchor is matched literally, not as a regular expression" \
  --why "drops the fixed-string flag, so an anchor is compiled as a regex. Dots are common in anchors and match any character, so unrelated headings validate unrelated links" \
  --apply 'sed -i "s@grep -qFx -- \"\$target_anchor\"@grep -qx -- \"\$target_anchor\"@" "$F"'

mutation doc-links-external-links-checked \
  --file scripts/lib/check-doc-links.sh \
  --bats tests/lib-doc-links.bats \
  --test "doc-links: external and mailto links are never checked" \
  --why "removes the external-URL skip, so an https URL ending in .md is resolved as a repo-relative path and every documentation link to another project is reported broken. A check that cries wolf on correct links is worse than no check: it trains the reader to pass --no-verify" \
  --apply 'perl -0pi -e "s/                    http:\/\/\*\|https:\/\/\*\|mailto:\*\) continue ;;\n/                    :) continue ;;\n/" "$F"'

mutation doc-links-this-repos-own-markdown \
  --file docs/REFERENCE.md \
  --bats tests/lib-doc-links.bats \
  --test "doc-links: every link in this repository's own markdown resolves" \
  --why "appends a link to a file that does not exist. Nothing else in the suite reads this repo's own markdown, so before that test existed the only thing that would have noticed a broken doc link was scripts/pre-commit -- which runs on a developer's commit and never in the deploy workflow, while the NAS cannot run it at all because it enumerates with git ls-files and has no host git" \
  --apply 'printf "\n[bogus](no-such-file-xyz.md)\n" >> "$F"'

