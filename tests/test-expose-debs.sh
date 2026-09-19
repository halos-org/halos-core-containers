#!/usr/bin/env bash
# Tests for tools/expose-debs.sh
#
# Run from repo root:
#   bash tests/test-expose-debs.sh
#
# The guard is the reason the script exists: it turns "lintian inspected
# nothing" from a silent pass into a failure. CI only ever exercises the
# success path, so the failure path is tested here or nowhere.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/tools/expose-debs.sh"

if [ ! -f "$SCRIPT" ]; then
    echo "expose-debs.sh not found at $SCRIPT" >&2
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

# ---------------------------------------------------------------------------

test_packages_are_copied_to_the_destination() {
    local dir
    dir="$(mktemp -d "$TMPDIR_ROOT/ok.XXXXXX")"
    mkdir -p "$dir/build" "$dir/root"
    echo payload > "$dir/build/one_1.0-1_all.deb"
    echo payload > "$dir/build/two_1.0-1_all.deb"

    bash "$SCRIPT" "$dir/build" "$dir/root" >/dev/null 2>&1 || return 1

    [ -f "$dir/root/one_1.0-1_all.deb" ] && [ -f "$dir/root/two_1.0-1_all.deb" ] || {
        echo "packages not copied; destination holds: $(ls "$dir/root")" >&2
        return 1
    }
    # The originals stay put: rename-packages.sh works from build/.
    [ -f "$dir/build/one_1.0-1_all.deb" ] || {
        echo "the build directory was emptied" >&2
        return 1
    }
}

test_empty_build_dir_fails_loudly() {
    local dir out status
    dir="$(mktemp -d "$TMPDIR_ROOT/empty.XXXXXX")"
    mkdir -p "$dir/build" "$dir/root"

    out=$(bash "$SCRIPT" "$dir/build" "$dir/root" 2>&1) && status=0 || status=$?

    if [ "$status" -eq 0 ]; then
        echo "a build with no package exited 0; the check would pass having inspected nothing" >&2
        return 1
    fi
    case "$out" in
        *"::error::"*) ;;
        *) echo "no ::error:: annotation in output: $out" >&2; return 1 ;;
    esac
}

test_missing_build_dir_fails_through_the_guard() {
    # Asserting only a non-zero exit would prove nothing: without `shopt -s
    # nullglob` the array holds the literal glob, the guard never fires, and the
    # cp fails instead -- also non-zero. The ::error:: annotation is what
    # distinguishes "the guard caught it" from "something downstream broke".
    local dir out status
    dir="$(mktemp -d "$TMPDIR_ROOT/nodir.XXXXXX")"
    mkdir -p "$dir/root"

    out=$(bash "$SCRIPT" "$dir/build" "$dir/root" 2>&1) && status=0 || status=$?

    if [ "$status" -eq 0 ]; then
        echo "a missing build directory exited 0" >&2
        return 1
    fi
    case "$out" in
        *"::error::"*) ;;
        *) echo "failed without reaching the guard: $out" >&2; return 1 ;;
    esac
}

test_default_arguments_match_the_real_call_site() {
    # The build-deb action calls this with no arguments, so the defaults are
    # what production actually exercises. Also pins that non-.deb build
    # artifacts stay put and that a second run is idempotent.
    local dir
    dir="$(mktemp -d "$TMPDIR_ROOT/defaults.XXXXXX")"
    mkdir -p "$dir/build"
    echo payload > "$dir/build/one_1.0-1_all.deb"
    echo meta > "$dir/build/one_1.0-1_all.buildinfo"
    echo meta > "$dir/build/one_1.0-1_all.changes"

    (cd "$dir" && bash "$SCRIPT" >/dev/null 2>&1) || return 1
    (cd "$dir" && bash "$SCRIPT" >/dev/null 2>&1) || {
        echo "a second run failed; the action would break on a re-run" >&2
        return 1
    }

    [ -f "$dir/one_1.0-1_all.deb" ] || {
        echo "default destination did not receive the package" >&2
        return 1
    }
    if [ -e "$dir/one_1.0-1_all.buildinfo" ] || [ -e "$dir/one_1.0-1_all.changes" ]; then
        echo "non-.deb artifacts were copied too" >&2
        return 1
    fi
}

run_test test_default_arguments_match_the_real_call_site
run_test test_packages_are_copied_to_the_destination
run_test test_empty_build_dir_fails_loudly
run_test test_missing_build_dir_fails_through_the_guard

echo ""
echo "Passed: $PASSES   Failed: $FAILS"
[ "$FAILS" -eq 0 ]
