#!/bin/bash
# YAML syntax validation for compose files
#
# Resolution order for a validator, best first:
#   1. PyYAML via the repo-local .venv  (created by ./setup-hooks.sh)
#   2. PyYAML via whatever python3 is on PATH
#   3. `docker compose config -q`
#   4. nothing — and in that case this reports SKIPPED, not OK
#
# The .venv step exists because macOS ships an externally-managed Python
# (PEP 668), so `pip install pyyaml` refuses to touch the system interpreter
# and the hook silently ran degraded on the one machine where commits happen.

# Find a python3 that can actually import yaml. Echoes the interpreter path
# and returns 0, or returns 1 if there isn't one.
_find_python_with_yaml() {
    local repo_root candidate
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root="."
    for candidate in "$repo_root/.venv/bin/python3" python3; do
        if command -v "$candidate" >/dev/null 2>&1 &&
           "$candidate" -c "import yaml" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

check_yaml_syntax() {
    local errors=0
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root="."

    local staged_compose
    staged_compose=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep -E '\.ya?ml$')

    if [[ -z "$staged_compose" ]]; then
        echo "    SKIP: No YAML files staged"
        return 0
    fi

    local py
    if py=$(_find_python_with_yaml); then
        local file err
        for file in $staged_compose; do
            [[ -f "$repo_root/$file" ]] || continue
            # Report the parser's own message, not a Python traceback — the
            # traceback's first three lines are boilerplate and push the
            # useful "line N, column M" detail out of view.
            if ! err=$("$py" -c '
import sys, yaml
try:
    yaml.safe_load(open(sys.argv[1]))
except yaml.YAMLError as e:
    sys.exit(str(e))
' "$repo_root/$file" 2>&1); then
                echo "    ERROR: Invalid YAML syntax in $file"
                echo "$err" | head -4 | sed 's/^/      /'
                ((errors++)) || true
            fi
        done
        [[ $errors -eq 0 ]] && echo "    OK: YAML syntax valid (PyYAML via $py)"
        return $errors
    fi

    # Fallback: docker compose can parse them even without PyYAML present.
    if docker compose version >/dev/null 2>&1; then
        local file
        for file in $staged_compose; do
            [[ -f "$repo_root/$file" ]] || continue
            case "$file" in docker-compose*.yml) ;; *) continue ;; esac
            if ! docker compose -f "$repo_root/$file" \
                   --env-file "$repo_root/tests/fixtures/.env.test" --profile '*' config -q >/dev/null 2>&1; then
                echo "    ERROR: $file failed docker compose config"
                ((errors++)) || true
            fi
        done
        [[ $errors -eq 0 ]] && echo "    OK: YAML syntax valid (docker compose config)"
        return $errors
    fi

    # Nothing available. Say so plainly — the old code ran a `grep -qP` tab
    # check here, but -P is a GNU extension that BSD grep rejects outright, so
    # on macOS it checked nothing and still reported "YAML syntax valid".
    echo "    SKIPPED: no YAML validator available — nothing was checked."
    echo "             Run ./setup-hooks.sh to create .venv with PyYAML."
    return 0
}
