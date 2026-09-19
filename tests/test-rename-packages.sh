#!/usr/bin/env bash
# Tests for .github/scripts/rename-packages.sh
#
# Run from repo root:
#   bash tests/test-rename-packages.sh
#
# The release path runs only on pushes to main, so a regression here first
# appears as a published release with the wrong assets. These tests are the
# only pre-merge signal.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/.github/scripts/rename-packages.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "rename-packages.sh not found at $SCRIPT" >&2
    exit 2
fi

PASSES=0
FAILS=0
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; RESET=""
fi

run_test() {
    local name="$1"
    local out
    if out=$("$name" 2>&1); then
        PASSES=$((PASSES + 1))
        printf '%sPASS%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAILS=$((FAILS + 1))
        printf '%sFAIL%s %s\n%s\n' "$RED" "$RESET" "$name" "$out"
    fi
}

# Stage a scratch workspace with the given files, run the script in it, echo the dir.
run_rename() {
    local dir
    dir="$(mktemp -d "$TMPDIR_ROOT/case.XXXXXX")"
    mkdir -p "$dir/build" "$dir/.github/scripts"
    cp "$SCRIPT" "$dir/.github/scripts/"
    echo "payload" > "$dir/build/halos-core-containers_0.2.1-1_all.deb"
    # The build-deb action leaves an unsuffixed copy at the root for the shared
    # workflows' root-level lintian glob.
    [ "${1:-}" = "with-root-copy" ] && cp "$dir/build/"*.deb "$dir/"

    (cd "$dir" && ./.github/scripts/rename-packages.sh \
        --version 0.2.1-1 --distro trixie --component main >/dev/null 2>&1) || return 1
    echo "$dir"
}

# ---------------------------------------------------------------------------

test_package_gets_the_suffix() {
    local dir
    dir="$(run_rename)" || return 1
    [ -f "$dir/halos-core-containers_0.2.1-1_all+trixie+main.deb" ] || {
        echo "renamed package missing; root holds: $(ls "$dir"/*.deb 2>/dev/null)" >&2
        return 1
    }
}

test_root_copy_does_not_become_a_second_release_asset() {
    local dir count
    dir="$(run_rename with-root-copy)" || return 1
    # build-release.yml collects assets with ASSETS=(*.deb) at the root, so any
    # leftover unsuffixed copy is published alongside the real one.
    count=$(ls "$dir"/*.deb 2>/dev/null | wc -l | tr -d ' ')
    if [ "$count" != "1" ]; then
        echo "expected exactly one .deb at the root, found ${count}:" >&2
        ls "$dir"/*.deb >&2
        return 1
    fi
    [ -f "$dir/halos-core-containers_0.2.1-1_all+trixie+main.deb" ] || {
        echo "the surviving package is not the suffixed one" >&2
        return 1
    }
}

run_test test_package_gets_the_suffix
run_test test_root_copy_does_not_become_a_second_release_asset

echo ""
echo "Passed: $PASSES   Failed: $FAILS"
[ "$FAILS" -eq 0 ]
