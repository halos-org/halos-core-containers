#!/usr/bin/env bash
# Tests for assets/halos-manage-certs
#
# Run from repo root:
#   bash tests/test-halos-manage-certs.sh
#
# The script is exec'd in a subshell per test with HALOS_* env overrides
# pointing all on-disk state at a per-test tmpdir. This avoids touching
# /var/lib, /etc/halos, or /etc/cockpit while still exercising the real
# script (and the lib-ca / lib-hostnames functions it calls).

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/assets/halos-manage-certs"
LIB_CA="$REPO_ROOT/assets/lib-ca.sh"
LIB_HOSTNAMES="$REPO_ROOT/assets/lib-hostnames.sh"

for f in "$SCRIPT" "$LIB_CA" "$LIB_HOSTNAMES"; do
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

assert_no_file() {
    [ ! -e "$1" ] && return 0
    printf '%s    unexpected file: %s\n' "$2" "$1" >&2
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

# Build a per-test scratch layout and echo the data root so the test can
# reference $D/... paths. CUSTOM_CA_DIR stays empty (auto-CA mode);
# COCKPIT_WS_CERTS_DIR is created so the cockpit-override branch runs.
new_scratch() {
    local d="$TMPDIR_ROOT/$1"
    mkdir -p "$d/data" "$d/etc" "$d/custom-ca" "$d/cockpit-certs"
    printf '%s\n' "fixture.test" > "$d/hostnames.conf"
    printf '%s' "$d"
}

# Invoke the script with HALOS_* env overrides pointing at the scratch
# layout. PACKAGE_NAME=halos-core-containers so AUTO_CA_DIR lands at
# $CONTAINER_DATA_ROOT/halos-core-containers/certs/ca — matching the
# production layout.
run_script() {
    local d="$1"
    HALOS_ETC_DIR="$d/etc" \
    HALOS_LIB_HOSTNAMES="$LIB_HOSTNAMES" \
    HALOS_LIB_CA="$LIB_CA" \
    HALOS_CUSTOM_CA_DIR="$d/custom-ca" \
    HALOS_COCKPIT_WS_CERTS_DIR="$d/cockpit-certs" \
    HALOS_HOSTNAMES_FILE="$d/hostnames.conf" \
    PACKAGE_NAME="halos-core-containers" \
    CONTAINER_DATA_ROOT="$d/data" \
    bash "$SCRIPT"
}

# Paths the script writes, as a function of the scratch root.
_cert_file() { printf '%s' "$1/data/traefik/certs/halos.crt"; }
_key_file()  { printf '%s' "$1/data/traefik/certs/halos.key"; }
_domain_file() { printf '%s' "$1/data/traefik/certs/.domain"; }
_auto_ca_crt() { printf '%s' "$1/data/halos-core-containers/certs/ca/ca.crt"; }
_auto_ca_key() { printf '%s' "$1/data/halos-core-containers/certs/ca/ca.key"; }
_public_ca() { printf '%s' "$1/data/halos-core-containers/certs/public/halos-ca.crt"; }
_cockpit_override() { printf '%s' "$1/cockpit-certs/99-halos.cert"; }

# ---------------------------------------------------------------------------

test_first_boot_bootstrap_creates_all_artifacts() {
    # No prior state. Expect: auto-CA created, leaf signed, sentinel written,
    # public CA published, cockpit override installed.
    local d
    d=$(new_scratch first_boot)
    run_script "$d" >/dev/null
    assert_file "$(_auto_ca_crt "$d")" "auto-CA cert" || return 1
    assert_file "$(_auto_ca_key "$d")" "auto-CA key" || return 1
    assert_file "$(_cert_file "$d")" "leaf cert" || return 1
    assert_file "$(_key_file "$d")" "leaf key" || return 1
    assert_file "$(_domain_file "$d")" "sentinel" || return 1
    assert_file "$(_public_ca "$d")" "public CA copy" || return 1
    assert_file "$(_cockpit_override "$d")" "cockpit override" || return 1
}

test_idempotent_rerun_preserves_leaf_and_sentinel() {
    # After a successful first run, re-running with identical state must NOT
    # rotate the leaf or the auto-CA. Verified by inode comparison on
    # ca.crt and halos.crt (mv would change the inode; mtime alone is not
    # robust on filesystems with second-only granularity). Sentinel content
    # checked byte-for-byte so a corrupted .domain file (which would force
    # a re-sign on the next run) is caught.
    local d
    d=$(new_scratch idempotent)
    run_script "$d" >/dev/null
    local ca_inode_before leaf_inode_before sentinel_before
    ca_inode_before=$(stat -c '%i' "$(_auto_ca_crt "$d")" 2>/dev/null \
        || stat -f '%i' "$(_auto_ca_crt "$d")")
    leaf_inode_before=$(stat -c '%i' "$(_cert_file "$d")" 2>/dev/null \
        || stat -f '%i' "$(_cert_file "$d")")
    sentinel_before=$(cat "$(_domain_file "$d")")
    sleep 1
    run_script "$d" >/dev/null
    local ca_inode_after leaf_inode_after sentinel_after
    ca_inode_after=$(stat -c '%i' "$(_auto_ca_crt "$d")" 2>/dev/null \
        || stat -f '%i' "$(_auto_ca_crt "$d")")
    leaf_inode_after=$(stat -c '%i' "$(_cert_file "$d")" 2>/dev/null \
        || stat -f '%i' "$(_cert_file "$d")")
    sentinel_after=$(cat "$(_domain_file "$d")")
    assert_eq "$ca_inode_after" "$ca_inode_before" "auto-CA must not rotate on idempotent rerun" || return 1
    assert_eq "$leaf_inode_after" "$leaf_inode_before" "leaf must not rotate on idempotent rerun" || return 1
    assert_eq "$sentinel_after" "$sentinel_before" "sentinel content must be preserved on idempotent rerun" || return 1
}

test_hostname_change_triggers_leaf_only_resign() {
    # Changing the hostname list mutates HOSTNAMES_HASH → sentinel mismatch
    # → leaf re-sign. Auto-CA must stay put (CA fingerprint half of the
    # sentinel is unchanged).
    local d
    d=$(new_scratch hostname_change)
    run_script "$d" >/dev/null
    local ca_inode_before leaf_inode_before
    ca_inode_before=$(stat -c '%i' "$(_auto_ca_crt "$d")" 2>/dev/null \
        || stat -f '%i' "$(_auto_ca_crt "$d")")
    leaf_inode_before=$(stat -c '%i' "$(_cert_file "$d")" 2>/dev/null \
        || stat -f '%i' "$(_cert_file "$d")")
    printf '%s\n%s\n' "fixture.test" "second.test" > "$d/hostnames.conf"
    sleep 1
    run_script "$d" >/dev/null
    local ca_inode_after leaf_inode_after
    ca_inode_after=$(stat -c '%i' "$(_auto_ca_crt "$d")" 2>/dev/null \
        || stat -f '%i' "$(_auto_ca_crt "$d")")
    leaf_inode_after=$(stat -c '%i' "$(_cert_file "$d")" 2>/dev/null \
        || stat -f '%i' "$(_cert_file "$d")")
    assert_eq "$ca_inode_after" "$ca_inode_before" "auto-CA must not rotate on hostname-only change" || return 1
    if [ "$leaf_inode_after" = "$leaf_inode_before" ]; then
        echo "leaf must re-sign on hostname change (inodes still equal: $leaf_inode_before)"
        return 1
    fi
}

test_renewal_threshold_triggers_leaf_only_resign() {
    # Synthesize a leaf+sentinel pair where the leaf is just inside the
    # 60-day renewal window. Sentinel intentionally matches what the script
    # would compute (so the sentinel branch passes), so the only thing
    # that can fire NEED_LEAF=true is the halos_ca_leaf_needs_renewal gate.
    local d
    d=$(new_scratch renewal)
    run_script "$d" >/dev/null
    # Re-sign the leaf with a 30-day validity, then re-compute and write the
    # matching sentinel so the sentinel branch is a no-op. The library
    # signs leaves with HALOS_CA_LEAF_VALIDITY_DAYS; override via the 7th
    # arg to halos_ca_sign_leaf.
    (
        # shellcheck source=../assets/lib-ca.sh
        . "$LIB_CA"
        # shellcheck source=../assets/lib-hostnames.sh
        . "$LIB_HOSTNAMES"
        HALOS_HOSTNAMES_FILE="$d/hostnames.conf" halos_load_hostnames
        halos_ca_sign_leaf \
            "$(_auto_ca_crt "$d")" "$(_auto_ca_key "$d")" \
            "$(_cert_file "$d")" "$(_key_file "$d")" \
            "DNS:fixture.test" "fixture.test" \
            30
        ca_fp=$(halos_ca_fingerprint "$(_auto_ca_crt "$d")")
        hn_hash=$(halos_hostnames_hash)
        sentinel=$(halos_ca_sentinel_compose "$hn_hash" "$ca_fp")
        printf '%s' "$sentinel" > "$(_domain_file "$d")"
    )
    local leaf_inode_before
    leaf_inode_before=$(stat -c '%i' "$(_cert_file "$d")" 2>/dev/null \
        || stat -f '%i' "$(_cert_file "$d")")
    sleep 1
    run_script "$d" >/dev/null
    local leaf_inode_after
    leaf_inode_after=$(stat -c '%i' "$(_cert_file "$d")" 2>/dev/null \
        || stat -f '%i' "$(_cert_file "$d")")
    if [ "$leaf_inode_after" = "$leaf_inode_before" ]; then
        echo "leaf must re-sign when within renewal threshold (inodes still equal: $leaf_inode_before)"
        return 1
    fi
}

test_auto_ca_expired_rotates_ca_and_leaf() {
    # Replace the auto-CA with a cert that's already expired
    # (notAfter in the past). halos_ca_ensure_auto sees it as unhealthy
    # and regenerates → new fingerprint → sentinel mismatch → leaf re-sign.
    local d
    d=$(new_scratch ca_expired)
    run_script "$d" >/dev/null
    local ca_inode_before leaf_inode_before
    ca_inode_before=$(stat -c '%i' "$(_auto_ca_crt "$d")" 2>/dev/null \
        || stat -f '%i' "$(_auto_ca_crt "$d")")
    leaf_inode_before=$(stat -c '%i' "$(_cert_file "$d")" 2>/dev/null \
        || stat -f '%i' "$(_cert_file "$d")")
    # Overwrite the CA with a same-keypair-but-already-expired cert.
    # Using openssl req -x509 with the existing key, explicit not_before
    # and not_after well in the past. CA:TRUE / keyCertSign extensions
    # so halos_ca_ensure_auto's structural checks still pass; only the
    # validity-period check fails.
    local nb na
    nb=$(date -u -d "@$(( $(date -u +%s) - 30 * 86400 ))" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) - 30 * 86400 ))" +%Y%m%d%H%M%SZ)
    na=$(date -u -d "@$(( $(date -u +%s) - 86400 ))" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) - 86400 ))" +%Y%m%d%H%M%SZ)
    openssl req -x509 -nodes -key "$(_auto_ca_key "$d")" \
        -out "$(_auto_ca_crt "$d")" \
        -not_before "$nb" -not_after "$na" \
        -subj "/CN=Expired Auto CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        >/dev/null 2>&1 \
        || { echo "fixture cert regen failed"; return 1; }
    sleep 1
    run_script "$d" >/dev/null
    local ca_inode_after leaf_inode_after
    ca_inode_after=$(stat -c '%i' "$(_auto_ca_crt "$d")" 2>/dev/null \
        || stat -f '%i' "$(_auto_ca_crt "$d")")
    leaf_inode_after=$(stat -c '%i' "$(_cert_file "$d")" 2>/dev/null \
        || stat -f '%i' "$(_cert_file "$d")")
    if [ "$ca_inode_after" = "$ca_inode_before" ]; then
        echo "auto-CA must regenerate when expired (inodes still equal: $ca_inode_before)"
        return 1
    fi
    if [ "$leaf_inode_after" = "$leaf_inode_before" ]; then
        echo "leaf must re-sign when CA rotates (inodes still equal: $leaf_inode_before)"
        return 1
    fi
}

test_cockpit_dir_absent_skips_install_without_failure() {
    # When the cockpit-ws cert dir doesn't exist, the install branch logs
    # and is skipped; the script must still exit 0 and produce the leaf.
    local d
    d=$(new_scratch cockpit_absent)
    rm -rf "$d/cockpit-certs"
    if ! run_script "$d" >/dev/null 2>&1; then
        echo "script exited non-zero when cockpit dir absent"
        return 1
    fi
    assert_file "$(_cert_file "$d")" "leaf must still be produced" || return 1
    assert_no_file "$(_cockpit_override "$d")" "cockpit override must NOT be installed when dir absent" || return 1
}

test_broken_custom_ca_aborts_run() {
    # An operator drops malformed files into /etc/halos/ca. halos_ca_select_active
    # must reject and abort; we surface the failure (set -e) and exit non-zero.
    # No leaf gets signed.
    local d
    d=$(new_scratch broken_custom)
    printf 'garbage\n' > "$d/custom-ca/ca.crt"
    printf 'garbage\n' > "$d/custom-ca/ca.key"
    if run_script "$d" >/dev/null 2>&1; then
        echo "script must exit non-zero on broken custom CA"
        return 1
    fi
    assert_no_file "$(_cert_file "$d")" "leaf must NOT be signed when custom CA is broken" || return 1
}

test_valid_custom_ca_takes_precedence_over_auto() {
    # Happy-path companion to test_broken_custom_ca_aborts_run: when the
    # operator drops a valid CA at /etc/halos/ca, the script must use it
    # (mode=custom) and sign the leaf with it — confirming the precedence
    # branch in halos_ca_select_active isn't only ever exercised on the
    # failure path.
    local d
    d=$(new_scratch valid_custom)
    (
        umask 077
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "$d/custom-ca/ca.key" -out "$d/custom-ca/ca.crt" \
            -subj "/CN=Test Operator CA" \
            -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
            -addext "keyUsage=critical,keyCertSign,cRLSign" \
            >/dev/null 2>&1
    ) || { echo "custom CA fixture creation failed"; return 1; }
    chmod 0700 "$d/custom-ca"
    local out
    out=$(run_script "$d" 2>&1) || { echo "$out"; return 1; }
    if ! echo "$out" | grep -q "mode=custom"; then
        echo "expected 'mode=custom' in script output; got:"
        echo "$out"
        return 1
    fi
    if ! openssl verify -CAfile "$d/custom-ca/ca.crt" "$(_cert_file "$d")" >/dev/null 2>&1; then
        echo "leaf must verify against the operator-supplied custom CA"
        return 1
    fi
    # Auto-CA must NOT have been written when custom mode is active.
    assert_no_file "$(_auto_ca_crt "$d")" "auto-CA must not be written when custom CA is active" || return 1
}

test_leaf_includes_ip_san_when_hostnames_conf_has_ip() {
    # Exercises the script's IP-SAN branch (which iterates HALOS_HOSTNAMES_IPS
    # in addition to halos_dns_hostnames). All other tests use DNS-only
    # configs, so without this case the IP-SAN code is dead in test.
    local d
    d=$(new_scratch ip_san)
    printf '%s\n%s\n' "fixture.test" "10.42.0.1" > "$d/hostnames.conf"
    run_script "$d" >/dev/null
    local sans
    sans=$(openssl x509 -in "$(_cert_file "$d")" -noout -ext subjectAltName 2>&1)
    if ! echo "$sans" | grep -q "DNS:fixture.test"; then
        echo "leaf SAN missing DNS:fixture.test; got: $sans"
        return 1
    fi
    if ! echo "$sans" | grep -q "IP Address:10.42.0.1"; then
        echo "leaf SAN missing IP Address:10.42.0.1; got: $sans"
        return 1
    fi
}

test_leaf_has_expected_cert_structure() {
    # Content-level structural assertions on the first-boot leaf. Without
    # these a regression that produced a 0-byte / wrong-CN / wrong-EKU /
    # over-825-day cert would pass the existence-only checks elsewhere.
    local d
    d=$(new_scratch leaf_structure)
    run_script "$d" >/dev/null
    local leaf="$(_cert_file "$d")"
    local subject_cn
    subject_cn=$(openssl x509 -in "$leaf" -noout -subject -nameopt RFC2253 \
        | sed -n 's/.*CN=\([^,]*\).*/\1/p')
    assert_eq "$subject_cn" "fixture.test" "leaf CN must match canonical hostname" || return 1
    if ! openssl x509 -in "$leaf" -noout -ext subjectAltName 2>&1 | grep -q "DNS:fixture.test"; then
        echo "leaf SAN must include DNS:fixture.test"
        return 1
    fi
    if ! openssl x509 -in "$leaf" -noout -ext basicConstraints 2>&1 | grep -q "CA:FALSE"; then
        echo "leaf must have basicConstraints CA:FALSE"
        return 1
    fi
    if ! openssl x509 -in "$leaf" -noout -ext extendedKeyUsage 2>&1 | grep -q "TLS Web Server Authentication"; then
        echo "leaf must have extendedKeyUsage serverAuth (Chrome requires it)"
        return 1
    fi
    local not_before not_after nb_epoch na_epoch validity_days
    not_before=$(openssl x509 -in "$leaf" -noout -startdate | cut -d= -f2)
    not_after=$(openssl x509 -in "$leaf" -noout -enddate | cut -d= -f2)
    nb_epoch=$(date -u -d "$not_before" +%s 2>/dev/null \
        || date -u -j -f "%b %d %T %Y %Z" "$not_before" +%s)
    na_epoch=$(date -u -d "$not_after" +%s 2>/dev/null \
        || date -u -j -f "%b %d %T %Y %Z" "$not_after" +%s)
    validity_days=$(( (na_epoch - nb_epoch) / 86400 ))
    if [ "$validity_days" -gt 825 ]; then
        echo "leaf validity $validity_days exceeds Apple's 825-day cap"
        return 1
    fi
}

test_cockpit_reload_signal_emitted_on_leaf_change() {
    # When the leaf is re-signed, the script logs the cockpit-reload signal
    # line. Production wiring (systemctl reload-or-restart cockpit.socket)
    # is gated on `/run/systemd/system` existing AND cockpit.socket being
    # enabled — both absent in the test env — so the actual reload doesn't
    # fire here. The "Leaf rotated; signaling cockpit.socket to reload..."
    # log line is the assertable signal that the script TOOK the reload
    # branch (vs the cockpit dir absent / no leaf change paths).
    local d
    d=$(new_scratch reload_signal_on_change)
    local out
    out=$(run_script "$d" 2>&1) || { echo "$out"; return 1; }
    if ! echo "$out" | grep -q "signaling cockpit.socket to reload"; then
        echo "expected cockpit-reload signal on first-boot leaf signing; got:"
        echo "$out"
        return 1
    fi
}

test_cockpit_reload_signal_skipped_on_idempotent_rerun() {
    # The reload signal must NOT fire when the leaf wasn't touched. Without
    # this gate, a timer firing daily would bounce cockpit.socket every
    # 24h even when no rotation happened — exactly the no-op-thrash this
    # PR is meant to avoid.
    local d
    d=$(new_scratch reload_signal_idempotent)
    run_script "$d" >/dev/null
    local out
    out=$(run_script "$d" 2>&1) || { echo "$out"; return 1; }
    if echo "$out" | grep -q "signaling cockpit.socket to reload"; then
        echo "cockpit-reload signal must NOT fire on idempotent rerun; got:"
        echo "$out"
        return 1
    fi
    # Sanity: the second run should still produce the "Using existing leaf"
    # message — confirms the test is actually exercising the no-op path
    # and not silently failing some other way.
    if ! echo "$out" | grep -q "Using existing leaf"; then
        echo "expected 'Using existing leaf' on rerun; got:"
        echo "$out"
        return 1
    fi
}

test_cockpit_reload_signal_skipped_when_cockpit_dir_absent() {
    # Belt-and-suspenders: even if the leaf rotates, no reload signal when
    # cockpit-ws isn't installed. The reload branch is gated on the dir
    # existing because there's nothing to reload if cockpit isn't here.
    local d
    d=$(new_scratch reload_signal_no_cockpit)
    rm -rf "$d/cockpit-certs"
    local out
    out=$(run_script "$d" 2>&1) || { echo "$out"; return 1; }
    if echo "$out" | grep -q "signaling cockpit.socket to reload"; then
        echo "cockpit-reload signal must NOT fire when cockpit dir absent; got:"
        echo "$out"
        return 1
    fi
}

test_fingerprint_guard_exits_when_helper_fails() {
    # Validates the `CA_FINGERPRINT=$(...) || exit 1` guard at the top of
    # the post-CA-select block. Bash `set -e` does NOT abort on command-
    # substitution failure in an assignment, so the explicit guard is
    # load-bearing — without it, an empty fingerprint would feed a
    # malformed sentinel into downstream comparison and induce an
    # infinite re-sign loop. We trigger the failure by stubbing
    # halos_ca_fingerprint via the HALOS_LIB_CA seam.
    local d
    d=$(new_scratch fp_guard)
    run_script "$d" >/dev/null
    cat > "$d/stub-lib-ca.sh" <<EOF
. "$LIB_CA"
halos_ca_fingerprint() {
    echo "stub: simulating fingerprint failure" >&2
    return 1
}
EOF
    if HALOS_ETC_DIR="$d/etc" \
       HALOS_LIB_HOSTNAMES="$LIB_HOSTNAMES" \
       HALOS_LIB_CA="$d/stub-lib-ca.sh" \
       HALOS_CUSTOM_CA_DIR="$d/custom-ca" \
       HALOS_COCKPIT_WS_CERTS_DIR="$d/cockpit-certs" \
       HALOS_HOSTNAMES_FILE="$d/hostnames.conf" \
       PACKAGE_NAME="halos-core-containers" \
       CONTAINER_DATA_ROOT="$d/data" \
       bash "$SCRIPT" >/dev/null 2>&1; then
        echo "script must exit non-zero when halos_ca_fingerprint fails"
        return 1
    fi
}

# ---------------------------------------------------------------------------

run_test test_first_boot_bootstrap_creates_all_artifacts
run_test test_idempotent_rerun_preserves_leaf_and_sentinel
run_test test_hostname_change_triggers_leaf_only_resign
run_test test_renewal_threshold_triggers_leaf_only_resign
run_test test_auto_ca_expired_rotates_ca_and_leaf
run_test test_cockpit_dir_absent_skips_install_without_failure
run_test test_broken_custom_ca_aborts_run
run_test test_valid_custom_ca_takes_precedence_over_auto
run_test test_leaf_includes_ip_san_when_hostnames_conf_has_ip
run_test test_leaf_has_expected_cert_structure
run_test test_cockpit_reload_signal_emitted_on_leaf_change
run_test test_cockpit_reload_signal_skipped_on_idempotent_rerun
run_test test_cockpit_reload_signal_skipped_when_cockpit_dir_absent
run_test test_fingerprint_guard_exits_when_helper_fails

echo
echo "Passed: $PASSES, Failed: $FAILS"
[ "$FAILS" -eq 0 ]
