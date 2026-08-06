#!/usr/bin/env bash
# Packaging contract checks for halos-core-containers
#
# Run from repo root:
#   bash tests/test-packaging-contract.sh
#
# Two classes of silent breakage, both cheap to pin and both already documented
# in debian/rules' own comments:
#
# 1. dh_installsystemd's autodetect only picks up debian/<pkg>.<ext>, never
#    debian/<pkg>.<name>.<ext>. A unit added without a matching --name= call is
#    present in the source tree and absent from the built .deb — a mechanism
#    that exists in the repo but never runs on a device, which is exactly how
#    the OIDC reload trigger came to be missing (#201).
#
# 2. The watched directory is named independently in the path unit, the tool
#    and postinst. If they drift, the trigger fires on a directory nobody
#    writes to and nothing reports it.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG="halos-core-containers"
RULES="$REPO_ROOT/debian/rules"

if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; RESET=""
fi

PASSES=0
FAILS=0

pass() { PASSES=$((PASSES + 1)); printf '%sPASS%s %s\n' "$GREEN" "$RESET" "$1"; }
fail() { FAILS=$((FAILS + 1)); printf '%sFAIL%s %s\n' "$RED" "$RESET" "$1"; }

# 1. Every named unit file has a dh_installsystemd --name= call.
for unit in "$REPO_ROOT"/debian/${PKG}.*.{service,timer,path}; do
    [ -e "$unit" ] || continue
    base="$(basename "$unit")"
    name="${base#"${PKG}".}"
    name="${name%.*}"
    if grep -q -- "--name=${name}\b" "$RULES"; then
        pass "debian/rules installs ${base}"
    else
        fail "debian/rules has no --name=${name}; ${base} would be absent from the .deb"
    fi
done

# 2. The watched directory matches what the tool reads and postinst creates.
watch_path=$(grep -h '^PathModified=' "$REPO_ROOT"/debian/${PKG}.halos-oidc-clients-reload.path | cut -d= -f2-)
tool_default=$(grep -o 'HALOS_OIDC_CLIENTS_DIR:-[^}]*' "$REPO_ROOT/assets/reload-oidc-clients" | cut -d- -f2-)
if [ -n "$watch_path" ] && [ "$watch_path" = "$tool_default" ]; then
    pass "the watched directory is the one the tool merges (${watch_path})"
else
    fail "watcher watches '${watch_path}' but the tool merges '${tool_default}'"
fi

if grep -q "mkdir -p ${watch_path}\$" "$REPO_ROOT/debian/postinst"; then
    pass "postinst creates ${watch_path}"
else
    fail "postinst does not create ${watch_path}; the watcher would have nothing to watch"
fi

# 3. Shared shell libraries reach /usr/lib/<pkg>/, where both callers source
#    them from. A library that ships only inside the app directory would break
#    /usr/bin/reload-oidc-clients while leaving prestart working.
for lib in "$REPO_ROOT"/assets/lib-*.sh; do
    base="$(basename "$lib")"
    if grep -q "assets/${base} " "$RULES" || grep -q "assets/${base}\$" "$RULES"; then
        pass "debian/rules installs ${base} to /usr/lib/${PKG}/"
    else
        fail "debian/rules does not install ${base}"
    fi
done

printf '\nPassed: %d   Failed: %d\n' "$PASSES" "$FAILS"
[ "$FAILS" -eq 0 ]
