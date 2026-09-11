#!/usr/bin/env bats
# scripts/lib/check-yaml-syntax.sh
#
# Validates staged YAML. It has two arms and only one of them ever runs on a
# given machine, which is exactly why both need a test: pi1 has PyYAML, so the
# grep fallback would otherwise be code nobody has executed since it was
# written. `has_pyyaml` is decided by `python3 -c "import yaml"`, so overriding
# python3 is what reaches the second arm.
#
# Seams: this file calls git DIRECTLY rather than through common.sh, so the
# override is on git itself -- `rev-parse --show-toplevel` for the root and
# `diff --cached --name-only` for the staged list.
#
# Which arm a test judges, and on which host:
#
#   * the fallback tests call no_pyyaml(), so they judge the fallback anywhere;
#   * the tests whose assertion is the parser's verdict call require_pyyaml() and
#     skip with a reason where PyYAML is absent, instead of running against the
#     fallback and going red while saying nothing about the code;
#   * the regular-file guard test forces the arm with a stub that answers
#     `import yaml` and delegates the parse, because python3 fails on a
#     directory either way.
#
# Three things pinned here that the file does not currently get right; each is
# marked DEFECT and asserts the FIXED behaviour:
#
#   * `for file in $staged_compose` word-splits, so a staged path containing a
#     space is validated as two paths that do not exist -- and the `|| continue`
#     for a missing file turns that into a silent pass.
#   * :29 interpolates the path into `python3 -c "...open('$p')"`. A quote in
#     the path ends the literal.
#   * `return $errors` puts an unbounded count in a one-byte status. The only
#     caller, scripts/pre-commit:91, reads it as a boolean.

setup() {
    load helpers/setup
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
    source "$REPO_ROOT/scripts/lib/check-yaml-syntax.sh"
    STAGED=()
    git() {
        case "$1 $2" in
            "rev-parse --show-toplevel") echo "$WORK" ;;
            "diff --cached")             printf '%s\n' ${STAGED+"${STAGED[@]}"} ;;
            *) return 1 ;;
        esac
    }
}

yml() {
    local p="$WORK/$1"; shift
    mkdir -p "$(dirname "$p")"
    printf '%s\n' "$@" > "$p"
}

# Force the no-PyYAML arm. `import yaml` is the only thing the file asks
# python3 for before it branches.
no_pyyaml() { python3() { return 1; }; }

# Force the PyYAML arm on a host that has none, for the tests whose assertion
# does not depend on the parser's verdict. `import yaml` is answered here; every
# other call is handed to the real python3, so what runs is still the real
# interpreter -- on a directory it raises IsADirectoryError whether or not yaml
# is installed. A stub that answered the parse call itself would make the test
# an assertion about this stub.
pyyaml_arm_present() { python3() { case "$*" in *"import yaml"*) return 0 ;; esac; command python3 "$@"; }; }

# Skip where the parser's own verdict is the thing under test. Running one of
# those against the fallback is not a weaker version of the same test: the
# fallback cannot report a syntax error at all, only a leading tab, so a pass
# there says nothing and a red there says less.
require_pyyaml() {
    python3 -c 'import yaml' 2>/dev/null \
        || skip "PyYAML is not installed on this host, so the parser's verdict cannot be judged here"
}

# --- staged-file selection --------------------------------------------------

@test "yaml-syntax: nothing staged is a skip, not a pass" {
    STAGED=()
    run check_yaml_syntax
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: No YAML files staged"* ]]
}

@test "yaml-syntax: only .yml and .yaml are considered" {
    STAGED=(notes.md data.json Makefile)
    run check_yaml_syntax
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: No YAML files staged"* ]]
}

@test "yaml-syntax: both extensions are picked up" {
    yml a.yml 'a: 1'
    yml b.yaml 'b: 2'
    STAGED=(a.yml b.yaml)
    run check_yaml_syntax
    [ "$status" -eq 0 ]
    [[ "$output" != *"SKIP"* ]]
}

@test "yaml-syntax: a staged path that no longer exists on disk is not an error" {
    # git reports a rename's old path as staged; validating it would fail for a
    # reason that has nothing to do with YAML.
    STAGED=(deleted.yml)
    run check_yaml_syntax
    [ "$status" -eq 0 ]
    [[ "$output" != *"ERROR"* ]]
}

@test "yaml-syntax: a staged symlink to a directory is skipped, not called invalid YAML" {
    # The guard is "a regular file, or nothing to validate" -- not "anything that
    # exists". The PyYAML arm hands the path to python3 whatever it is, and
    # open() on a directory raises IsADirectoryError before yaml ever sees it,
    # so an existence test reports it as "ERROR: Invalid YAML syntax" and
    # returns 1. scripts/pre-commit:91 counts that as an error and stops the
    # commit, over a path that was never a YAML file. git indexes symlinks, so
    # a symlinked .yml whose target is a directory is a path anyone can stage,
    # which is the threat model this file states for itself.
    #
    # The PyYAML arm is forced, so this runs on any host and its corpus entry
    # can be replayed on any host. That is safe here because the assertion is
    # about the regular-file guard, not about parsing: python3 raises
    # IsADirectoryError on the directory whether or not yaml is installed, and
    # the guard is what stops the call from happening at all.
    mkdir -p "$WORK/realdir"
    ln -s "$WORK/realdir" "$WORK/linked.yml"
    STAGED=(linked.yml)
    pyyaml_arm_present
    run check_yaml_syntax
    [ "$status" -eq 0 ]
    [[ "$output" != *"Invalid YAML"* ]]
}

# --- the PyYAML arm ---------------------------------------------------------

@test "yaml-syntax: valid YAML passes" {
    yml ok.yml 'services:' '  app:' '    image: nginx'
    STAGED=(ok.yml)
    run check_yaml_syntax
    [ "$status" -eq 0 ]
}

@test "yaml-syntax: invalid YAML is reported by name" {
    require_pyyaml
    yml bad.yml 'services:' '  app:' ' image: [unclosed'
    STAGED=(bad.yml)
    run check_yaml_syntax
    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: Invalid YAML syntax in bad.yml"* ]]
}

@test "yaml-syntax: the parser's own message is shown, indented" {
    require_pyyaml
    yml bad.yml 'a: [1, 2'
    STAGED=(bad.yml)
    run check_yaml_syntax
    [ "$status" -eq 1 ]
    # Without this the user gets "invalid" and no clue where. The exact wording
    # is PyYAML's, so match the shape rather than the sentence.
    [[ "$output" == *"      "* ]]
    [[ "$output" == *"line"* ]]
}

@test "yaml-syntax: a duplicate key is NOT caught, and that is worth knowing" {
    # PyYAML's safe_load takes the last value silently. This is the single most
    # likely real compose defect and this check cannot see it -- pinned so the
    # gap is recorded rather than assumed covered.
    require_pyyaml
    yml dup.yml 'a: 1' 'a: 2'
    STAGED=(dup.yml)
    run check_yaml_syntax
    [ "$status" -eq 0 ]
}

# --- the fallback arm -------------------------------------------------------

@test "yaml-syntax: without PyYAML a leading tab is an error" {
    yml tabbed.yml 'services:' "$(printf '\tapp:')"
    STAGED=(tabbed.yml)
    no_pyyaml
    run check_yaml_syntax
    [ "$status" -eq 1 ]
    [[ "$output" == *"Tab characters found in tabbed.yml"* ]]
}

@test "yaml-syntax: without PyYAML a space-indented file passes" {
    yml fine.yml 'services:' '  app:'
    STAGED=(fine.yml)
    no_pyyaml
    run check_yaml_syntax
    [ "$status" -eq 0 ]
}

@test "yaml-syntax: the fallback says how to get the real check" {
    yml fine.yml 'a: 1'
    STAGED=(fine.yml)
    no_pyyaml
    run check_yaml_syntax
    [[ "$output" == *"Install PyYAML"* ]]
}

@test "yaml-syntax: a tab that is not at line start is not flagged" {
    # Only indentation matters to YAML; a tab inside a value is legal.
    yml v.yml "$(printf 'a: one\ttwo')"
    STAGED=(v.yml)
    no_pyyaml
    run check_yaml_syntax
    [ "$status" -eq 0 ]
}

# --- accounting -------------------------------------------------------------

@test "yaml-syntax: two bad files are reported as two" {
    yml b1.yml 'a: [1'
    yml b2.yml 'b: {2'
    require_pyyaml
    STAGED=(b1.yml b2.yml)
    run check_yaml_syntax
    [[ "$output" == *"b1.yml"* ]]
    [[ "$output" == *"b2.yml"* ]]
    [[ "$output" == *"2 file(s) with invalid YAML"* ]]
}

@test "yaml-syntax: DEFECT - the count lives in the message, the status is a boolean" {
    # scripts/pre-commit:91 is `if check_yaml_syntax; then`, so the count never
    # reached anyone; it only ever risked truncating to 0 at 256.
    yml b1.yml 'a: [1'
    yml b2.yml 'b: {2'
    require_pyyaml
    STAGED=(b1.yml b2.yml)
    run check_yaml_syntax
    [ "$status" -eq 1 ]
}

@test "yaml-syntax: DEFECT - a path containing a space is one file, not two" {
    # `for file in $staged_compose` splits on whitespace. Both halves then fail
    # the -f test and `continue`, so an unparseable file passes silently.
    yml 'my stack.yml' 'a: [1'
    require_pyyaml
    STAGED=('my stack.yml')
    run check_yaml_syntax
    [ "$status" -eq 1 ]
    [[ "$output" == *"my stack.yml"* ]]
}

@test "yaml-syntax: DEFECT - a valid file whose path has a quote still passes" {
    # Note which direction this asserts. Against a path holding a quote, the old
    # interpolation raised SyntaxError -- which on an INVALID file produced the
    # right verdict for entirely the wrong reason, and so could not tell the two
    # versions apart. It is the VALID file that separates them: every good file
    # whose name contains an apostrophe was reported as broken YAML.
    yml "it's.yml" 'a: 1'
    require_pyyaml
    STAGED=("it's.yml")
    run check_yaml_syntax
    [ "$status" -eq 0 ]
}

@test "yaml-syntax: DEFECT - a path is data to python, never code" {
    # Staged paths are whatever anyone could `git add`. Interpolated into the
    # -c string they are code. No slash and no space in the payload: a slash
    # would make mkdir read it as directories, and a space would be eaten by the
    # word-splitting bug above before python ever saw it.
    export PWN="$BATS_TEST_TMPDIR/PWNED"
    local payload="x'+__import__('pathlib').Path(__import__('os').environ['PWN']).write_text('')+'.yml"
    yml "$payload" 'a: 1'
    require_pyyaml
    STAGED=("$payload")
    run check_yaml_syntax
    [ ! -f "$BATS_TEST_TMPDIR/PWNED" ]
}
