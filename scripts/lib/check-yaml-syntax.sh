#!/bin/bash
# YAML syntax validation for compose files
# Uses python (usually available) or docker compose config

# Parse one YAML file, quietly. The path goes through argv, NOT into the -c
# string: it used to be interpolated into a single-quoted python literal, so a
# path holding a quote ended the literal and anything after it was executed as
# code. Paths here come from `git diff --cached`, which is to say from whatever
# anyone was able to stage.
_yaml_parses() {
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$1"
}

check_yaml_syntax() {
    local errors=0
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root="."

    # Get staged compose files
    local staged_compose
    staged_compose=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E 'docker-compose.*\.yml$|\.ya?ml$')

    if [[ -z "$staged_compose" ]]; then
        echo "    SKIP: No YAML files staged"
        return 0
    fi

    # Check if PyYAML is available
    local has_pyyaml=false
    if python3 -c "import yaml" 2>/dev/null; then
        has_pyyaml=true
    fi

    # Both arms iterate with `while read`, not `for file in $staged_compose`.
    # Word splitting turns one staged path containing a space into two paths
    # that do not exist, and the `-f ... || continue` on the next line then
    # turns THAT into a silent pass -- an unparseable file waved through
    # because its name had a space in it.
    #
    # The parser is asked twice on failure by design: once quietly for the
    # verdict, once with stderr shown so the user gets the parser's own message
    # rather than a bare "invalid".
    if $has_pyyaml; then
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            [[ -f "$repo_root/$file" ]] || continue
            if ! _yaml_parses "$repo_root/$file"; then
                echo "    ERROR: Invalid YAML syntax in $file"
                _yaml_parses "$repo_root/$file" 2>&1 | head -3 | sed 's/^/      /'
                errors=$((errors + 1))
            fi
        done <<< "$staged_compose"
    else
        # Fallback: basic check with grep for common YAML errors
        while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            [[ -f "$repo_root/$file" ]] || continue
            # Check for tabs at line start (YAML uses spaces). A literal tab
            # needs no GNU -P: it matches in BRE and ERE alike, so -P bought
            # nothing and cost this check its ability to fail at all on a host
            # without GNU grep. BSD grep exits 2 with "invalid option", the
            # 2>/dev/null discarded that, and the `if` read the non-zero status
            # as "no tab found". This is the fallback arm, so the hosts it went
            # quiet on are the ones with no PyYAML either: the ones with no
            # second opinion available.
            if grep -q $'^\t' "$repo_root/$file" 2>/dev/null; then
                echo "    ERROR: Tab characters found in $file (YAML requires spaces)"
                errors=$((errors + 1))
            fi
        done <<< "$staged_compose"
        echo "    NOTE: Install PyYAML for full validation: pip install pyyaml"
    fi

    if [[ $errors -eq 0 ]]; then
        return 0
    fi

    # Count in the message, boolean in the status -- `return $errors` truncates
    # to one byte, and scripts/pre-commit:91 is `if check_yaml_syntax; then`, so
    # the count was only ever a liability there.
    echo "    ERROR: $errors file(s) with invalid YAML"
    return 1
}
