#!/usr/bin/env bash
# Tests for assets/halos-resolve-domain
#
# Run from repo root:
#   bash tests/test-halos-resolve-domain.sh
#
# The producer is exec'd in a subshell per test with HALOS_* env overrides
# pointing the loader and the output file at a per-test tmpdir, so we exercise
# the real script (and the real lib-hostnames functions it sources) without
# touching /run/halos or /etc/halos.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/assets/halos-resolve-domain"
LIB_HOSTNAMES="$REPO_ROOT/assets/lib-hostnames.sh"

for f in "$SCRIPT" "$LIB_HOSTNAMES"; do
    [ -f "$f" ] || { echo "missing fixture: $f" >&2; exit 2; }
done

PASSES=0
FAILS=0
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; RESET=""
fi

assert_eq() {
    if [ "$1" = "$2" ]; then return 0; fi
    printf '%s    actual:   %q\n    expected: %q\n' "$3" "$1" "$2" >&2
    return 1
}

assert_file() {
    [ -f "$1" ] && return 0
    printf '%s    missing file: %s\n' "$2" "$1" >&2
    return 1
}

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

_short_hostname() { hostname -s 2>/dev/null || hostname | cut -d. -f1; }

# Invoke the producer with the loader + output file pointed at the scratch
# layout. Stickiness is disabled (set-but-empty state) so resolution is
# deterministic regardless of host network state.
run_producer() {
    local d="$1"
    HALOS_DOMAIN_FILE="$d/domain.env" \
    HALOS_LIB_HOSTNAMES="$LIB_HOSTNAMES" \
    HALOS_HOSTNAMES_FILE="$d/hostnames.conf" \
    HALOS_HOSTNAMES_DOMAIN_STATE="" \
    bash "$SCRIPT"
}

# Read HALOS_DOMAIN back out of a produced env file.
_domain_value() { sed -n 's/^HALOS_DOMAIN=//p' "$1"; }

# ---------------------------------------------------------------------------

test_writes_literal_canonical() {
    local d="$TMPDIR_ROOT/literal"; mkdir -p "$d"
    printf '%s\n' "myhost.example.net" "myhost.local" > "$d/hostnames.conf"
    run_producer "$d" >/dev/null
    assert_file "$d/domain.env" "domain.env not written" || return 1
    assert_eq "$(_domain_value "$d/domain.env")" "myhost.example.net" "canonical wrong"
}

test_fallback_when_conf_missing() {
    local d="$TMPDIR_ROOT/missing"; mkdir -p "$d"
    # No hostnames.conf at the configured path -> loader falls back to <short>.local.
    run_producer "$d" >/dev/null
    assert_file "$d/domain.env" "domain.env not written on fallback" || return 1
    assert_eq "$(_domain_value "$d/domain.env")" "$(_short_hostname).local" "fallback canonical wrong"
}

test_creates_missing_output_dir() {
    local d="$TMPDIR_ROOT/nodir"; mkdir -p "$d"
    printf '%s\n' "host.example.org" > "$d/hostnames.conf"
    # Point the output file at a not-yet-existing subdirectory.
    HALOS_DOMAIN_FILE="$d/run/halos/domain.env" \
    HALOS_LIB_HOSTNAMES="$LIB_HOSTNAMES" \
    HALOS_HOSTNAMES_FILE="$d/hostnames.conf" \
    HALOS_HOSTNAMES_DOMAIN_STATE="" \
    bash "$SCRIPT" >/dev/null
    assert_file "$d/run/halos/domain.env" "output dir not created" || return 1
    assert_eq "$(_domain_value "$d/run/halos/domain.env")" "host.example.org" "canonical wrong in created dir"
}

test_recomputes_on_rerun() {
    local d="$TMPDIR_ROOT/rerun"; mkdir -p "$d"
    printf '%s\n' "first.example.net" > "$d/hostnames.conf"
    run_producer "$d" >/dev/null
    assert_eq "$(_domain_value "$d/domain.env")" "first.example.net" "first run wrong" || return 1
    # Edit the config and re-run: the producer must republish the new value
    # (no stale pinning). This is the "edit hostnames.conf, restart, applies"
    # contract the producer exists to provide.
    printf '%s\n' "second.example.net" > "$d/hostnames.conf"
    run_producer "$d" >/dev/null
    assert_eq "$(_domain_value "$d/domain.env")" "second.example.net" "rerun did not republish"
}

# ---------------------------------------------------------------------------

run_test test_writes_literal_canonical
run_test test_fallback_when_conf_missing
run_test test_creates_missing_output_dir
run_test test_recomputes_on_rerun

printf '\n%d passed, %d failed\n' "$PASSES" "$FAILS"
[ "$FAILS" -eq 0 ]
