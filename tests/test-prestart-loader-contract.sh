#!/usr/bin/env bash
# Loader-consumer contract test for prestart.sh
#
# Run from repo root:
#   bash tests/test-prestart-loader-contract.sh
#
# AGENTS.md (Hostname-list contract): "The shared loader at
# /usr/lib/halos-core-containers/lib-hostnames.sh is sourced by prestart.sh
# ... do not duplicate parsing logic — extend the loader instead."
#
# prestart.sh runs under `set -e`, so any halos_* / _halos_* function it
# invokes without the loader sourced aborts the script at container start
# (exit 127), and halos-core-containers.service fails to boot. This guards
# that class of regression cheaply, without running the full prestart (which
# needs docker + scratch /etc + /run): every loader symbol prestart.sh calls
# must be defined by the loader, and prestart.sh must source the loader.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRESTART="$REPO_ROOT/prestart.sh"
LIB="$REPO_ROOT/assets/lib-hostnames.sh"

for f in "$PRESTART" "$LIB"; do
    [ -f "$f" ] || { echo "missing fixture: $f" >&2; exit 2; }
done

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; RESET=""
fi

FAILS=0

# 1. prestart.sh must source the loader. Check on non-comment lines only, and
#    assert the specific indirection the loader-consumer convention uses:
#    LIB_HOSTNAMES is assigned a lib-hostnames.sh path AND dot-sourced. This is
#    tighter than "contains lib-hostnames.sh + some dot-source" — prestart has
#    other dot-sources (env files, the Authelia secrets file) and comment
#    mentions of the lib, so a loose check passes even when the source is gone.
noncomment="$(sed 's/#.*//' "$PRESTART")"
if printf '%s\n' "$noncomment" | grep -Eq 'LIB_HOSTNAMES=.*lib-hostnames\.sh' \
   && printf '%s\n' "$noncomment" | grep -Eq '^\s*\.\s+"\$\{?LIB_HOSTNAMES\}?"'; then
    printf '%sPASS%s prestart.sh sources the lib-hostnames.sh loader\n' "$GREEN" "$RESET"
else
    printf '%sFAIL%s prestart.sh does not source the lib-hostnames.sh loader\n' "$RED" "$RESET"
    FAILS=$((FAILS + 1))
fi

# 2. Every loader symbol prestart.sh *invokes* must be defined by the loader.
#    Collect candidate invocations: halos_* / _halos_* tokens that appear as a
#    command (start of pipeline, after `<(`, `$(`, `if`, `&&`, etc.). We keep
#    it simple: any halos_*/_halos_* word in prestart.sh that is NOT part of a
#    HALOS_HOSTNAMES_ variable reference.
mapfile -t called < <(grep -oE '\b_?halos_[a-z_]+' "$PRESTART" \
    | grep -vE '^HALOS_' | sort -u)

# Source the loader in this shell so declare -F can see its functions.
# shellcheck source=/dev/null
. "$LIB"

missing=()
for fn in "${called[@]}"; do
    # Only check things that look like function calls (lowercase helper/public
    # API). Skip anything the loader exposes as a variable, not a function.
    if ! declare -F "$fn" >/dev/null 2>&1; then
        missing+=("$fn")
    fi
done

if [ "${#called[@]}" -gt 0 ] && [ "${#missing[@]}" -eq 0 ]; then
    printf '%sPASS%s all %d loader symbols invoked by prestart.sh are defined: %s\n' \
        "$GREEN" "$RESET" "${#called[@]}" "${called[*]}"
else
    printf '%sFAIL%s prestart.sh invokes loader symbols not defined by lib-hostnames.sh: %s\n' \
        "$RED" "$RESET" "${missing[*]:-<none collected>}"
    FAILS=$((FAILS + 1))
fi

printf '\n%d check(s) failed\n' "$FAILS"
[ "$FAILS" -eq 0 ]
