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

# reload_avahi shells out to systemctl. Point it at a stub that records calls,
# so running these tests on a Linux host cannot reload the real avahi-daemon.
cat > "$TMPDIR_ROOT/systemctl-stub" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${SYSTEMCTL_CALLS:-/dev/null}"
# is-active: claim the daemon is running so the reload path is exercised.
[ "$1" = "is-active" ] && exit 0
exit 0
STUB
chmod +x "$TMPDIR_ROOT/systemctl-stub"

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
        # A test that could not assert anything reports SKIP, not PASS: a green
        # line for a check that did not run is worse than no line.
        case "$out" in
            SKIP*)
                printf 'SKIP %s -- %s\n' "$name" "${out#SKIP }"
                return 0
                ;;
        esac
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
    SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
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
- type: _signalk-wss._tcp'

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
- type: _signalk-https._tcp"
    local root content
    root="$(run_configure signalk-server "$routing")" || return 1
    content="$(cat "$root/avahi-services/halos-signalk-server.service")"
    assert_contains "$content" "<type>_signalk-wss._tcp</type>" "first type missing:" || return 1
    assert_contains "$content" "<type>_signalk-https._tcp</type>" "second type missing:" || return 1
}

test_fixed_port_overrides_the_traefik_port() {
    local routing="${SK_ROUTING}
- type: _nmea-0183._tcp
  port: 10110"
    local root content port
    root="$(run_configure signalk-server "$routing")" || return 1
    content="$(cat "$root/avahi-services/halos-signalk-server.service")"
    port="$(grep '^signalk-server=' "$root/port-registry" | cut -d= -f2)"
    assert_contains "$content" "<port>10110</port>" "fixed port missing:" || return 1
    assert_contains "$content" "<port>${port}</port>" "assigned port missing:" || return 1
}

test_generated_file_is_well_formed_xml() {
    local routing="${SK_ROUTING}
- type: _nmea-0183._tcp
  port: 10110"
    local root file
    root="$(run_configure signalk-server "$routing")" || return 1
    file="$root/avahi-services/halos-signalk-server.service"
    # A substring match passes on a file avahi rejects outright, and a rejected
    # file publishes nothing while the script reports success.
    python3 - "$file" <<'XMLCHECK'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
assert root.tag == "service-group", root.tag
types = sorted(s.findtext("type") for s in root.findall("service"))
assert types == ["_nmea-0183._tcp", "_signalk-wss._tcp"], types
XMLCHECK
}

# Shapes a grep-based reader would drop. Each one must publish, not withdraw.
test_quoted_and_flow_style_entries_publish() {
    local root content
    root="$(run_configure signalk-server "app_id: signalk-server
package_name: marine-signalk-server-container
routing:
  backend:
    type: host
    service: signalk-server
    port: 3000
auth:
  mode: oidc
mdns: [{type: \"_signalk-wss._tcp\"}]")" || return 1
    content="$(cat "$root/avahi-services/halos-signalk-server.service")"
    assert_contains "$content" "<type>_signalk-wss._tcp</type>" "flow-style quoted entry dropped:" || return 1
}

test_unusable_declaration_keeps_the_existing_record() {
    local root
    root="$(mktemp -d "$TMPDIR_ROOT/bad.XXXXXX")"
    mkdir -p "$root/routing.d" "$root/avahi-services"
    printf '%s\n' "app_id: signalk-server
package_name: marine-signalk-server-container
routing:
  backend:
    type: host
    service: signalk-server
    port: 3000
auth:
  mode: oidc
mdns: true" > "$root/routing.d/signalk-server.yml"
    echo "previous record" > "$root/avahi-services/halos-signalk-server.service"

    ROUTING_DIR="$root/routing.d" \
    OUTPUT_DIR="$root/routing-labels" \
    MIDDLEWARE_DIR="$root/traefik-dynamic.d" \
    PORT_REGISTRY="$root/port-registry" \
    AVAHI_SERVICES_DIR="$root/avahi-services" \
    RUNTIME_DIR="$root/container-apps" \
    SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" signalk-server >/dev/null 2>&1 || {
            echo "a malformed mdns declaration must not fail the app start" >&2
            return 1
        }

    if [ ! -f "$root/avahi-services/halos-signalk-server.service" ]; then
        echo "an unparseable declaration withdrew a working record" >&2
        return 1
    fi
}

test_withdraw_mode_removes_the_record() {
    local root
    root="$(run_configure signalk-server "$SK_ROUTING")" || return 1
    [ -f "$root/avahi-services/halos-signalk-server.service" ] || return 1

    AVAHI_SERVICES_DIR="$root/avahi-services" \
    SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" --mdns-withdraw signalk-server >/dev/null 2>&1 || return 1

    if [ -e "$root/avahi-services/halos-signalk-server.service" ]; then
        echo "--mdns-withdraw left the record in place" >&2
        return 1
    fi
}

test_unwritable_services_dir_does_not_fail_the_start() {
    # chmod means nothing to root, so as root this would assert nothing at all.
    # Say so rather than reporting a pass the run did not earn.
    if [ "$(id -u)" -eq 0 ]; then
        echo "SKIP (running as root; chmod cannot make the directory unwritable)"
        return 0
    fi

    local root
    root="$(mktemp -d "$TMPDIR_ROOT/ro.XXXXXX")"
    mkdir -p "$root/routing.d" "$root/avahi-services"
    printf '%s\n' "$SK_ROUTING" > "$root/routing.d/signalk-server.yml"
    chmod 500 "$root/avahi-services"

    ROUTING_DIR="$root/routing.d" \
    OUTPUT_DIR="$root/routing-labels" \
    MIDDLEWARE_DIR="$root/traefik-dynamic.d" \
    PORT_REGISTRY="$root/port-registry" \
    AVAHI_SERVICES_DIR="$root/avahi-services" \
    RUNTIME_DIR="$root/container-apps" \
    SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" signalk-server >/dev/null 2>&1
    local status=$?
    chmod 700 "$root/avahi-services"

    if [ "$status" -ne 0 ]; then
        echo "a failed mDNS write aborted the start (exit $status)" >&2
        return 1
    fi
    # The Traefik half must still be there.
    [ -f "$root/routing-labels/signalk-server.yml" ] || {
        echo "routing labels missing" >&2
        return 1
    }
}

test_port_change_rewrites_the_record() {
    local root file
    root="$(run_configure signalk-server "$SK_ROUTING")" || return 1
    file="$root/avahi-services/halos-signalk-server.service"
    local before
    before="$(cat "$file")"

    # Second run with no change: the record must be byte-identical.
    ROUTING_DIR="$root/routing.d" OUTPUT_DIR="$root/routing-labels" \
    MIDDLEWARE_DIR="$root/traefik-dynamic.d" PORT_REGISTRY="$root/port-registry" \
    AVAHI_SERVICES_DIR="$root/avahi-services" RUNTIME_DIR="$root/container-apps" \
    SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" signalk-server >/dev/null 2>&1 || return 1
    assert_contains "$(cat "$file")" "$before" "second run changed the record:" || return 1

    # Reassign the port: the record names it, so it must follow.
    echo "signalk-server=4444" > "$root/port-registry"
    ROUTING_DIR="$root/routing.d" OUTPUT_DIR="$root/routing-labels" \
    MIDDLEWARE_DIR="$root/traefik-dynamic.d" PORT_REGISTRY="$root/port-registry" \
    AVAHI_SERVICES_DIR="$root/avahi-services" RUNTIME_DIR="$root/container-apps" \
    SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" signalk-server >/dev/null 2>&1 || return 1
    assert_contains "$(cat "$file")" "<port>4444</port>" "record kept the old port:" || return 1
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
    SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" webapp >/dev/null 2>&1 || return 1

    if [ -e "$root/avahi-services/halos-webapp.service" ]; then
        echo "stale service file survived a run that declares no mdns types" >&2
        return 1
    fi
}

test_real_generated_routing_file_publishes() {
    local fixture="$SCRIPT_DIR/fixtures/routing.d-signalk-server.yml"
    [ -f "$fixture" ] || { echo "fixture missing: $fixture" >&2; return 1; }

    local root
    root="$(mktemp -d "$TMPDIR_ROOT/fixture.XXXXXX")"
    mkdir -p "$root/routing.d"
    cp "$fixture" "$root/routing.d/signalk-server.yml"

    ROUTING_DIR="$root/routing.d" \
    OUTPUT_DIR="$root/routing-labels" \
    MIDDLEWARE_DIR="$root/traefik-dynamic.d" \
    PORT_REGISTRY="$root/port-registry" \
    AVAHI_SERVICES_DIR="$root/avahi-services" \
    RUNTIME_DIR="$root/container-apps" \
    SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" signalk-server >/dev/null 2>&1 || return 1

    local port
    port="$(grep '^signalk-server=' "$root/port-registry" | cut -d= -f2)"
    python3 - "$root/avahi-services/halos-signalk-server.service" "$port" <<'FIXCHECK'
import sys
import xml.etree.ElementTree as ET

path, external_port = sys.argv[1], sys.argv[2]
root = ET.parse(path).getroot()
got = {s.findtext("type"): s.findtext("port") for s in root.findall("service")}
expected = {
    "_signalk-wss._tcp": external_port,
    "_signalk-https._tcp": external_port,
    "_https._tcp": external_port,
    "_nmea-0183._tcp": "10110",
}
assert got == expected, f"{got} != {expected}"
FIXCHECK
}

test_failed_write_is_reported_not_logged_as_success() {
    # generate_mdns_services runs on the left of `||`, which disables `set -e`
    # inside it. Unchecked, a failed write falls through to the success log and
    # returns 0 -- a record reported as published that never was.
    local root out
    root="$(mktemp -d "$TMPDIR_ROOT/failwrite.XXXXXX")"
    mkdir -p "$root/routing.d"
    printf '%s\n' "$SK_ROUTING" > "$root/routing.d/signalk-server.yml"
    # A plain file where the services directory should be. chmod would prove
    # nothing under root, which is how CI runs the suite.
    printf 'not a directory\n' > "$root/avahi-services"

    out=$(ROUTING_DIR="$root/routing.d" \
        OUTPUT_DIR="$root/routing-labels" \
        MIDDLEWARE_DIR="$root/traefik-dynamic.d" \
        PORT_REGISTRY="$root/port-registry" \
        AVAHI_SERVICES_DIR="$root/avahi-services" \
        RUNTIME_DIR="$root/container-apps" \
        SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" signalk-server 2>&1)
    local status=$?

    [ "$status" -eq 0 ] || { echo "the app start failed (exit $status)" >&2; return 1; }

    case "$out" in
        *"Created mDNS services"*)
            echo "a failed write was logged as success:" >&2
            echo "$out" >&2
            return 1
            ;;
    esac
    case "$out" in
        *"WARNING: mDNS publication failed"*) ;;
        *) echo "no warning for a failed write:" >&2; echo "$out" >&2; return 1 ;;
    esac
}

test_record_withdrawn_when_routing_file_is_gone() {
    # A deleted declaration leaves a record answering for a port nothing
    # serves. main() returns early in that case, so the withdrawal has to
    # happen before the early exit.
    local root
    root="$(run_configure signalk-server "$SK_ROUTING")" || return 1
    [ -f "$root/avahi-services/halos-signalk-server.service" ] || return 1

    rm -f "$root/routing.d/signalk-server.yml"
    ROUTING_DIR="$root/routing.d" \
    OUTPUT_DIR="$root/routing-labels" \
    MIDDLEWARE_DIR="$root/traefik-dynamic.d" \
    PORT_REGISTRY="$root/port-registry" \
    AVAHI_SERVICES_DIR="$root/avahi-services" \
    RUNTIME_DIR="$root/container-apps" \
    SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" signalk-server >/dev/null 2>&1 || return 1

    if [ -e "$root/avahi-services/halos-signalk-server.service" ]; then
        echo "the record outlived its routing declaration" >&2
        return 1
    fi
}

test_failed_file_write_is_reported_not_logged_as_success() {
    # The case above trips the mkdir check. This one reaches the write itself,
    # which needs an unwritable directory -- so it cannot run as root.
    if [ "$(id -u)" -eq 0 ]; then
        echo "SKIP (running as root; chmod cannot make the directory unwritable)"
        return 0
    fi

    local root out status
    root="$(mktemp -d "$TMPDIR_ROOT/failfile.XXXXXX")"
    mkdir -p "$root/routing.d" "$root/avahi-services"
    printf '%s\n' "$SK_ROUTING" > "$root/routing.d/signalk-server.yml"
    chmod 500 "$root/avahi-services"

    out=$(ROUTING_DIR="$root/routing.d" \
        OUTPUT_DIR="$root/routing-labels" \
        MIDDLEWARE_DIR="$root/traefik-dynamic.d" \
        PORT_REGISTRY="$root/port-registry" \
        AVAHI_SERVICES_DIR="$root/avahi-services" \
        RUNTIME_DIR="$root/container-apps" \
        SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" signalk-server 2>&1)
    status=$?
    chmod 700 "$root/avahi-services"

    [ "$status" -eq 0 ] || { echo "the app start failed (exit $status)" >&2; return 1; }
    case "$out" in
        *"Created mDNS services"*)
            echo "a failed write was logged as success:" >&2; echo "$out" >&2; return 1 ;;
    esac
    case "$out" in
        *"WARNING: mDNS publication failed"*) ;;
        *) echo "no warning for a failed write:" >&2; echo "$out" >&2; return 1 ;;
    esac
    # Deliberately not asserting that no temp file survives: in both failure
    # scenarios the redirect fails before the temp file is created, so the
    # cleanup in generate_mdns_services never runs and such an assertion could
    # not fail. Reaching it needs a write that succeeds and a rename that does
    # not, which takes a sticky-bit directory owned by another user.
}

test_failed_withdrawal_is_reported_not_silent() {
    # An app that drops its mdns: key withdraws its record. If that removal
    # fails the record is still on the network, so reporting it as
    # nothing-to-do is the same false success the write path was fixed for.
    if [ "$(id -u)" -eq 0 ]; then
        echo "SKIP (running as root; chmod cannot make the directory unwritable)"
        return 0
    fi

    local root out status
    root="$(mktemp -d "$TMPDIR_ROOT/failwithdraw.XXXXXX")"
    mkdir -p "$root/routing.d" "$root/avahi-services"
    printf '%s\n' "$WEB_APP_ROUTING" > "$root/routing.d/webapp.yml"
    echo "stale" > "$root/avahi-services/halos-webapp.service"
    chmod 500 "$root/avahi-services"

    out=$(ROUTING_DIR="$root/routing.d" \
        OUTPUT_DIR="$root/routing-labels" \
        MIDDLEWARE_DIR="$root/traefik-dynamic.d" \
        PORT_REGISTRY="$root/port-registry" \
        AVAHI_SERVICES_DIR="$root/avahi-services" \
        RUNTIME_DIR="$root/container-apps" \
        SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" webapp 2>&1)
    status=$?
    chmod 700 "$root/avahi-services"

    [ "$status" -eq 0 ] || { echo "the app start failed (exit $status)" >&2; return 1; }
    case "$out" in
        *"WARNING: mDNS publication failed"*) ;;
        *)
            echo "a failed withdrawal produced no warning; the stale record is still advertised:" >&2
            echo "$out" >&2
            return 1
            ;;
    esac
}

test_double_hyphen_app_id_still_produces_valid_xml() {
    # container-packaging-tools validates app_id as ^[a-z0-9][a-z0-9-]*$, which
    # permits a double hyphen -- and `--` is illegal inside an XML comment, so
    # putting the id there made avahi reject the whole file while this script
    # reported success.
    local routing root
    routing="${SK_ROUTING//signalk-server/sig--nalk}"
    root="$(run_configure sig--nalk "$routing")" || return 1

    python3 -c "import xml.etree.ElementTree as E, sys; E.parse(sys.argv[1])" \
        "$root/avahi-services/halos-sig--nalk.service" || {
            echo "the generated file is not well-formed XML" >&2
            cat "$root/avahi-services/halos-sig--nalk.service" >&2
            return 1
        }
}

test_app_id_cannot_escape_the_services_directory() {
    # app_id arrives from argv and becomes a file name.
    local root out
    root="$(mktemp -d "$TMPDIR_ROOT/escape.XXXXXX")"
    mkdir -p "$root/avahi-services" "$root/elsewhere"
    echo "do not touch" > "$root/elsewhere/halos-evil.service"

    out=$(AVAHI_SERVICES_DIR="$root/avahi-services" \
        SYSTEMCTL="$TMPDIR_ROOT/systemctl-stub" \
        bash "$SCRIPT" --mdns-withdraw "../elsewhere/evil" 2>&1)

    [ -f "$root/elsewhere/halos-evil.service" ] || {
        echo "a traversing app id removed a file outside the services directory" >&2
        return 1
    }
    case "$out" in
        *"invalid app id"*) ;;
        *) echo "no warning for a traversing app id: $out" >&2; return 1 ;;
    esac
}

run_test test_double_hyphen_app_id_still_produces_valid_xml
run_test test_app_id_cannot_escape_the_services_directory
run_test test_failed_withdrawal_is_reported_not_silent
run_test test_failed_file_write_is_reported_not_logged_as_success
run_test test_failed_write_is_reported_not_logged_as_success
run_test test_record_withdrawn_when_routing_file_is_gone
run_test test_real_generated_routing_file_publishes
run_test test_service_file_written_with_assigned_port
run_test test_no_service_file_without_mdns
run_test test_multiple_service_types
run_test test_fixed_port_overrides_the_traefik_port
run_test test_generated_file_is_well_formed_xml
run_test test_quoted_and_flow_style_entries_publish
run_test test_unusable_declaration_keeps_the_existing_record
run_test test_withdraw_mode_removes_the_record
run_test test_unwritable_services_dir_does_not_fail_the_start
run_test test_port_change_rewrites_the_record
run_test test_stale_file_removed_when_mdns_dropped

echo ""
echo "Passed: $PASSES   Failed: $FAILS"
[ "$FAILS" -eq 0 ]
