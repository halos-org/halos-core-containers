#!/usr/bin/env bash
# Tests for the mDNS service records written by assets/configure-container-routing.
#
# Run from repo root:
#   bash tests/test-configure-container-routing-mdns.sh
#
# Each test is a function prefixed with `test_`. Failures print a diagnostic
# and bump FAILS; the script exits non-zero if any test failed.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/assets/configure-container-routing"

if [ ! -f "$SCRIPT" ]; then
    echo "configure-container-routing not found at $SCRIPT" >&2
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

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    case "$haystack" in
        *"$needle"*) return 0 ;;
    esac
    printf '%s    missing:  %q\n    in:       %q\n' "$msg" "$needle" "$haystack" >&2
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

# Run configure-container-routing against a scratch root with the given
# routing.d body. Echoes the scratch root so the caller can inspect output.
run_configure() {
    local app_id="$1" routing_body="$2"
    local root
    root="$(mktemp -d "$TMPDIR_ROOT/case.XXXXXX")"
    mkdir -p "$root/routing.d"
    printf '%s\n' "$routing_body" > "$root/routing.d/${app_id}.yml"

    ROUTING_DIR="$root/routing.d" \
    OUTPUT_DIR="$root/routing-labels" \
    MIDDLEWARE_DIR="$root/traefik-dynamic.d" \
    PORT_REGISTRY="$root/port-registry" \
    AVAHI_SERVICES_DIR="$root/avahi-services" \
    RUNTIME_DIR="$root/container-apps" \
        bash "$SCRIPT" "$app_id" >/dev/null 2>&1 || {
            echo "configure-container-routing failed for $app_id" >&2
            return 1
        }
    echo "$root"
}

WEB_APP_ROUTING='app_id: webapp
package_name: webapp-container
routing:
  backend:
    type: container
    service: web
    port: 8080
auth:
  mode: none'

SK_ROUTING='app_id: signalk-server
package_name: marine-signalk-server-container
routing:
  backend:
    type: host
    service: signalk-server
    port: 3000
auth:
  mode: oidc
mdns:
- _signalk-wss._tcp'

# ---------------------------------------------------------------------------

test_service_file_written_with_assigned_port() {
    local root file
    root="$(run_configure signalk-server "$SK_ROUTING")" || return 1
    file="$root/avahi-services/halos-signalk-server.service"
    [ -f "$file" ] || { echo "no service file at $file" >&2; return 1; }

    local content port
    content="$(cat "$file")"
    port="$(grep '^signalk-server=' "$root/port-registry" | cut -d= -f2)"
    assert_contains "$content" "<type>_signalk-wss._tcp</type>" "service type missing:" || return 1
    assert_contains "$content" "<port>${port}</port>" "assigned port missing:" || return 1
    assert_contains "$content" '<name replace-wildcards="yes">%h</name>' "host name wildcard missing:" || return 1
}

test_no_service_file_without_mdns() {
    local root
    root="$(run_configure webapp "$WEB_APP_ROUTING")" || return 1
    if [ -e "$root/avahi-services/halos-webapp.service" ]; then
        echo "service file written for an app that declares no mdns types" >&2
        return 1
    fi
}

test_multiple_service_types() {
    local routing="${SK_ROUTING}
- _signalk-http._tcp"
    local root content
    root="$(run_configure signalk-server "$routing")" || return 1
    content="$(cat "$root/avahi-services/halos-signalk-server.service")"
    assert_contains "$content" "<type>_signalk-wss._tcp</type>" "first type missing:" || return 1
    assert_contains "$content" "<type>_signalk-http._tcp</type>" "second type missing:" || return 1
}

test_stale_file_removed_when_mdns_dropped() {
    local root
    root="$(mktemp -d "$TMPDIR_ROOT/stale.XXXXXX")"
    mkdir -p "$root/routing.d" "$root/avahi-services"
    printf '%s\n' "$WEB_APP_ROUTING" > "$root/routing.d/webapp.yml"
    echo "stale" > "$root/avahi-services/halos-webapp.service"

    ROUTING_DIR="$root/routing.d" \
    OUTPUT_DIR="$root/routing-labels" \
    MIDDLEWARE_DIR="$root/traefik-dynamic.d" \
    PORT_REGISTRY="$root/port-registry" \
    AVAHI_SERVICES_DIR="$root/avahi-services" \
    RUNTIME_DIR="$root/container-apps" \
        bash "$SCRIPT" webapp >/dev/null 2>&1 || return 1

    if [ -e "$root/avahi-services/halos-webapp.service" ]; then
        echo "stale service file survived a run that declares no mdns types" >&2
        return 1
    fi
}

run_test test_service_file_written_with_assigned_port
run_test test_no_service_file_without_mdns
run_test test_multiple_service_types
run_test test_stale_file_removed_when_mdns_dropped

echo ""
echo "Passed: $PASSES   Failed: $FAILS"
[ "$FAILS" -eq 0 ]
