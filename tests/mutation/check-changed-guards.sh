#!/bin/bash
# Run only the corpus entries that guard the files this change touched.
#
# Why not the whole corpus: 271 entries, each running its oracle twice. Why this
# exists at all: run-mutations.sh is this repo's proof that its guards can fail,
# and no workflow referenced it, so the corpus could go inert unnoticed.
#
# Two refusals, both deliberate:
#   * an unresolvable base is an error, not a silent no-op -- a gate that cannot
#     tell what changed has not passed, it has not run;
#   * a run where every selected mutation was SKIPPED is an error. run-mutations.sh
#     exits 0 on an all-skipped run (only SURVIVED/ERRORED are non-zero), which is
#     the same "a skip reads as a clean run" trap the rest of this repo closes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
BASE="${1:-origin/main}"

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "check-changed-guards: base '$BASE' does not resolve, so the changed set is unknown" >&2
    echo "check-changed-guards: refusing to report success for a gate that could not run" >&2
    exit 1
fi

changed=$(git diff --name-only "$BASE"...HEAD 2>/dev/null || true)
if [[ -z "$changed" ]]; then
    echo "check-changed-guards: no files changed against $BASE"
    exit 0
fi

corpora=()
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    for c in tests/mutation/corpus/*.sh; do
        grep -qF -- "--file $f" "$c" || continue
        case " ${corpora[*]-} " in *" $c "*) ;; *) corpora+=("$c") ;; esac
    done
done <<<"$changed"

if [[ ${#corpora[@]} -eq 0 ]]; then
    echo "check-changed-guards: no changed file is guarded by a corpus entry"
    exit 0
fi

echo "check-changed-guards: ${#corpora[@]} corpus file(s) guard this change:"
printf '  %s\n' "${corpora[@]}"

out=$(mktemp)
trap 'rm -f "$out"' EXIT
set +e
./tests/mutation/run-mutations.sh "${corpora[@]}" 2>&1 | tee "$out"
rc=${PIPESTATUS[0]}
set -e

summary=$(grep -E '^killed [0-9]+ / [0-9]+' "$out" | tail -1 || true)
killed=$(sed -nE 's/^killed ([0-9]+) \/.*/\1/p' <<<"$summary")
if [[ -z "$killed" ]]; then
    echo "check-changed-guards: could not read the runner's summary line" >&2
    exit 1
fi
if [[ "$killed" -eq 0 ]]; then
    echo "check-changed-guards: every selected mutation was SKIPPED - the oracle is not available" >&2
    echo "check-changed-guards: on this host, so this run proved nothing about the guards it named" >&2
    exit 1
fi

exit "$rc"
