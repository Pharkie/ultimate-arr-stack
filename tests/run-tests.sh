#!/bin/bash
# BATS test runner for arr-stack
# Usage: ./tests/run-tests.sh [test-file.bats ...]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Check for bats submodule
BATS="$SCRIPT_DIR/bats-core/bin/bats"
if [[ ! -x "$BATS" ]]; then
    echo "BATS not found. Initializing submodules..."
    git -C "$REPO_ROOT" submodule update --init --recursive tests/bats-core tests/bats-support tests/bats-assert
    if [[ ! -x "$BATS" ]]; then
        echo "ERROR: Failed to install BATS. Check git submodules."
        exit 1
    fi
fi

# TAP output is kept so the census below can count it. `tee` keeps it streaming and
# PIPESTATUS keeps bats's own exit status, so nothing observable about the run changes.
TAP="$(mktemp)"
trap 'rm -f "$TAP"' EXIT

set +e
if [[ $# -gt 0 ]]; then
    "$BATS" "$@" 2>&1 | tee "$TAP"
else
    "$BATS" "$SCRIPT_DIR"/*.bats 2>&1 | tee "$TAP"
fi
rc="${PIPESTATUS[0]}"
set -e

# The census.
#
# A run that says "ok" hundreds of times while skipping the tests that matter reads
# exactly like full coverage. On the NAS, 57 tests skip for want of a host git
# binary -- which is the whole NAS-sync and hook path -- and 5 more skip because
# network-segmentation.bats needs a VLAN20 address. The mutation ledger has the same
# hole, where an all-skipped corpus run is a SKIPPED verdict rather than a kill.
# Print the numbers, and say out loud what produced no verdict here.
ok=$(grep -cE '^ok ' "$TAP" || true)
skipped=$(grep -cE '^ok .*# skip' "$TAP" || true)
failed=$(grep -cE '^not ok ' "$TAP" || true)
executed=$((ok - skipped))

echo
echo "=== census: executed=${executed} skipped=${skipped} failed=${failed} ==="
if [[ "$skipped" -gt 0 ]]; then
    echo "=== skipped, by reason:"
    grep -oE '# skip .*' "$TAP" | sed 's/# skip //' | sort | uniq -c | sort -rn | sed 's/^/===   /'
fi
if grep -q 'no host git binary' "$TAP"; then
    echo "=== NOTE: the git-gated tests produced no verdict on this host (no host git binary)."
    echo "===       Run the suite on a git-capable host (pi1) too before reading this as coverage."
fi

exit "$rc"
