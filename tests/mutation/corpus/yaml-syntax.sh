# shellcheck shell=bash
# (sourced by run-mutations.sh, never executed - hence a directive, not a shebang)
# Mutations for scripts/lib/check-yaml-syntax.sh.
#
# Safe to run: tests/lib-yaml-syntax.bats overrides git for both the repo root
# and the staged list, so every mutation reads only $BATS_TEST_TMPDIR. The
# no-PyYAML arm is reached by overriding python3, not by uninstalling anything.
#
# Four entries below name tests that require PyYAML (yaml-count-as-exit-status,
# yaml-staged-list-word-split, yaml-path-in-python-string). Those tests skip with
# a reason where it is absent, and a skipped oracle reads as a pass, so replaying
# them on a host without PyYAML reports SURVIVED and means nothing. CI and pi1
# have it; this file says so rather than leaving the next reader to guess.

mutation yaml-count-as-exit-status \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: DEFECT - the count lives in the message, the status is a boolean" \
  --why "restores 'return \$errors'. An unbounded count in a one-byte status is 0 at exactly 256, and scripts/pre-commit:91 reads it as a boolean, so the count only ever risked inverting the verdict" \
  --apply 'perl -0pi -e "s/    echo \\\"    ERROR: \\\$errors file\\(s\\) with invalid YAML\\\"\n    return 1\n/    return \\\$errors\n/" "$F"'

mutation yaml-staged-list-word-split \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: DEFECT - a path containing a space is one file, not two" \
  --why "restores 'for file in \$staged_compose' in the PyYAML arm. A staged path containing a space becomes two paths that do not exist, and the '-f || continue' on the next line converts that into a silent pass - the file is never parsed and the check reports OK" \
  --apply 'perl -0pi -e "s/        while IFS= read -r file; do\n            \[\[ -n \\\"\\\$file\\\" \]\] \|\| continue\n            \[\[ -f \\\"\\\$repo_root\/\\\$file\\\" \]\] \|\| continue\n            if ! _yaml_parses/        for file in \\\$staged_compose; do\n            [[ -f \\\"\\\$repo_root\/\\\$file\\\" ]] || continue\n            if ! _yaml_parses/; s/                errors=\\\$\\(\\(errors \+ 1\\)\\)\n            fi\n        done <<< \\\"\\\$staged_compose\\\"\n    else/                errors=\\\$((errors + 1))\n            fi\n        done\n    else/" "$F"'

mutation yaml-path-in-python-string \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: DEFECT - a path is data to python, never code" \
  --why "puts the path back inside the python -c string. Staged paths are whatever anyone could git add, so inside the -c string they are code. The side effect is what proves it: on an INVALID file the interpolation still produces the right verdict, by SyntaxError rather than by parsing, so a test asserting only the verdict cannot see this at all" \
  --apply $'perl -0pi -e "s/    python3 -c .import sys, yaml; yaml.safe_load\\\\(open\\\\(sys.argv\\\\[1\\\\]\\\\)\\\\). \\\\\\"\\\\\\$1\\\\\\"/    python3 -c \\\\\\"import yaml; yaml.safe_load(open(\'\\\\\\$1\'))\\\\\\"/" "$F"'

mutation yaml-fallback-tab-anywhere \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: a tab that is not at line start is not flagged" \
  --why "drops the line-start anchor, so a tab anywhere in a file is called an indentation error. Only indentation matters to YAML; a tab inside a value is legal, so this rejects valid compose files on the machines that have no PyYAML - exactly the machines with no second opinion available" \
  --apply 'python3 -c "import sys;p=sys.argv[1];s=open(p).read();old=\"grep -q \x24\x27^\\\\t\x27\";new=\"grep -q \x24\x27\\\\t\x27\";assert old in s, old;s=s.replace(old,new,1);open(p,\"w\").write(s)" "$F"' \

mutation yaml-fallback-never-runs \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: without PyYAML a leading tab is an error" \
  --why "hardcodes has_pyyaml=true, so on a machine without PyYAML the parse silently fails for every file and the grep fallback - the only check those machines get - is never reached" \
  --apply 'sed -i "s@^    local has_pyyaml=false\$@    local has_pyyaml=true@" "$F"'

# --- Entries below close gaps the generative sweep found, not gaps anyone
# --- thought of first.

# \x24 rather than \$ in the --apply below: the value is inside single quotes, so
# a backslash before $ survives the shell and perl then reads $repo_root as one of
# its OWN variables, expands it to nothing, and leaves a pattern matching no line -
# an inert mutation, which the runner scores ERROR rather than a kill. \x24 is the
# same character and means nothing to either shell.
mutation yaml-existence-test-not-regular-file \
  --file scripts/lib/check-yaml-syntax.sh \
  --bats tests/lib-yaml-syntax.bats \
  --test "yaml-syntax: a staged symlink to a directory is skipped, not called invalid YAML" \
  --why "swaps the regular-file guard for an existence one in both arms, so a staged path that exists but is not a regular file reaches the parser. The PyYAML arm hands it to python3 whatever it is and open() on a directory raises IsADirectoryError before yaml sees it, so the check reports 'Invalid YAML syntax in <name>' and returns 1 - which scripts/pre-commit:91 counts as an ERROR and blocks the commit on. git indexes symlinks, so a symlinked .yml pointing at a directory is a path anyone can stage" \
  --apply 'perl -pi -e "s/\[\[ -f \"\x24repo_root\/\x24file\" \]\] \|\| continue/[[ -e \"\x24repo_root\/\x24file\" ]] || continue/" "$F"'
