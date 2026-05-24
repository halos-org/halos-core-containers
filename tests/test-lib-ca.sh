#!/usr/bin/env bash
# Tests for assets/lib-ca.sh
#
# Run from repo root:
#   bash tests/test-lib-ca.sh
#
# Each test is a function prefixed with `test_`. Failures print a diagnostic
# and bump FAILS; the script exits non-zero if any test failed.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/assets/lib-ca.sh"

if [ ! -f "$LIB" ]; then
    echo "lib-ca.sh not found at $LIB" >&2
    exit 2
fi

# shellcheck source=../assets/lib-ca.sh
. "$LIB"

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

assert_matches() {
    # assert_matches <actual> <regex> <msg>
    if [[ "$1" =~ $2 ]]; then return 0; fi
    printf '%s    actual:   %q\n    regex:    %s\n' "$3" "$1" "$2" >&2
    return 1
}

_stat_mode() {
    # GNU stat: -c '%a'; BSD stat (macOS): -f '%Lp'.
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

_parse_openssl_date() {
    # OpenSSL prints dates like "May 24 19:48:00 2026 GMT".
    # GNU date accepts that directly; BSD date does not. Use the appropriate flag.
    date -u -d "$1" +%s 2>/dev/null \
        || date -u -j -f "%b %d %T %Y %Z" "$1" +%s
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

test_ensure_auto_generates_files() {
    local d="$TMPDIR_ROOT/case_ensure_files"
    halos_ca_ensure_auto "$d" || { echo "ensure_auto returned non-zero"; return 1; }
    [ -f "$d/ca.crt" ] || { echo "ca.crt not created"; return 1; }
    [ -f "$d/ca.key" ] || { echo "ca.key not created"; return 1; }

    # Permissions
    local key_mode
    key_mode=$(_stat_mode "$d/ca.key")
    assert_eq "$key_mode" "600" "ca.key mode should be 600" || return 1
    local crt_mode
    crt_mode=$(_stat_mode "$d/ca.crt")
    assert_eq "$crt_mode" "644" "ca.crt mode should be 644" || return 1
}

test_ensure_auto_is_idempotent() {
    local d="$TMPDIR_ROOT/case_ensure_idempotent"
    halos_ca_ensure_auto "$d" || return 1
    local fp1; fp1=$(halos_ca_fingerprint "$d/ca.crt")
    halos_ca_ensure_auto "$d" || return 1
    local fp2; fp2=$(halos_ca_fingerprint "$d/ca.crt")
    assert_eq "$fp1" "$fp2" "fingerprint must not change on second call" || return 1
}

test_ca_has_required_extensions() {
    local d="$TMPDIR_ROOT/case_ca_extensions"
    halos_ca_ensure_auto "$d" || return 1
    local dump
    dump=$(openssl x509 -in "$d/ca.crt" -noout -text)
    echo "$dump" | grep -q "CA:TRUE" || { echo "CA:TRUE not found"; return 1; }
    echo "$dump" | grep -q "Certificate Sign" || { echo "keyCertSign not found"; return 1; }
    echo "$dump" | grep -q "CRL Sign" || { echo "cRLSign not found"; return 1; }
    echo "$dump" | grep -q "Subject Key Identifier" || { echo "subjectKeyIdentifier not found"; return 1; }
}

test_ca_validity_is_long() {
    local d="$TMPDIR_ROOT/case_ca_validity"
    halos_ca_ensure_auto "$d" || return 1
    # notAfter should be ~20y out; check at least 18y to allow leap-day jitter.
    local not_after_epoch now_epoch diff_years
    local not_after
    not_after=$(openssl x509 -in "$d/ca.crt" -noout -enddate | cut -d= -f2)
    not_after_epoch=$(_parse_openssl_date "$not_after")
    now_epoch=$(date +%s)
    diff_years=$(( (not_after_epoch - now_epoch) / (365 * 86400) ))
    if [ "$diff_years" -lt 18 ]; then
        echo "CA validity only $diff_years years; expected ~20"
        return 1
    fi
}

test_ca_not_before_is_backdated() {
    local d="$TMPDIR_ROOT/case_ca_backdate"
    halos_ca_ensure_auto "$d" || return 1
    local not_before_epoch now_epoch
    local not_before
    not_before=$(openssl x509 -in "$d/ca.crt" -noout -startdate | cut -d= -f2)
    not_before_epoch=$(_parse_openssl_date "$not_before")
    now_epoch=$(date +%s)
    # notBefore must be in the past (at least 1h ago, well within the 24h backdate window)
    if [ "$not_before_epoch" -ge "$((now_epoch - 3600))" ]; then
        echo "notBefore not backdated; not_before_epoch=$not_before_epoch now=$now_epoch"
        return 1
    fi
}

test_fingerprint_format() {
    local d="$TMPDIR_ROOT/case_fp_format"
    halos_ca_ensure_auto "$d" || return 1
    local fp; fp=$(halos_ca_fingerprint "$d/ca.crt")
    assert_matches "$fp" "^[0-9a-f]{64}$" "fingerprint should be 64 lowercase hex chars" || return 1
}

test_fingerprint_missing_file_errors() {
    halos_ca_fingerprint "$TMPDIR_ROOT/does-not-exist.crt" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "missing cert file must exit 1 (runtime failure)" || return 1
}

test_sign_leaf_produces_valid_chain() {
    local d="$TMPDIR_ROOT/case_sign_chain"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local,DNS:device.lan,IP:10.0.0.5" \
        "device.local" \
        365 \
        || { echo "sign_leaf returned non-zero"; return 1; }
    [ -f "$d/leaf.crt" ] || { echo "leaf.crt not created"; return 1; }
    [ -f "$d/leaf.key" ] || { echo "leaf.key not created"; return 1; }
    # Verify chain
    if ! openssl verify -CAfile "$d/ca.crt" "$d/leaf.crt" >/dev/null 2>&1; then
        echo "openssl verify failed for leaf against CA"
        openssl verify -CAfile "$d/ca.crt" "$d/leaf.crt"
        return 1
    fi
}

test_sign_leaf_includes_sans() {
    local d="$TMPDIR_ROOT/case_sign_sans"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local,DNS:device.lan,IP:10.0.0.5" \
        "device.local" \
        || return 1
    local dump
    dump=$(openssl x509 -in "$d/leaf.crt" -noout -text)
    echo "$dump" | grep -q "DNS:device.local" || { echo "DNS:device.local SAN missing"; return 1; }
    echo "$dump" | grep -q "DNS:device.lan" || { echo "DNS:device.lan SAN missing"; return 1; }
    echo "$dump" | grep -q "IP Address:10.0.0.5" || { echo "IP SAN missing"; return 1; }
}

test_sign_leaf_has_server_auth_eku() {
    local d="$TMPDIR_ROOT/case_sign_eku"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" \
        "device.local" \
        || return 1
    local dump
    dump=$(openssl x509 -in "$d/leaf.crt" -noout -text)
    echo "$dump" | grep -q "TLS Web Server Authentication" || { echo "serverAuth EKU missing"; return 1; }
    echo "$dump" | grep -q "CA:FALSE" || { echo "leaf must not be a CA"; return 1; }
}

test_sign_leaf_missing_args_errors() {
    halos_ca_sign_leaf "" "" "" "" "" "" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "2" "missing args must exit 2 (caller bug), not 1 (runtime failure)" || return 1
}

test_sign_leaf_missing_ca_files_errors() {
    # All args supplied but CA paths don't exist — distinct from arg-validation;
    # must return 1 (runtime failure) and leave no .new debris.
    local d="$TMPDIR_ROOT/case_sign_missing_ca"
    mkdir -p "$d"
    halos_ca_sign_leaf \
        "$d/nonexistent-ca.crt" "$d/nonexistent-ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "missing CA files must exit 1 (runtime failure)" || return 1
    [ ! -f "$d/leaf.crt.new" ] || { echo "leaf.crt.new leaked"; return 1; }
    [ ! -f "$d/leaf.key.new" ] || { echo "leaf.key.new leaked"; return 1; }
    [ ! -f "$d/leaf.crt" ] || { echo "leaf.crt should not exist"; return 1; }
    [ ! -f "$d/leaf.key" ] || { echo "leaf.key should not exist"; return 1; }
}

test_sign_leaf_does_not_verify_against_other_ca() {
    # Cross-CA contamination check: a leaf signed by CA-A must NOT verify
    # against CA-B. Guards against a regression where the function would
    # silently pick up a different CA from env/PATH.
    local da="$TMPDIR_ROOT/case_cross_ca_a"
    local db="$TMPDIR_ROOT/case_cross_ca_b"
    halos_ca_ensure_auto "$da" || { echo "ensure_auto CA-A failed"; return 1; }
    halos_ca_ensure_auto "$db" || { echo "ensure_auto CA-B failed"; return 1; }
    halos_ca_sign_leaf \
        "$da/ca.crt" "$da/ca.key" \
        "$da/leaf.crt" "$da/leaf.key" \
        "DNS:device.local" "device.local" \
        || { echo "sign_leaf against CA-A failed"; return 1; }
    # Sanity: leaf verifies against its own CA
    openssl verify -CAfile "$da/ca.crt" "$da/leaf.crt" >/dev/null 2>&1 \
        || { echo "leaf should verify against its own CA-A"; return 1; }
    # Real check: leaf does NOT verify against the unrelated CA
    if openssl verify -CAfile "$db/ca.crt" "$da/leaf.crt" >/dev/null 2>&1; then
        echo "leaf signed by CA-A must not verify against CA-B"
        return 1
    fi
}

test_sentinel_compose_format() {
    local out
    out=$(halos_ca_sentinel_compose "aaaa" "bbbb")
    assert_eq "$out" "aaaa:bbbb" "compose should join with single colon" || return 1
}

test_sentinel_classify_match_shape() {
    local s
    s=$(printf '%064d:%064d' 0 0 | tr 0 a)
    local got; got=$(halos_ca_sentinel_classify "$s")
    assert_eq "$got" "match-shape" "64hex:64hex must classify as match-shape" || return 1
}

test_sentinel_classify_legacy() {
    local s; s=$(printf '%064d' 0 | tr 0 a)
    local got; got=$(halos_ca_sentinel_classify "$s")
    assert_eq "$got" "legacy" "64hex must classify as legacy" || return 1
}

test_sentinel_classify_unrecognized() {
    local got
    got=$(halos_ca_sentinel_classify "")
    assert_eq "$got" "unrecognized" "empty must classify as unrecognized" || return 1
    got=$(halos_ca_sentinel_classify "garbage")
    assert_eq "$got" "unrecognized" "non-hex must classify as unrecognized" || return 1
    got=$(halos_ca_sentinel_classify "aaaa:bbbb")
    assert_eq "$got" "unrecognized" "short hex must classify as unrecognized" || return 1
    # Trailing whitespace / newline
    local s; s=$(printf '%064d' 0 | tr 0 a)
    got=$(halos_ca_sentinel_classify "${s}
")
    assert_eq "$got" "unrecognized" "trailing newline must classify as unrecognized" || return 1
}

test_fingerprint_corrupt_cert_errors() {
    # Regression guard: prior version returned 0 with empty stdout when openssl
    # couldn't parse the cert, which cascaded into a re-sign loop in prestart.
    local d="$TMPDIR_ROOT/case_fp_corrupt"
    mkdir -p "$d"
    printf 'not a certificate\n' > "$d/ca.crt"
    halos_ca_fingerprint "$d/ca.crt" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "corrupt cert must exit 1, not silently return empty" || return 1
}

test_ensure_auto_refuses_partial_state() {
    # Only ca.crt present (no ca.key). Function must refuse and exit 1 rather
    # than silently regenerate and orphan a previously-distributed trust anchor.
    local d="$TMPDIR_ROOT/case_partial_crt_only"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    local fp_before; fp_before=$(halos_ca_fingerprint "$d/ca.crt")
    rm -f "$d/ca.key"
    halos_ca_ensure_auto "$d" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "partial state (key missing) must exit 1" || return 1
    # CA cert must not have been regenerated (same fingerprint)
    local fp_after; fp_after=$(halos_ca_fingerprint "$d/ca.crt" 2>/dev/null) || true
    assert_eq "$fp_after" "$fp_before" "ca.crt must not have been overwritten" || return 1
}

test_ensure_auto_refuses_partial_state_key_only() {
    local d="$TMPDIR_ROOT/case_partial_key_only"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    rm -f "$d/ca.crt"
    halos_ca_ensure_auto "$d" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "partial state (crt missing) must exit 1" || return 1
    # ca.key should still be the original (no regeneration)
    [ -f "$d/ca.key" ] || { echo "ca.key should still exist"; return 1; }
}

test_ensure_auto_rotates_expired_ca() {
    # A CA whose notAfter is too close (or in the past) must trigger rotation
    # so a device that booted with a wildly-skewed clock self-heals when NTP
    # catches up. Synthesize an expired CA by overwriting ca.crt with one that
    # already expired, then re-invoking ensure_auto.
    local d="$TMPDIR_ROOT/case_expired"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    local fp_before; fp_before=$(halos_ca_fingerprint "$d/ca.crt")
    # Overwrite ca.crt with a cert that expired yesterday (fresh keypair just
    # for the test fixture). Reuse the existing ca.key so this matches the
    # "both files present but cert is unhealthy" code path.
    local nb na
    nb=$(date -u -d "@$(( $(date -u +%s) - 7200 ))" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) - 7200 ))" +%Y%m%d%H%M%SZ)
    na=$(date -u -d "@$(( $(date -u +%s) - 3600 ))" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) - 3600 ))" +%Y%m%d%H%M%SZ)
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$d/throwaway.key" -out "$d/ca.crt" \
        -not_before "$nb" -not_after "$na" \
        -subj "/CN=expired" >/dev/null 2>&1 \
        || { echo "fixture cert generation failed"; return 1; }
    rm -f "$d/throwaway.key"

    halos_ca_ensure_auto "$d" 2>/dev/null || { echo "ensure_auto should rotate, not fail"; return 1; }
    local fp_after; fp_after=$(halos_ca_fingerprint "$d/ca.crt")
    if [ "$fp_before" = "$fp_after" ]; then
        echo "expired CA was not rotated"
        return 1
    fi
    # And the new CA must itself be healthy
    halos_ca_ensure_auto "$d" || { echo "rotated CA should be considered healthy on next call"; return 1; }
}

test_ensure_auto_dir_mode_is_0700() {
    local d="$TMPDIR_ROOT/case_dir_mode"
    halos_ca_ensure_auto "$d" || return 1
    local mode; mode=$(_stat_mode "$d")
    assert_eq "$mode" "700" "CA directory must be mode 0700" || return 1
}

test_sign_leaf_no_srl_sidecar() {
    # Regression guard: switched from -CAcreateserial to random -set_serial to
    # eliminate the .srl sidecar (which has no recovery path if corrupted).
    local d="$TMPDIR_ROOT/case_no_srl"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    [ ! -f "$d/ca.crt.srl" ] || { echo ".srl sidecar should not be created"; return 1; }
    [ ! -f "$d/ca.srl" ] || { echo ".srl sidecar should not be created"; return 1; }
}

test_sign_leaf_preserves_existing_on_failure() {
    # If signing fails after a previous leaf already exists, the existing leaf
    # and key must remain untouched and no .new debris should be left.
    local d="$TMPDIR_ROOT/case_sign_preserve"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local fp_before; fp_before=$(openssl x509 -in "$d/leaf.crt" -noout -fingerprint -sha256)
    # Now corrupt the CA key to force a sign failure.
    cp "$d/ca.key" "$d/ca.key.bak"
    printf 'not a key\n' > "$d/ca.key"
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        >/dev/null 2>&1
    local rc=$?
    # Restore key for any later assertion
    mv "$d/ca.key.bak" "$d/ca.key"
    [ "$rc" -ne 0 ] || { echo "sign with corrupt CA key should fail"; return 1; }
    [ ! -f "$d/leaf.crt.new" ] || { echo "leaf.crt.new leaked"; return 1; }
    [ ! -f "$d/leaf.key.new" ] || { echo "leaf.key.new leaked"; return 1; }
    local fp_after; fp_after=$(openssl x509 -in "$d/leaf.crt" -noout -fingerprint -sha256)
    assert_eq "$fp_after" "$fp_before" "existing leaf must be preserved on sign failure" || return 1
}

# ---------------------------------------------------------------------------

run_test test_ensure_auto_generates_files
run_test test_ensure_auto_is_idempotent
run_test test_ca_has_required_extensions
run_test test_ca_validity_is_long
run_test test_ca_not_before_is_backdated
run_test test_fingerprint_format
run_test test_fingerprint_missing_file_errors
run_test test_sign_leaf_produces_valid_chain
run_test test_sign_leaf_includes_sans
run_test test_sign_leaf_has_server_auth_eku
run_test test_sign_leaf_missing_args_errors
run_test test_sign_leaf_missing_ca_files_errors
run_test test_sign_leaf_does_not_verify_against_other_ca
run_test test_sentinel_compose_format
run_test test_sentinel_classify_match_shape
run_test test_sentinel_classify_legacy
run_test test_sentinel_classify_unrecognized
run_test test_fingerprint_corrupt_cert_errors
run_test test_ensure_auto_refuses_partial_state
run_test test_ensure_auto_refuses_partial_state_key_only
run_test test_ensure_auto_rotates_expired_ca
run_test test_ensure_auto_dir_mode_is_0700
run_test test_sign_leaf_no_srl_sidecar
run_test test_sign_leaf_preserves_existing_on_failure

echo
echo "Passed: $PASSES, Failed: $FAILS"
[ "$FAILS" -eq 0 ]
