#!/usr/bin/env bats
# scripts/lib/check-doc-links.sh
#
# Walks every tracked .md file and resolves its internal links. Two seams are
# enough to drive it: `git ls-files` (the file list) and get_repo_root (where
# the paths are resolved from). Both are overridden here against a throwaway
# docs tree, so no test depends on the real repo's documentation staying still
# -- a test that asserted "the repo's own links are valid" would go red for
# reasons that have nothing to do with this file.
#
# Two things this file pins that the code does not currently get right, marked
# DEFECT where the assertion encodes the FIXED behaviour:
#
#   * `return $errors` puts an unbounded count into a one-byte exit status, so
#     256 broken links returns 0 and the hook says the docs are fine. The only
#     call site, scripts/pre-commit:174, is `if check_doc_links; then` -- it
#     reads the value as a boolean and always did, so the count was never
#     reaching anyone. It moves into the message, where it can be any size.
#   * :119 interpolates a path straight into `python3 -c "...normpath('$p')"`.
#     A path holding a single quote ends the string; the repo's own docs are
#     the input so the threat model is small, but the shape is the same one
#     that CVEs are written about, and passing argv costs nothing.

setup() {
    load helpers/setup
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    DOCS="$BATS_TEST_TMPDIR/docs"
    mkdir -p "$DOCS"
    source "$REPO_ROOT/scripts/lib/common.sh"
    source "$REPO_ROOT/scripts/lib/check-doc-links.sh"
    _REPO_ROOT="$DOCS"
    get_repo_root() { echo "$DOCS"; }
    # The file list seam. check_doc_links calls `git ls-files '*.md'` directly
    # rather than going through common.sh, so the override has to be on git.
    git() { [[ "$1" == "ls-files" ]] && printf '%s\n' "${MD_FILES[@]}"; }
}

# doc <relative-path> <content...>
doc() {
    local p="$DOCS/$1"; shift
    mkdir -p "$(dirname "$p")"
    printf '%s\n' "$@" > "$p"
}

# --- _heading_to_anchor: the GitHub slug rules ------------------------------

@test "doc-links: a heading becomes a lowercase hyphenated anchor" {
    run _heading_to_anchor "## Step 4: Configure Each App"
    [ "$output" = "step-4-configure-each-app" ]
}

@test "doc-links: punctuation is dropped, not hyphenated" {
    run _heading_to_anchor "### Don't Panic!"
    [ "$output" = "dont-panic" ]
}

@test "doc-links: underscores and existing hyphens survive" {
    run _heading_to_anchor "# my_thing-here"
    [ "$output" = "my_thing-here" ]
}

@test "doc-links: the leading hashes and their space are stripped at any depth" {
    run _heading_to_anchor "###### Deep"
    [ "$output" = "deep" ]
}

# --- _get_file_anchors ------------------------------------------------------

@test "doc-links: anchors come from headings and from HTML anchor tags alike" {
    doc a.md '# One' 'text' '## Two Words' '<a id="manual-anchor"></a>' '<a name="other"></a>'
    run _get_file_anchors "$DOCS/a.md"
    [[ "$output" == *"one"* ]]
    [[ "$output" == *"two-words"* ]]
    [[ "$output" == *"manual-anchor"* ]]
    [[ "$output" == *"other"* ]]
}

@test "doc-links: a line of hashes with no space is not a heading" {
    doc a.md '#### ' '#nothash' '# real'
    run _get_file_anchors "$DOCS/a.md"
    [[ "$output" != *"nothash"* ]]
}

# --- check_doc_links: the golden path ---------------------------------------

@test "doc-links: a valid file link and a valid anchor both pass" {
    doc a.md '# A' 'see [b](b.md) and [sec](b.md#section-two)'
    doc b.md '# B' '## Section Two'
    MD_FILES=(a.md b.md)
    run check_doc_links
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK: All internal doc links valid"* ]]
}

@test "doc-links: no markdown at all is a skip, not a pass" {
    MD_FILES=()
    run check_doc_links
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP: No markdown files found"* ]]
}

# --- check_doc_links: what it must catch ------------------------------------

@test "doc-links: a link to a file that does not exist is an error" {
    doc a.md '# A' 'see [gone](missing.md)'
    MD_FILES=(a.md)
    run check_doc_links
    [ "$status" -eq 1 ]
    [[ "$output" == *"1 broken internal doc link"* ]]
    [[ "$output" == *"broken link to 'missing.md'"* ]]
    [[ "$output" == *"a.md:2"* ]]
}

@test "doc-links: an anchor that does not exist in an existing file is an error" {
    doc a.md '# A' 'see [x](b.md#no-such-heading)'
    doc b.md '# B'
    MD_FILES=(a.md b.md)
    run check_doc_links
    [ "$status" -eq 1 ]
    [[ "$output" == *"broken anchor '#no-such-heading'"* ]]
}

@test "doc-links: an anchor must match a heading exactly, not as a substring" {
    # "sec" is a prefix of "section-two". A substring match would call this
    # link valid, and the reader would land at the top of the page instead.
    doc a.md '# A' '[x](b.md#sec)'
    doc b.md '# B' '## Section Two'
    MD_FILES=(a.md b.md)
    run check_doc_links
    [ "$status" -eq 1 ]
    [[ "$output" == *"broken anchor '#sec'"* ]]
}

@test "doc-links: an anchor is matched literally, not as a regular expression" {
    # A dot in an anchor is a dot. Treated as a regex it matches any character,
    # so "a.b" would silently accept the unrelated heading "aXb".
    doc a.md '# A' '[x](b.md#a.b)'
    doc b.md '# B' '## aXb'
    MD_FILES=(a.md b.md)
    run check_doc_links
    [ "$status" -eq 1 ]
    [[ "$output" == *"broken anchor '#a.b'"* ]]
}

@test "doc-links: an anchor-only link resolves against the file it appears in" {
    doc a.md '# A' '## Local Section' 'jump to [here](#local-section)' 'and [nope](#absent)'
    MD_FILES=(a.md)
    run check_doc_links
    [ "$status" -eq 1 ]
    [[ "$output" == *"broken anchor '#absent'"* ]]
    [[ "$output" != *"local-section"* ]]
}

@test "doc-links: a relative link is resolved from the linking file's directory" {
    doc sub/a.md '# A' 'up to [root](../root.md)' 'sideways to [sib](sib.md)'
    doc root.md '# Root'
    doc sub/sib.md '# Sib'
    MD_FILES=(sub/a.md root.md sub/sib.md)
    run check_doc_links
    [ "$status" -eq 0 ]
}

@test "doc-links: a relative link that escapes to nothing is still an error" {
    doc sub/a.md '# A' '[bad](../nowhere.md)'
    MD_FILES=(sub/a.md)
    run check_doc_links
    [ "$status" -eq 1 ]
    [[ "$output" == *"broken link"* ]]
}

# --- check_doc_links: what it must NOT flag ---------------------------------

@test "doc-links: external and mailto links are never checked" {
    doc a.md '# A' '[web](https://example.com/x.md)' '[mail](mailto:a@b.md)' '[http](http://x/y.md)'
    MD_FILES=(a.md)
    run check_doc_links
    [ "$status" -eq 0 ]
}

@test "doc-links: non-markdown targets are skipped entirely" {
    doc a.md '# A' '[script](scripts/nope.sh)' '[conf](x.yml)' '[env](.env)'
    MD_FILES=(a.md)
    run check_doc_links
    [ "$status" -eq 0 ]
}

@test "doc-links: image references are skipped even when missing" {
    doc a.md '# A' '![shot](img/absent.png)' '[d](d.svg)'
    MD_FILES=(a.md)
    run check_doc_links
    [ "$status" -eq 0 ]
}

@test "doc-links: links inside a fenced code block are not checked" {
    doc a.md '# A' '```' '[example](does-not-exist.md)' '```' 'real text'
    MD_FILES=(a.md)
    run check_doc_links
    [ "$status" -eq 0 ]
}

@test "doc-links: the fence toggles, so a link after the closing fence IS checked" {
    # The bug this guards against is a one-way switch: set in_code_block and
    # never clear it, and every link below the first fence in a file silently
    # stops being checked. That is invisible in a passing run.
    doc a.md '# A' '```' 'code' '```' '[gone](nope.md)'
    MD_FILES=(a.md)
    run check_doc_links
    [ "$status" -eq 1 ]
    [[ "$output" == *"broken link to 'nope.md'"* ]]
}

@test "doc-links: a language-tagged fence still opens a block" {
    doc a.md '# A' '```bash' '[example](does-not-exist.md)' '```'
    MD_FILES=(a.md)
    run check_doc_links
    [ "$status" -eq 0 ]
}

# --- accounting -------------------------------------------------------------

@test "doc-links: two broken links in one file are counted as two" {
    doc a.md '# A' '[x](one.md)' '[y](two.md)'
    MD_FILES=(a.md)
    run check_doc_links
    [[ "$output" == *"2 broken internal doc link"* ]]
}

@test "doc-links: broken links are counted across files, not per file" {
    doc a.md '# A' '[x](one.md)'
    doc b.md '# B' '[y](two.md)'
    MD_FILES=(a.md b.md)
    run check_doc_links
    [[ "$output" == *"2 broken internal doc link"* ]]
}

@test "doc-links: DEFECT - the count lives in the message, the status is a boolean" {
    # This is the whole no-wrap property, tested for the price of two links
    # rather than 256: if the status still carried the count it would be 2 here.
    # An unbounded count in a one-byte status is 0 at exactly 256, which is the
    # one input where the hook would say the docs are fine because there are so
    # many broken links.
    doc a.md '# A' '[x](one.md)' '[y](two.md)'
    MD_FILES=(a.md)
    run check_doc_links
    [ "$status" -eq 1 ]
}

@test "doc-links: DEFECT - a path is data to python, never code" {
    # :119 built `python3 -c "...normpath('$check_file')"`. The path is not a
    # constant: it comes from `git ls-files`, so it is whatever anyone was able
    # to commit -- and interpolated into the -c string it is CODE, not data.
    #
    # The first thing tried here was a path holding a plain apostrophe, which
    # proves nothing: normpath("it's/b.md") returns its argument unchanged, so
    # the SyntaxError falls through to `|| echo "$check_file"` and BOTH versions
    # produce the same answer. The mutation testing caught that -- the entry
    # survived. A payload with an observable side effect is the only assertion
    # that can separate them.
    #
    # No slash in the payload, or mkdir would read it as nested directories, so
    # the target path arrives via the environment instead.
    export PWN="$BATS_TEST_TMPDIR/PWNED"
    local payload="x'+__import__('pathlib').Path(__import__('os').environ['PWN']).write_text('')+'"
    doc "$payload/a.md" '# A' '[sib](b.md)'
    doc "$payload/b.md" '# B'
    MD_FILES=("$payload/a.md" "$payload/b.md")
    run check_doc_links
    [ ! -f "$BATS_TEST_TMPDIR/PWNED" ]
}

# --- this repository's own documentation ------------------------------------
#
# Every test above fixtures the file list, so the checker's own behaviour is
# covered and this repo's actual markdown never was. Until now a broken link in
# these docs was caught only by scripts/pre-commit, which runs on a developer's
# commit -- and the deploy workflow runs the bats suite, not the hook. This
# closes the gap where the coverage already lives.

@test "doc-links: every link in this repository's own markdown resolves" {
    # ORDER MATTERS: setup() installs a `git()` FUNCTION as the fixture seam, and
    # `command -v git` is happy to report a function. Checking before unsetting it
    # made this test skip-proof and then fail on a host with no git at all -- the
    # NAS -- because the probe passed and the real binary did not exist.
    unset -f git
    get_repo_root() { echo "$REPO_ROOT"; }

    command -v git >/dev/null 2>&1 \
        || skip "no host git binary: check_doc_links enumerates files with git ls-files, so it would find none here and report a skip"

    local md_list
    if ! md_list=$(cd "$REPO_ROOT" && git ls-files '*.md' 2>/dev/null); then
        skip "git is present but cannot enumerate this repo here (safe.directory?), so check_doc_links would report a skip rather than a result"
    fi
    # git works and still found no markdown: that is a defect in the repo, not an
    # environment gap, and it would otherwise pass this test while checking nothing.
    [[ -n "$md_list" ]] \
        || { echo "git enumerated no markdown in this repo, so the checker would skip and this test would pass having checked nothing"; return 1; }

    cd "$REPO_ROOT" || return 1
    run check_doc_links
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -20; return 1; }
    [[ "$output" == *"OK: All internal doc links valid"* ]] \
        || { echo "the checker neither failed nor reported success: $output"; return 1; }
}

