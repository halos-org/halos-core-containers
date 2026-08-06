#!/usr/bin/env bash
# Tests for assets/lib-oidc-clients.sh and assets/reload-oidc-clients
#
# Run from repo root:
#   bash tests/test-lib-oidc-clients.sh
#
# Each test is a function prefixed with `test_`. Failures print a diagnostic
# and bump FAILS; the script exits non-zero if any test failed.
#
# Secret hashing normally shells out to the Authelia image. Every test here
# puts a stub `docker` first on PATH that returns a deterministic digest, so
# the suite needs neither Docker nor network. The stub also records its
# invocations, which is how the restart assertions are made.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_OIDC="$REPO_ROOT/assets/lib-oidc-clients.sh"
LIB_HOSTNAMES="$REPO_ROOT/assets/lib-hostnames.sh"
RELOAD_TOOL="$REPO_ROOT/assets/reload-oidc-clients"

for f in "$LIB_OIDC" "$LIB_HOSTNAMES" "$RELOAD_TOOL"; do
    if [ ! -f "$f" ]; then
        echo "missing: $f" >&2
        exit 2
    fi
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
    if [ "$1" = "$2" ]; then
        return 0
    fi
    printf '%s    actual:   %q\n    expected: %q\n' "$3" "$1" "$2" >&2
    return 1
}

assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then
        return 0
    fi
    printf '%s    haystack: %s\n    needle:   %q\n' "$3" "$1" "$2" >&2
    return 1
}

assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then
        printf '%s    haystack: %s\n    unwanted: %q\n' "$3" "$1" "$2" >&2
        return 1
    fi
    return 0
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

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# Build a scratch device layout under $1: /etc, /usr/lib and the container
# data root, wired together exactly as the installed package wires them.
make_device() {
    local root="$1"
    mkdir -p "$root/etc/container-apps/halos-core-containers" \
             "$root/etc/halos/oidc-clients.d" \
             "$root/usr/lib/halos-core-containers" \
             "$root/var/lib/container-apps/halos-core-containers/data/authelia"

    cat > "$root/etc/container-apps/halos-core-containers/env.defaults" << EOF
CONTAINER_DATA_ROOT="$root/var/lib/container-apps/halos-core-containers/data"
PACKAGE_NAME="halos-core-containers"
EOF

    cp "$LIB_HOSTNAMES" "$root/usr/lib/halos-core-containers/lib-hostnames.sh"
    cp "$LIB_OIDC" "$root/usr/lib/halos-core-containers/lib-oidc-clients.sh"

    printf 'halosdev.local\n' > "$root/etc/halos/hostnames.conf"

    local authelia="$root/var/lib/container-apps/halos-core-containers/data/authelia"
    cat > "$authelia/secrets.env" << 'EOF'
SESSION_SECRET="s"
OIDC_HMAC_SECRET="hmac-fixture"
STORAGE_ENCRYPTION_KEY="k"
RESET_PASSWORD_JWT_SECRET="j"
REDIS_PASSWORD="r"
EOF
    printf -- '-----BEGIN PRIVATE KEY-----\nFIXTURE\n-----END PRIVATE KEY-----\n' \
        > "$authelia/oidc_private_key.pem"
}

# Write a client snippet plus the plaintext secret it points at.
write_client() {
    local root="$1" id="$2" secret="$3"
    local secret_file="$root/var/lib/container-apps/${id}/data/oidc-secret"
    mkdir -p "$(dirname "$secret_file")"
    printf '%s\n' "$secret" > "$secret_file"
    cat > "$root/etc/halos/oidc-clients.d/${id}.yml" << EOF
client_id: ${id}
client_name: ${id} app
client_secret_file: ${secret_file}
redirect_uris:
  - 'https://\${HALOS_DOMAIN}/callback'
scopes: [openid, profile, email]
consent_mode: implicit
token_endpoint_auth_method: client_secret_post
EOF
}

# Stub `docker` on PATH. Hashing echoes a digest derived from the plaintext,
# so a changed secret produces changed output the way the real CLI does.
# Every call is appended to $root/docker.log for the restart assertions.
install_docker_stub() {
    local root="$1"
    local bin="$root/stub-bin"
    mkdir -p "$bin"
    cat > "$bin/docker" << 'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_STUB_LOG}"
case "$1" in
    run)
        [ "${DOCKER_STUB_HASH_RC:-0}" -ne 0 ] && exit "${DOCKER_STUB_HASH_RC}"
        for arg in "$@"; do
            case "$prev" in --password) plaintext="$arg" ;; esac
            prev="$arg"
        done
        printf 'Digest: $pbkdf2-sha512$fake$%s\n' "${plaintext:-none}"
        ;;
    inspect)
        printf '%s\n' "${DOCKER_STUB_STATE:-true}"
        ;;
    restart)
        exit "${DOCKER_STUB_RESTART_RC:-0}"
        ;;
    *)
        exit 1
        ;;
esac
STUB
    chmod 755 "$bin/docker"
    export DOCKER_STUB_LOG="$root/docker.log"
    : > "$DOCKER_STUB_LOG"
    export PATH="$bin:$PATH"
}

# Fresh scratch device + docker stub, published as DEV_ROOT. Deliberately not
# a command substitution: the stub is installed by exporting PATH, which a
# subshell would discard, and the real docker would silently take over.
new_device() {
    DEV_ROOT="$(mktemp -d "$TMPDIR_ROOT/dev.XXXXXX")"
    make_device "$DEV_ROOT"
    install_docker_stub "$DEV_ROOT"
}

authelia_dir() {
    printf '%s' "$1/var/lib/container-apps/halos-core-containers/data/authelia"
}

# Source the libraries and run a merge against $1's layout, in a subshell-free
# context so HALOS_OIDC_CHANGED is observable by the caller.
merge_on() {
    local root="$1"
    local authelia; authelia="$(authelia_dir "$root")"

    HALOS_HOSTNAMES_FILE="$root/etc/halos/hostnames.conf"
    HALOS_HOSTNAMES_DOMAIN_STATE=""
    unset HALOS_HOSTNAMES_DNS HALOS_HOSTNAMES_IPS HALOS_HOSTNAMES_CANONICAL
    # shellcheck source=/dev/null
    . "$LIB_HOSTNAMES"
    halos_load_hostnames

    # shellcheck source=/dev/null
    . "$LIB_OIDC"

    OIDC_CLIENTS_DIR="$root/etc/halos/oidc-clients.d"
    AUTHELIA_OIDC_FILE="${authelia}/oidc-clients.yml"
    OIDC_HMAC_SECRET="hmac-fixture"
    OIDC_PRIVATE_KEY="$(cat "${authelia}/oidc_private_key.pem")"

    halos_oidc_merge_clients
}

# Run the installed-tool entry point against $1's scratch layout. The hostname
# file and domain-state overrides are lib-hostnames.sh's own documented seams.
run_reload() {
    local root="$1"
    HALOS_OIDC_ROOT="$root" \
    HALOS_HOSTNAMES_FILE="$root/etc/halos/hostnames.conf" \
    HALOS_HOSTNAMES_DOMAIN_STATE="" \
        bash "$RELOAD_TOOL"
}

# ---------------------------------------------------------------------------
# Library: rendering
# ---------------------------------------------------------------------------

test_merge_renders_clients() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null

    local out; out="$(cat "$(authelia_dir "$root")/oidc-clients.yml")"
    assert_contains "$out" "client_id: signalk" "client not rendered" || return 1
    assert_contains "$out" "hmac_secret: 'hmac-fixture'" "hmac not rendered" || return 1
    assert_contains "$out" "sekrit-one" "hashed secret not rendered" || return 1
    assert_contains "$out" "- 'https://halosdev.local/callback'" "redirect_uri not expanded" || return 1
    assert_not_contains "$out" '${HALOS_DOMAIN}' "placeholder left unexpanded"
}

test_merge_reports_change_on_first_render() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null
    assert_eq "$HALOS_OIDC_CHANGED" "1" "first render must report a change"
}

test_merge_without_snippets_disables_oidc() {
    new_device; local root="$DEV_ROOT"
    merge_on "$root" > /dev/null

    local out; out="$(cat "$(authelia_dir "$root")/oidc-clients.yml")"
    assert_contains "$out" "No clients configured" "empty registration not written" || return 1
    assert_not_contains "$out" "client_id:" "no client should be present"
}

test_merge_skips_snippet_without_secret_file() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    write_client "$root" "grafana" "sekrit-two"
    rm "$root/var/lib/container-apps/grafana/data/oidc-secret"

    local log; log="$(merge_on "$root" 2>&1)"
    local out; out="$(cat "$(authelia_dir "$root")/oidc-clients.yml")"
    assert_contains "$log" "WARNING" "skipped snippet must warn" || return 1
    assert_contains "$out" "client_id: signalk" "healthy client dropped" || return 1
    assert_not_contains "$out" "client_id: grafana" "secret-less client must not register"
}

# ---------------------------------------------------------------------------
# Library: change detection
# ---------------------------------------------------------------------------

test_second_merge_with_identical_inputs_is_a_no_op() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null

    local rendered="$(authelia_dir "$root")/oidc-clients.yml"
    local before; before="$(cat "$rendered")"
    merge_on "$root" > /dev/null

    assert_eq "$HALOS_OIDC_CHANGED" "0" "unchanged inputs must not report a change" || return 1
    assert_eq "$(cat "$rendered")" "$before" "unchanged inputs must not rewrite the file"
}

test_rotated_secret_triggers_rerender() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null

    # Snippet text is untouched; only the secret it points at rotates. This is
    # the exact shape of the failure in issue #201.
    printf '%s\n' "rotated-secret" > "$root/var/lib/container-apps/signalk/data/oidc-secret"
    merge_on "$root" > /dev/null

    assert_eq "$HALOS_OIDC_CHANGED" "1" "rotated secret must report a change" || return 1
    assert_contains "$(cat "$(authelia_dir "$root")/oidc-clients.yml")" "rotated-secret" \
        "registration must carry the rotated secret"
}

test_new_snippet_triggers_rerender() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null

    write_client "$root" "grafana" "sekrit-two"
    merge_on "$root" > /dev/null

    assert_eq "$HALOS_OIDC_CHANGED" "1" "added snippet must report a change" || return 1
    assert_contains "$(cat "$(authelia_dir "$root")/oidc-clients.yml")" "client_id: grafana" \
        "added client missing from registration"
}

test_hostname_change_triggers_rerender() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null

    printf 'halosdev.local\nhalosdev.example.com\n' > "$root/etc/halos/hostnames.conf"
    merge_on "$root" > /dev/null

    assert_eq "$HALOS_OIDC_CHANGED" "1" "hostname list change must report a change" || return 1
    assert_contains "$(cat "$(authelia_dir "$root")/oidc-clients.yml")" \
        "- 'https://halosdev.example.com/callback'" "new hostname missing from redirect_uris"
}

test_missing_rendered_file_triggers_rerender() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null

    rm "$(authelia_dir "$root")/oidc-clients.yml"
    merge_on "$root" > /dev/null

    assert_eq "$HALOS_OIDC_CHANGED" "1" "a missing registration must be re-rendered" || return 1
    assert_contains "$(cat "$(authelia_dir "$root")/oidc-clients.yml")" "client_id: signalk" \
        "registration not restored"
}

test_externally_modified_registration_triggers_rerender() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null

    printf '# clobbered\n' > "$(authelia_dir "$root")/oidc-clients.yml"
    merge_on "$root" > /dev/null

    assert_eq "$HALOS_OIDC_CHANGED" "1" "a clobbered registration must be re-rendered" || return 1
    assert_contains "$(cat "$(authelia_dir "$root")/oidc-clients.yml")" "client_id: signalk" \
        "registration not restored"
}

test_render_version_bump_invalidates_stamp() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null

    # Simulates a package upgrade that changes the output format: the stamp on
    # disk was written by the old renderer and must not mark it current.
    HALOS_OIDC_RENDER_VERSION=$((HALOS_OIDC_RENDER_VERSION + 1))
    halos_oidc_merge_clients > /dev/null

    assert_eq "$HALOS_OIDC_CHANGED" "1" "render-version bump must invalidate the stamp"
}

test_hash_failure_keeps_the_previous_registration() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null
    local rendered="$(authelia_dir "$root")/oidc-clients.yml"
    local before; before="$(cat "$rendered")"

    # Hashing is a docker run; when it fails, dropping the client would break
    # exactly the logins this whole mechanism exists to keep working.
    printf '%s\n' "rotated" > "$root/var/lib/container-apps/signalk/data/oidc-secret"
    DOCKER_STUB_HASH_RC=1 merge_on "$root" > /dev/null && return 1

    assert_eq "$(cat "$rendered")" "$before" "a failed hash must not replace the registration"
}

test_hash_failure_is_retried_on_the_next_run() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null

    printf '%s\n' "rotated" > "$root/var/lib/container-apps/signalk/data/oidc-secret"
    DOCKER_STUB_HASH_RC=1 merge_on "$root" > /dev/null || true

    # The inputs did not change between the failure and this run, so only a
    # discarded stamp makes the retry happen.
    merge_on "$root" > /dev/null
    assert_eq "$HALOS_OIDC_CHANGED" "1" "the failed render must be retried" || return 1
    assert_contains "$(cat "$(authelia_dir "$root")/oidc-clients.yml")" "rotated" \
        "retry did not pick up the rotated secret"
}

test_hash_failure_still_leaves_a_loadable_config() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"

    # X_AUTHELIA_CONFIG lists this file, so Authelia will not start without it.
    DOCKER_STUB_HASH_RC=1 merge_on "$root" > /dev/null && return 1

    local rendered="$(authelia_dir "$root")/oidc-clients.yml"
    if [ ! -f "$rendered" ]; then
        echo "    no registration written; authelia would fail to start" >&2
        return 1
    fi
    assert_contains "$(cat "$rendered")" "No clients configured" "expected the empty placeholder"
}

test_registration_is_not_world_readable() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    merge_on "$root" > /dev/null

    local mode
    mode="$(stat -f '%Lp' "$(authelia_dir "$root")/oidc-clients.yml" 2>/dev/null \
        || stat -c '%a' "$(authelia_dir "$root")/oidc-clients.yml")"
    assert_eq "$mode" "600" "registration holds secret hashes and must stay 0600"
}

# ---------------------------------------------------------------------------
# reload-oidc-clients: the standalone tool
# ---------------------------------------------------------------------------

test_reload_writes_where_authelia_reads() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    run_reload "$root" > /dev/null

    # Regression for issue #200: the tool reconstructed the data root without
    # the /data segment and wrote where Authelia never looks.
    local expected="$root/var/lib/container-apps/halos-core-containers/data/authelia/oidc-clients.yml"
    if [ ! -f "$expected" ]; then
        echo "    registration not written to $expected" >&2
        return 1
    fi
    if [ -e "$root/var/lib/container-apps/halos-core-containers/authelia" ]; then
        echo "    tool wrote outside the mounted data root" >&2
        return 1
    fi
    assert_contains "$(cat "$expected")" "client_id: signalk" "client not registered"
}

test_reload_restarts_authelia_when_registration_changed() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    run_reload "$root" > /dev/null

    # Regression for issue #200: the restart went through `docker compose`,
    # which needs the unit's EnvironmentFile and fails standalone.
    assert_contains "$(cat "$root/docker.log")" "restart authelia" "authelia was not restarted" || return 1
    assert_not_contains "$(cat "$root/docker.log")" "compose" "restart must not need the compose environment"
}

test_reload_without_changes_leaves_authelia_alone() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"
    run_reload "$root" > /dev/null
    : > "$root/docker.log"

    local out; out="$(run_reload "$root")"
    assert_not_contains "$(cat "$root/docker.log")" "restart" "unchanged inputs must not restart authelia" || return 1
    assert_contains "$out" "already current" "no-op run should say so"
}

test_reload_reports_missing_data_root() {
    new_device; local root="$DEV_ROOT"
    rm "$root/etc/container-apps/halos-core-containers/env.defaults"

    local out rc
    out="$(run_reload "$root" 2>&1)" && rc=0 || rc=$?
    assert_eq "$rc" "1" "missing env.defaults must fail loudly" || return 1
    assert_contains "$out" "CONTAINER_DATA_ROOT" "error must name the missing variable"
}

test_reload_fails_and_holds_authelia_when_hashing_fails() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"

    local rc
    DOCKER_STUB_HASH_RC=1 run_reload "$root" > /dev/null 2>&1 && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "    a failed hash must surface as a unit failure, not success" >&2
        return 1
    fi
    assert_not_contains "$(cat "$root/docker.log")" "restart" \
        "authelia must not be restarted onto a registration we could not build"
}

test_reload_fails_when_restart_fails() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"

    local rc
    DOCKER_STUB_RESTART_RC=1 run_reload "$root" > /dev/null 2>&1 && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "    a failed restart must not report success" >&2
        return 1
    fi
    return 0
}

test_reload_skips_restart_when_authelia_not_running() {
    new_device; local root="$DEV_ROOT"
    write_client "$root" "signalk" "sekrit-one"

    DOCKER_STUB_STATE=false run_reload "$root" > /dev/null
    assert_not_contains "$(cat "$root/docker.log")" "restart" "stopped authelia needs no restart" || return 1
    assert_contains "$(cat "$(authelia_dir "$root")/oidc-clients.yml")" "client_id: signalk" \
        "registration must still be written"
}

test_reload_aborts_without_authelia_secrets() {
    new_device; local root="$DEV_ROOT"
    rm "$(authelia_dir "$root")/secrets.env"

    local out rc
    out="$(run_reload "$root" 2>&1)" && rc=0 || rc=$?
    assert_eq "$rc" "1" "missing secrets must fail loudly" || return 1
    assert_contains "$out" "secrets" "error must name the missing secrets file"
}

# ---------------------------------------------------------------------------

run_test test_merge_renders_clients
run_test test_merge_reports_change_on_first_render
run_test test_merge_without_snippets_disables_oidc
run_test test_merge_skips_snippet_without_secret_file
run_test test_second_merge_with_identical_inputs_is_a_no_op
run_test test_rotated_secret_triggers_rerender
run_test test_new_snippet_triggers_rerender
run_test test_hostname_change_triggers_rerender
run_test test_missing_rendered_file_triggers_rerender
run_test test_externally_modified_registration_triggers_rerender
run_test test_render_version_bump_invalidates_stamp
run_test test_hash_failure_keeps_the_previous_registration
run_test test_hash_failure_is_retried_on_the_next_run
run_test test_hash_failure_still_leaves_a_loadable_config
run_test test_registration_is_not_world_readable
run_test test_reload_writes_where_authelia_reads
run_test test_reload_restarts_authelia_when_registration_changed
run_test test_reload_without_changes_leaves_authelia_alone
run_test test_reload_reports_missing_data_root
run_test test_reload_fails_and_holds_authelia_when_hashing_fails
run_test test_reload_fails_when_restart_fails
run_test test_reload_skips_restart_when_authelia_not_running
run_test test_reload_aborts_without_authelia_secrets

echo ""
echo "Passed: $PASSES   Failed: $FAILS"
[ "$FAILS" -eq 0 ]
