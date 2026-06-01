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

test_validate_pair_happy_path() {
    local d="$TMPDIR_ROOT/case_validate_happy"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_validate_pair "$d/ca.crt" "$d/ca.key" \
        || { echo "freshly-generated CA should validate"; return 1; }
}

test_validate_pair_missing_args() {
    halos_ca_validate_pair "" "" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "2" "missing args must exit 2" || return 1
}

test_validate_pair_missing_files() {
    halos_ca_validate_pair "$TMPDIR_ROOT/nope.crt" "$TMPDIR_ROOT/nope.key" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "missing files must exit 1" || return 1
}

test_validate_pair_rejects_non_ca_cert() {
    # A leaf cert (CA:FALSE) must NOT validate as a CA.
    local d="$TMPDIR_ROOT/case_validate_leaf"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    halos_ca_validate_pair "$d/leaf.crt" "$d/leaf.key" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "leaf cert must not validate as a CA" || return 1
}

test_validate_pair_rejects_mismatched_key() {
    # Cert from CA-A, key from CA-B → must reject.
    local da="$TMPDIR_ROOT/case_validate_mismatch_a"
    local db="$TMPDIR_ROOT/case_validate_mismatch_b"
    halos_ca_ensure_auto "$da" || return 1
    halos_ca_ensure_auto "$db" || return 1
    halos_ca_validate_pair "$da/ca.crt" "$db/ca.key" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "mismatched key must not validate" || return 1
}

test_validate_pair_rejects_corrupt_cert() {
    local d="$TMPDIR_ROOT/case_validate_corrupt"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    printf 'not a cert\n' > "$d/ca.crt"
    halos_ca_validate_pair "$d/ca.crt" "$d/ca.key" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "corrupt cert must not validate" || return 1
}

test_validate_pair_rejects_corrupt_key() {
    local d="$TMPDIR_ROOT/case_validate_corrupt_key"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    printf 'not a key\n' > "$d/ca.key"
    halos_ca_validate_pair "$d/ca.crt" "$d/ca.key" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "corrupt key must not validate" || return 1
}

test_validate_pair_rejects_leaf_with_ca_substrings_in_dn() {
    # Regression for the substring-grep injection: a CA:FALSE leaf whose
    # Subject DN contains both "CA:TRUE" and "Certificate Sign" literals
    # must still be rejected. Pre-fix, halos_ca_validate_pair grepped the
    # full `openssl x509 -text` dump (which includes Subject/Issuer DNs)
    # and accepted this kind of cert as a CA. Post-fix, the function scopes
    # the match to the basicConstraints / keyUsage extensions via
    # `openssl x509 -ext`, so DN contents can't satisfy the gate.
    local d="$TMPDIR_ROOT/case_validate_dn_injection"
    mkdir -p "$d"
    openssl req -x509 -nodes -newkey rsa:2048 -days 7300 \
        -keyout "$d/ca.key" -out "$d/ca.crt" \
        -subj "/CN=Evil Cert/O=CA:TRUE Inc, Certificate Sign Co" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        >/dev/null 2>&1 \
        || { echo "fixture cert generation failed"; return 1; }
    halos_ca_validate_pair "$d/ca.crt" "$d/ca.key" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "leaf with CA-shaped DN substrings must be rejected" || return 1
}

test_validate_pair_warns_on_short_remaining() {
    # Cert with remaining validity in the warn window (below WARN, above MIN)
    # must pass validation BUT log a WARNING to stderr. Lets operators see
    # the impending cliff in journalctl long before the hard floor fires.
    local d="$TMPDIR_ROOT/case_validate_warn_window"
    mkdir -p "$d"
    # 60 days is below the 90d WARN window but above the 30d MIN floor.
    openssl req -x509 -nodes -newkey rsa:2048 -days 60 \
        -keyout "$d/ca.key" -out "$d/ca.crt" \
        -subj "/CN=Aging CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        >/dev/null 2>&1 \
        || { echo "fixture cert generation failed"; return 1; }
    local stderr_capture
    stderr_capture=$(halos_ca_validate_pair "$d/ca.crt" "$d/ca.key" 2>&1)
    local rc=$?
    assert_eq "$rc" "0" "CA in warn window must still pass validation" || return 1
    if ! printf '%s' "$stderr_capture" | grep -q 'WARNING'; then
        echo "expected WARNING on stderr; got: $stderr_capture"
        return 1
    fi
}

test_validate_pair_no_warn_with_ample_remaining() {
    # Cert with > WARN days remaining must pass without any WARNING line —
    # confirms the warn path is gated on the threshold, not always-on.
    local d="$TMPDIR_ROOT/case_validate_no_warn"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    local stderr_capture
    stderr_capture=$(halos_ca_validate_pair "$d/ca.crt" "$d/ca.key" 2>&1)
    local rc=$?
    assert_eq "$rc" "0" "ample-validity CA must pass validation" || return 1
    if printf '%s' "$stderr_capture" | grep -q 'WARNING'; then
        echo "did not expect WARNING for 20-year CA; got: $stderr_capture"
        return 1
    fi
}

test_validate_pair_rejects_ca_without_keycertsign() {
    # A cert with basicConstraints CA:TRUE but keyUsage missing keyCertSign
    # must not validate — exercises the keyCertSign gate in isolation.
    local d="$TMPDIR_ROOT/case_validate_no_keycertsign"
    mkdir -p "$d"
    openssl req -x509 -nodes -newkey rsa:2048 -days 7300 \
        -keyout "$d/ca.key" -out "$d/ca.crt" \
        -subj "/CN=Bad CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        >/dev/null 2>&1 \
        || { echo "fixture cert generation failed"; return 1; }
    halos_ca_validate_pair "$d/ca.crt" "$d/ca.key" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "CA cert without keyCertSign must fail validation" || return 1
}

test_validate_pair_rejects_short_lived_ca() {
    # Operator-supplied CA with remaining validity below the hard floor
    # (HALOS_CA_CUSTOM_REJECT_THRESHOLD_DAYS) must fail validation. The 5-day fixture
    # below puts the cert clearly under the 30-day floor regardless of
    # second-level openssl rounding.
    local d="$TMPDIR_ROOT/case_validate_short_lived"
    mkdir -p "$d"
    openssl req -x509 -nodes -newkey rsa:2048 -days 5 \
        -keyout "$d/ca.key" -out "$d/ca.crt" \
        -subj "/CN=Short-lived CA" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        >/dev/null 2>&1 \
        || { echo "fixture cert generation failed"; return 1; }
    halos_ca_validate_pair "$d/ca.crt" "$d/ca.key" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "CA below the hard-floor remaining-days must fail validation" || return 1
}

test_select_active_retightens_custom_dir_mode() {
    # Defense-in-depth: an operator who widens the custom-CA drop slot
    # (e.g., debugging) must have it re-tightened to 0700 on the next
    # prestart, so the private key isn't left world-traversable.
    local custom="$TMPDIR_ROOT/case_select_chmod"
    local auto="$TMPDIR_ROOT/case_select_chmod_auto"
    local link="$auto/serving-ca.crt"
    halos_ca_ensure_auto "$custom" || return 1
    chmod 0755 "$custom"
    local mode_before; mode_before=$(_stat_mode "$custom")
    assert_eq "$mode_before" "755" "fixture: pre-call mode should be 755" || return 1
    halos_ca_select_active "$custom" "$auto" "$link" || return 1
    local mode_after; mode_after=$(_stat_mode "$custom")
    assert_eq "$mode_after" "700" "custom CA dir mode must be re-tightened to 700" || return 1
}

test_select_active_partial_custom_key_only_fails_loud() {
    # Symmetric to test_select_active_partial_custom_fails_loud — operator
    # drops only ca.key (e.g., mid-copy). Must fail with rc=1 and not
    # silently fall back to auto-CA.
    local custom="$TMPDIR_ROOT/case_select_partial_key"
    local auto="$TMPDIR_ROOT/case_select_partial_key_auto"
    local link="$auto/serving-ca.crt"
    mkdir -p "$custom"
    halos_ca_select_active "$custom" "$auto" "$link" || return 1
    local target_before; target_before=$(readlink "$link")
    halos_ca_ensure_auto "$TMPDIR_ROOT/seed_key_only" || return 1
    cp "$TMPDIR_ROOT/seed_key_only/ca.key" "$custom/ca.key"
    halos_ca_select_active "$custom" "$auto" "$link" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "partial custom CA (key only) must fail with rc=1" || return 1
    local target_after; target_after=$(readlink "$link")
    assert_eq "$target_after" "$target_before" "symlink must not change on validation failure" || return 1
}

test_select_active_no_custom_uses_auto() {
    local custom="$TMPDIR_ROOT/case_select_auto_custom"
    local auto="$TMPDIR_ROOT/case_select_auto_auto"
    local link="$auto/serving-ca.crt"
    mkdir -p "$custom"
    # custom_dir empty → must fall through to auto
    halos_ca_select_active "$custom" "$auto" "$link" \
        || { echo "select_active with no custom should succeed"; return 1; }
    assert_eq "$HALOS_CA_ACTIVE_MODE" "auto" "mode should be auto" || return 1
    assert_eq "$HALOS_CA_ACTIVE_CRT" "$auto/ca.crt" "active cert should be auto" || return 1
    assert_eq "$HALOS_CA_ACTIVE_KEY" "$auto/ca.key" "active key should be auto" || return 1
    [ -L "$link" ] || { echo "symlink should exist"; return 1; }
    local target; target=$(readlink "$link")
    assert_eq "$target" "$auto/ca.crt" "symlink should target auto cert" || return 1
}

test_select_active_valid_custom_takes_precedence() {
    local custom="$TMPDIR_ROOT/case_select_custom"
    local auto="$TMPDIR_ROOT/case_select_custom_auto"
    local link="$auto/serving-ca.crt"
    # Seed a valid custom CA by generating one via the auto helper, then moving it
    halos_ca_ensure_auto "$custom" || return 1
    halos_ca_select_active "$custom" "$auto" "$link" || return 1
    assert_eq "$HALOS_CA_ACTIVE_MODE" "custom" "mode should be custom" || return 1
    assert_eq "$HALOS_CA_ACTIVE_CRT" "$custom/ca.crt" "active cert should be custom" || return 1
    local target; target=$(readlink "$link")
    assert_eq "$target" "$custom/ca.crt" "symlink should target custom cert" || return 1
    # Auto must NOT have been generated when custom won
    [ ! -f "$auto/ca.crt" ] || { echo "auto CA should not exist when custom is active"; return 1; }
}

test_select_active_partial_custom_fails_loud() {
    local custom="$TMPDIR_ROOT/case_select_partial"
    local auto="$TMPDIR_ROOT/case_select_partial_auto"
    local link="$auto/serving-ca.crt"
    # First establish auto so symlink exists and we can verify it's untouched
    mkdir -p "$custom"
    halos_ca_select_active "$custom" "$auto" "$link" || return 1
    local target_before; target_before=$(readlink "$link")
    # Now drop a partial custom (cert only)
    halos_ca_ensure_auto "$TMPDIR_ROOT/seed" || return 1
    cp "$TMPDIR_ROOT/seed/ca.crt" "$custom/ca.crt"
    halos_ca_select_active "$custom" "$auto" "$link" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "partial custom CA must fail with rc=1" || return 1
    # Symlink must not have been retargeted
    local target_after; target_after=$(readlink "$link")
    assert_eq "$target_after" "$target_before" "symlink must not change on validation failure" || return 1
}

test_select_active_invalid_custom_fails_loud() {
    local custom="$TMPDIR_ROOT/case_select_invalid"
    local auto="$TMPDIR_ROOT/case_select_invalid_auto"
    local link="$auto/serving-ca.crt"
    mkdir -p "$custom"
    halos_ca_select_active "$custom" "$auto" "$link" || return 1
    local target_before; target_before=$(readlink "$link")
    # Drop a leaf-shaped cert (CA:FALSE) as if operator made a mistake
    halos_ca_ensure_auto "$TMPDIR_ROOT/seed2" || return 1
    halos_ca_sign_leaf \
        "$TMPDIR_ROOT/seed2/ca.crt" "$TMPDIR_ROOT/seed2/ca.key" \
        "$custom/ca.crt" "$custom/ca.key" \
        "DNS:device.local" "device.local" \
        || return 1
    halos_ca_select_active "$custom" "$auto" "$link" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "invalid custom CA (leaf cert) must fail with rc=1" || return 1
    local target_after; target_after=$(readlink "$link")
    assert_eq "$target_after" "$target_before" "symlink must not change on validation failure" || return 1
}

test_select_active_switch_custom_to_auto() {
    local custom="$TMPDIR_ROOT/case_select_switch_custom"
    local auto="$TMPDIR_ROOT/case_select_switch_auto"
    local link="$auto/serving-ca.crt"
    # Active = custom
    halos_ca_ensure_auto "$custom" || return 1
    halos_ca_select_active "$custom" "$auto" "$link" || return 1
    assert_eq "$HALOS_CA_ACTIVE_MODE" "custom" "should start as custom" || return 1
    # Remove custom → active should switch to auto
    rm -f "$custom/ca.crt" "$custom/ca.key"
    halos_ca_select_active "$custom" "$auto" "$link" || return 1
    assert_eq "$HALOS_CA_ACTIVE_MODE" "auto" "should switch to auto after custom removed" || return 1
    local target; target=$(readlink "$link")
    assert_eq "$target" "$auto/ca.crt" "symlink should retarget to auto" || return 1
}

test_select_active_switch_auto_to_custom() {
    local custom="$TMPDIR_ROOT/case_select_switch2_custom"
    local auto="$TMPDIR_ROOT/case_select_switch2_auto"
    local link="$auto/serving-ca.crt"
    mkdir -p "$custom"
    # Active = auto initially
    halos_ca_select_active "$custom" "$auto" "$link" || return 1
    assert_eq "$HALOS_CA_ACTIVE_MODE" "auto" "should start as auto" || return 1
    # Drop a valid custom → active should switch
    halos_ca_ensure_auto "$TMPDIR_ROOT/seed3" || return 1
    cp "$TMPDIR_ROOT/seed3/ca.crt" "$custom/ca.crt"
    cp "$TMPDIR_ROOT/seed3/ca.key" "$custom/ca.key"
    halos_ca_select_active "$custom" "$auto" "$link" || return 1
    assert_eq "$HALOS_CA_ACTIVE_MODE" "custom" "should switch to custom after drop" || return 1
    local target; target=$(readlink "$link")
    assert_eq "$target" "$custom/ca.crt" "symlink should retarget to custom" || return 1
}

test_cockpit_install_leaf_writes_valid_combined_pem() {
    local d="$TMPDIR_ROOT/case_cockpit_happy"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local out="$d/99-halos.cert"
    halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$out" \
        || { echo "cockpit_install_leaf returned non-zero"; return 1; }
    [ -f "$out" ] || { echo "combined PEM not created"; return 1; }
    # Cert must parse from the combined file
    openssl x509 -in "$out" -noout >/dev/null 2>&1 \
        || { echo "combined PEM does not parse as cert"; return 1; }
    # Key must parse from the combined file
    openssl pkey -in "$out" -noout >/dev/null 2>&1 \
        || { echo "combined PEM does not parse as key"; return 1; }
    # Key must match the cert
    local crt_pub key_pub
    crt_pub=$(openssl x509 -in "$out" -noout -pubkey 2>/dev/null)
    key_pub=$(openssl pkey -in "$out" -pubout 2>/dev/null)
    assert_eq "$crt_pub" "$key_pub" "combined PEM key must match cert" || return 1
}

test_cockpit_install_leaf_mode_is_0640() {
    local d="$TMPDIR_ROOT/case_cockpit_mode"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local out="$d/99-halos.cert"
    halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$out" || return 1
    local mode; mode=$(_stat_mode "$out")
    assert_eq "$mode" "640" "combined PEM mode must be 0640" || return 1
}

test_cockpit_install_leaf_rejects_mismatched_pair() {
    # Cross-CA fixture: leaf from CA-A, key from a CA-B-signed leaf. Same
    # pattern as test_sign_leaf_does_not_verify_against_other_ca, but applied
    # to the cockpit install path which must reject the mismatch.
    local da="$TMPDIR_ROOT/case_cockpit_mismatch_a"
    local db="$TMPDIR_ROOT/case_cockpit_mismatch_b"
    halos_ca_ensure_auto "$da" || return 1
    halos_ca_ensure_auto "$db" || return 1
    halos_ca_sign_leaf \
        "$da/ca.crt" "$da/ca.key" \
        "$da/leaf.crt" "$da/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    halos_ca_sign_leaf \
        "$db/ca.crt" "$db/ca.key" \
        "$db/leaf.crt" "$db/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local out="$TMPDIR_ROOT/case_cockpit_mismatch_out.cert"
    halos_cockpit_install_leaf "$da/leaf.crt" "$db/leaf.key" "$out" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "mismatched cert/key must exit 1" || return 1
    [ ! -f "$out" ] || { echo "no output file should be written on validation failure"; return 1; }
    ! ls "${out}".new.* >/dev/null 2>&1 || { echo "no .new.<pid> debris should remain on failure"; return 1; }
}

test_cockpit_install_leaf_preserves_existing_on_failure() {
    # Write a good combined PEM first, then call with a mismatched pair and
    # confirm the existing file is unchanged. Mirrors the
    # test_sign_leaf_preserves_existing_on_failure invariant.
    local da="$TMPDIR_ROOT/case_cockpit_preserve_a"
    local db="$TMPDIR_ROOT/case_cockpit_preserve_b"
    halos_ca_ensure_auto "$da" || return 1
    halos_ca_ensure_auto "$db" || return 1
    halos_ca_sign_leaf \
        "$da/ca.crt" "$da/ca.key" \
        "$da/leaf.crt" "$da/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    halos_ca_sign_leaf \
        "$db/ca.crt" "$db/ca.key" \
        "$db/leaf.crt" "$db/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local out="$TMPDIR_ROOT/case_cockpit_preserve_out.cert"
    # Install the good pair first
    halos_cockpit_install_leaf "$da/leaf.crt" "$da/leaf.key" "$out" || return 1
    local good_hash; good_hash=$(openssl dgst -sha256 "$out" | awk '{print $NF}')
    # Now call with a mismatched pair — must fail and leave existing file unchanged
    halos_cockpit_install_leaf "$da/leaf.crt" "$db/leaf.key" "$out" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "mismatched pair must fail with rc=1" || return 1
    local after_hash; after_hash=$(openssl dgst -sha256 "$out" | awk '{print $NF}')
    assert_eq "$after_hash" "$good_hash" "previous combined PEM must be preserved on failure" || return 1
    ! ls "${out}".new.* >/dev/null 2>&1 || { echo "no .new.<pid> debris should remain on failure"; return 1; }
}

test_cockpit_install_leaf_no_new_debris_on_success() {
    local d="$TMPDIR_ROOT/case_cockpit_no_debris"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local out="$d/99-halos.cert"
    halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$out" || return 1
    ! ls "${out}".new.* >/dev/null 2>&1 || { echo ".new.<pid> sibling should not remain after success"; return 1; }
}

test_cockpit_install_leaf_missing_args_errors() {
    halos_cockpit_install_leaf "" "" "" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "2" "missing args must exit 2 (caller bug)" || return 1
}

test_cockpit_install_leaf_missing_files_errors() {
    local d="$TMPDIR_ROOT/case_cockpit_missing_files"
    mkdir -p "$d"
    halos_cockpit_install_leaf "$d/nope.crt" "$d/nope.key" "$d/out.cert" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "missing source files must exit 1 (runtime failure)" || return 1
    [ ! -f "$d/out.cert" ] || { echo "no output file should be written"; return 1; }
    # The PID-suffixed .new sibling must not leak either.
    ! ls "$d"/out.cert.new.* >/dev/null 2>&1 || { echo "no .new.<pid> debris should remain"; return 1; }
}

test_cockpit_install_leaf_missing_cert_only_isolates_branch() {
    # Regression for the unit-test that previously passed BOTH paths missing,
    # so only the leaf_crt branch ever fired. Pass a real key and a missing
    # cert; rc must be 1 and the diagnostic must be the cert-missing one.
    local d="$TMPDIR_ROOT/case_cockpit_missing_cert_only"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    rm -f "$d/leaf.crt"
    local stderr_capture
    stderr_capture=$(halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$d/out.cert" 2>&1)
    local rc=$?
    assert_eq "$rc" "1" "missing-cert-only must exit 1" || return 1
    if ! printf '%s' "$stderr_capture" | grep -q 'leaf cert missing'; then
        echo "expected 'leaf cert missing' diagnostic; got: $stderr_capture"
        return 1
    fi
}

test_cockpit_install_leaf_missing_key_only_isolates_branch() {
    # Symmetric: real cert, missing key. Drives the leaf_key branch which the
    # combined-both-missing test never exercised.
    local d="$TMPDIR_ROOT/case_cockpit_missing_key_only"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    rm -f "$d/leaf.key"
    local stderr_capture
    stderr_capture=$(halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$d/out.cert" 2>&1)
    local rc=$?
    assert_eq "$rc" "1" "missing-key-only must exit 1" || return 1
    if ! printf '%s' "$stderr_capture" | grep -q 'leaf key missing'; then
        echo "expected 'leaf key missing' diagnostic; got: $stderr_capture"
        return 1
    fi
}

test_cockpit_install_leaf_rejects_malformed_cert() {
    # Cert content is garbage but key is well-formed. Must fail the cert-parse
    # early-exit branch (lib-ca.sh openssl x509 -in -noout) before reaching
    # the key-match check, returning rc=1 with no output file.
    local d="$TMPDIR_ROOT/case_cockpit_malformed_cert"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    printf 'not a certificate\n' > "$d/leaf.crt"
    local out="$d/99-halos.cert"
    halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$out" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "malformed cert must exit 1" || return 1
    [ ! -f "$out" ] || { echo "no output should be written"; return 1; }
}

test_cockpit_install_leaf_rejects_malformed_key() {
    # Symmetric: well-formed cert, garbage key. Must fail the key-parse
    # early-exit branch.
    local d="$TMPDIR_ROOT/case_cockpit_malformed_key"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    printf 'not a key\n' > "$d/leaf.key"
    local out="$d/99-halos.cert"
    halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$out" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "malformed key must exit 1" || return 1
    [ ! -f "$out" ] || { echo "no output should be written"; return 1; }
}

test_cockpit_install_leaf_logs_notice_when_group_missing() {
    # Shadow `getent` inside a subshell to force the group-absent path.
    # Must succeed (rc=0), leave the file in place, and emit a NOTICE.
    local d="$TMPDIR_ROOT/case_cockpit_group_missing"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local out="$d/99-halos.cert"
    local stderr_capture rc
    stderr_capture=$(
        getent() { return 2; }
        halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$out" 2>&1
    )
    rc=$?
    assert_eq "$rc" "0" "group-absent path must still succeed" || return 1
    [ -f "$out" ] || { echo "output file must exist"; return 1; }
    if ! printf '%s' "$stderr_capture" | grep -q 'NOTICE.*cockpit-ws group not found'; then
        echo "expected NOTICE on stderr; got: $stderr_capture"
        return 1
    fi
}

test_cockpit_install_leaf_rc1_when_chown_fails_with_group_present() {
    # Shadow `getent` to return success AND `chown` to return failure. The
    # helper must rm the .new debris, log loudly, and rc=1 — the previous
    # silent-success behavior (root:root file with the cockpit-ws group bit
    # useless) is what cockpit-tls cannot recover from.
    local d="$TMPDIR_ROOT/case_cockpit_chown_fails"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local out="$d/99-halos.cert"
    local stderr_capture rc
    stderr_capture=$(
        getent() { return 0; }
        chown() { return 1; }
        halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$out" 2>&1
    )
    rc=$?
    assert_eq "$rc" "1" "chown failure with group present must exit 1" || return 1
    [ ! -f "$out" ] || { echo "no output file should be written"; return 1; }
    ! ls "$d"/99-halos.cert.new.* >/dev/null 2>&1 || { echo "no .new.<pid> debris should remain"; return 1; }
    if ! printf '%s' "$stderr_capture" | grep -q 'chown root:cockpit-ws failed'; then
        echo "expected chown-fail diagnostic; got: $stderr_capture"
        return 1
    fi
}

test_cockpit_install_leaf_refuses_directory_at_out_path() {
    # Defense-in-depth: a pre-existing directory at out_path would cause plain
    # `mv` to silently move the .new file INTO it, masking the install. The
    # helper must detect this and refuse.
    local d="$TMPDIR_ROOT/case_cockpit_dir_at_out"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local out="$d/99-halos.cert"
    mkdir -p "$out"   # out_path is now a directory
    local stderr_capture
    stderr_capture=$(halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$out" 2>&1)
    local rc=$?
    assert_eq "$rc" "1" "directory at out_path must exit 1" || return 1
    [ -d "$out" ] || { echo "directory at out_path must be preserved (we don't rm it)"; return 1; }
    ! ls "$d"/99-halos.cert.new.* >/dev/null 2>&1 || { echo "no .new.<pid> debris should remain"; return 1; }
    if ! printf '%s' "$stderr_capture" | grep -q 'refusing to install over directory'; then
        echo "expected directory-refusal diagnostic; got: $stderr_capture"
        return 1
    fi
}

test_cockpit_install_leaf_no_symlink_follow_on_new() {
    # Pre-create out_path.new.<pid> as a symlink pointing at a canary file.
    # Helper must rm the symlink before writing (rm -f unlinks without
    # following), so the canary's contents are untouched. The PID-suffixed
    # name makes the symlink-attack guess race-prone in practice but the
    # rm-before-cat guarantees it across both shapes.
    local d="$TMPDIR_ROOT/case_cockpit_symlink"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local out="$d/99-halos.cert"
    local canary="$d/canary"
    printf 'canary contents must not be overwritten\n' > "$canary"
    # Plant a symlink at the exact PID-suffixed stage path so the rm-before-cat
    # guard is exercised. $$ inside this test is the parent shell pid; the
    # helper invocation runs in the same shell, so $$ matches.
    ln -s "$canary" "${out}.new.$$"
    halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$out" || return 1
    # Canary contents must be unchanged: the helper must not have followed
    # the symlink and written the leaf key into the canary.
    if ! grep -q 'canary contents must not be overwritten' "$canary"; then
        echo "canary was overwritten — symlink was followed"
        return 1
    fi
    [ -f "$out" ] || { echo "install must still succeed"; return 1; }
}

test_cockpit_install_leaf_write_failure_with_missing_parent() {
    # out_path under a nonexistent directory: helper does not mkdir -p
    # parents, so the cat redirection fails. Must rc=1 with no debris and
    # the cat-fail diagnostic.
    local d="$TMPDIR_ROOT/case_cockpit_write_fail"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local stderr_capture
    stderr_capture=$(halos_cockpit_install_leaf "$d/leaf.crt" "$d/leaf.key" "$d/no/such/dir/out.cert" 2>&1)
    local rc=$?
    assert_eq "$rc" "1" "missing parent dir must exit 1" || return 1
    [ ! -d "$d/no" ] || { echo "helper must not have created parent dirs"; return 1; }
    if ! printf '%s' "$stderr_capture" | grep -q 'failed to write combined PEM'; then
        echo "expected write-failure diagnostic; got: $stderr_capture"
        return 1
    fi
}

test_publish_public_happy_path() {
    # Publishes file at <dir>/halos-ca.crt with mode 0644, matching content.
    local d="$TMPDIR_ROOT/case_publish_happy"
    local pub="$d/public"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_public "$d/ca.crt" "$pub" \
        || { echo "publish_public returned non-zero"; return 1; }
    [ -f "$pub/halos-ca.crt" ] || { echo "published file not created"; return 1; }
    local mode; mode=$(_stat_mode "$pub/halos-ca.crt")
    assert_eq "$mode" "644" "published file mode must be 0644" || return 1
    # Content must match the source byte-for-byte.
    if ! cmp -s "$d/ca.crt" "$pub/halos-ca.crt"; then
        echo "published file content does not match source"
        return 1
    fi
}

test_publish_public_creates_parent_dir() {
    # If <public_dir> doesn't exist, helper creates it with mode 0755.
    local d="$TMPDIR_ROOT/case_publish_mkdir"
    local pub="$d/no/such/dir/yet"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_public "$d/ca.crt" "$pub" || return 1
    [ -d "$pub" ] || { echo "parent dir not created"; return 1; }
    local mode; mode=$(_stat_mode "$pub")
    assert_eq "$mode" "755" "public dir mode must be 0755" || return 1
}

test_publish_public_swap_updates_content() {
    # Central correctness claim of PR #136: published file tracks the active CA.
    # Publish CA-A, then re-publish CA-B and confirm the served bytes change.
    local da="$TMPDIR_ROOT/case_publish_swap_a"
    local db="$TMPDIR_ROOT/case_publish_swap_b"
    local pub="$TMPDIR_ROOT/case_publish_swap_pub"
    halos_ca_ensure_auto "$da" || return 1
    halos_ca_ensure_auto "$db" || return 1
    halos_ca_publish_public "$da/ca.crt" "$pub" || return 1
    local hash_a; hash_a=$(openssl dgst -sha256 "$pub/halos-ca.crt" | awk '{print $NF}')
    halos_ca_publish_public "$db/ca.crt" "$pub" || return 1
    local hash_b; hash_b=$(openssl dgst -sha256 "$pub/halos-ca.crt" | awk '{print $NF}')
    if [ "$hash_a" = "$hash_b" ]; then
        echo "swap-CA scenario: published content did not change"
        return 1
    fi
    # And the new bytes must match the new source.
    if ! cmp -s "$db/ca.crt" "$pub/halos-ca.crt"; then
        echo "swapped published file does not match new source"
        return 1
    fi
}

test_publish_public_missing_args_errors() {
    halos_ca_publish_public "" "" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "2" "missing args must exit 2 (caller bug)" || return 1
}

test_publish_public_missing_source_errors() {
    local d="$TMPDIR_ROOT/case_publish_missing_src"
    mkdir -p "$d"
    halos_ca_publish_public "$d/nope.crt" "$d/public" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "missing source must exit 1 (runtime failure)" || return 1
    [ ! -f "$d/public/halos-ca.crt" ] || { echo "no output should be written"; return 1; }
}

test_publish_public_rejects_non_cert_source() {
    # Source exists but isn't a parseable X.509 cert. Validation step must
    # catch this and refuse to publish (otherwise the sidecar would serve
    # garbage bytes with the wrong Content-Type to operators).
    local d="$TMPDIR_ROOT/case_publish_bad_src"
    local pub="$d/public"
    mkdir -p "$d"
    printf 'not a certificate\n' > "$d/bad.crt"
    halos_ca_publish_public "$d/bad.crt" "$pub" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "non-cert source must exit 1" || return 1
    [ ! -f "$pub/halos-ca.crt" ] || { echo "no output should be written"; return 1; }
    ! ls "$pub"/halos-ca.crt.new.* >/dev/null 2>&1 || { echo "no .new debris should remain"; return 1; }
}

test_publish_public_preserves_existing_on_failure() {
    # First publish succeeds; second publish (with bad source) must leave the
    # first file unchanged.
    local d="$TMPDIR_ROOT/case_publish_preserve"
    local pub="$d/public"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_public "$d/ca.crt" "$pub" || return 1
    local good_hash; good_hash=$(openssl dgst -sha256 "$pub/halos-ca.crt" | awk '{print $NF}')
    # Bad source — must fail and leave the existing published file intact.
    printf 'not a certificate\n' > "$d/bad.crt"
    halos_ca_publish_public "$d/bad.crt" "$pub" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "bad source must fail with rc=1" || return 1
    local after_hash; after_hash=$(openssl dgst -sha256 "$pub/halos-ca.crt" | awk '{print $NF}')
    assert_eq "$after_hash" "$good_hash" "previous published file must be preserved on failure" || return 1
}

test_publish_public_refuses_directory_at_output() {
    # Defense-in-depth: a pre-existing directory at <pub>/halos-ca.crt would
    # make plain mv silently move .new INTO it. Helper must refuse.
    local d="$TMPDIR_ROOT/case_publish_dir_at_out"
    local pub="$d/public"
    mkdir -p "$d" "$pub/halos-ca.crt"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_public "$d/ca.crt" "$pub" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "directory at out_path must exit 1" || return 1
    [ -d "$pub/halos-ca.crt" ] || { echo "directory must be preserved"; return 1; }
    ! ls "$pub"/halos-ca.crt.new.* >/dev/null 2>&1 || { echo "no .new debris should remain"; return 1; }
}

test_publish_public_no_new_debris_on_success() {
    local d="$TMPDIR_ROOT/case_publish_no_debris"
    local pub="$d/public"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_public "$d/ca.crt" "$pub" || return 1
    ! ls "$pub"/halos-ca.crt.new.* >/dev/null 2>&1 || { echo ".new.<pid> sibling should not remain after success"; return 1; }
}

# Decode the base64 <data> payload from a .mobileconfig into a DER file.
# Pulls the single-line base64 between the <data> tags (our generator emits it
# flattened), strips whitespace, and base64-decodes. Echoes the DER path.
_extract_mobileconfig_der() {
    local mc="$1" out="$2"
    sed -n 's|.*<data>\(.*\)</data>.*|\1|p' "$mc" | head -1 | tr -d ' \t' | base64 -d > "$out" 2>/dev/null
}

test_publish_mobileconfig_happy_path() {
    local d="$TMPDIR_ROOT/case_mc_happy"
    local pub="$d/public"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_mobileconfig "$d/ca.crt" "$pub" "halosdev.local" \
        || { echo "publish_mobileconfig returned non-zero"; return 1; }
    local mc="$pub/halos-ca.mobileconfig"
    [ -f "$mc" ] || { echo ".mobileconfig not created"; return 1; }
    grep -q '<plist version="1.0">' "$mc" || { echo "missing plist root"; return 1; }
    grep -q 'com.apple.security.root' "$mc" || { echo "missing root payload type"; return 1; }
    local mode; mode=$(_stat_mode "$mc")
    assert_eq "$mode" "644" ".mobileconfig must be mode 0644" || return 1
}

test_publish_mobileconfig_der_round_trips() {
    # The CA embedded in the profile must be byte-identical to the input CA:
    # decode the <data> payload back to DER and compare fingerprints.
    local d="$TMPDIR_ROOT/case_mc_roundtrip"
    local pub="$d/public"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    local src_fp; src_fp=$(halos_ca_fingerprint "$d/ca.crt") || return 1
    halos_ca_publish_mobileconfig "$d/ca.crt" "$pub" "halosdev.local" || return 1
    local der="$d/extracted.der"
    _extract_mobileconfig_der "$pub/halos-ca.mobileconfig" "$der"
    [ -s "$der" ] || { echo "failed to extract DER payload"; return 1; }
    local pem_fp
    pem_fp=$(openssl x509 -inform DER -in "$der" -noout -fingerprint -sha256 2>/dev/null \
        | sed -e 's/^.*Fingerprint=//' -e 's/://g' | tr '[:upper:]' '[:lower:]')
    assert_eq "$pem_fp" "$src_fp" "embedded CA DER must match the source CA" || return 1
}

test_publish_mobileconfig_embeds_display_host() {
    local d="$TMPDIR_ROOT/case_mc_host"
    local pub="$d/public"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_mobileconfig "$d/ca.crt" "$pub" "boat-pi.local" || return 1
    grep -q 'HaLOS Device CA (boat-pi.local)' "$pub/halos-ca.mobileconfig" \
        || { echo "display host not embedded in PayloadDisplayName"; return 1; }
}

test_publish_mobileconfig_is_deterministic() {
    # Same CA + host on two runs → byte-identical output (fixed UUIDs). Guards
    # against a regression to random UUIDs, which would make every rotation
    # look like a content change to clients diffing the file.
    local d="$TMPDIR_ROOT/case_mc_determ"
    local pub="$d/public"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_mobileconfig "$d/ca.crt" "$pub" "halosdev.local" || return 1
    local h1; h1=$(openssl dgst -sha256 "$pub/halos-ca.mobileconfig" | awk '{print $NF}')
    halos_ca_publish_mobileconfig "$d/ca.crt" "$pub" "halosdev.local" || return 1
    local h2; h2=$(openssl dgst -sha256 "$pub/halos-ca.mobileconfig" | awk '{print $NF}')
    assert_eq "$h2" "$h1" "same CA + host must produce byte-identical output" || return 1
}

test_publish_mobileconfig_missing_args_errors() {
    halos_ca_publish_mobileconfig "" "" "" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "2" "missing args must exit 2 (caller bug)" || return 1
}

test_publish_mobileconfig_missing_source_errors() {
    local d="$TMPDIR_ROOT/case_mc_missing_src"
    mkdir -p "$d"
    halos_ca_publish_mobileconfig "$d/nope.crt" "$d/public" "halosdev.local" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "missing source must exit 1 (runtime failure)" || return 1
    [ ! -f "$d/public/halos-ca.mobileconfig" ] || { echo "no output should be written"; return 1; }
}

test_publish_mobileconfig_rejects_non_cert_source() {
    local d="$TMPDIR_ROOT/case_mc_bad_src"
    local pub="$d/public"
    mkdir -p "$d"
    printf 'not a certificate\n' > "$d/bad.crt"
    halos_ca_publish_mobileconfig "$d/bad.crt" "$pub" "halosdev.local" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "non-cert source must exit 1" || return 1
    [ ! -f "$pub/halos-ca.mobileconfig" ] || { echo "no output should be written"; return 1; }
    ! ls "$pub"/halos-ca.mobileconfig.new.* >/dev/null 2>&1 || { echo "no .new debris should remain"; return 1; }
}

test_publish_mobileconfig_uuid_is_per_ca() {
    # Two distinct CAs must yield distinct PayloadUUIDs — the fleet-collision
    # guard. A regression to fixed UUIDs would make a second device's profile
    # silently replace the first on the same Apple device.
    local da="$TMPDIR_ROOT/case_mc_uuid_a"
    local db="$TMPDIR_ROOT/case_mc_uuid_b"
    mkdir -p "$da" "$db"
    halos_ca_ensure_auto "$da" || return 1
    halos_ca_ensure_auto "$db" || return 1
    halos_ca_publish_mobileconfig "$da/ca.crt" "$da/pub" "halosdev.local" || return 1
    halos_ca_publish_mobileconfig "$db/ca.crt" "$db/pub" "halosdev.local" || return 1
    # First <string> after the outer PayloadUUID key.
    local ua ub
    ua=$(grep -A1 '<key>PayloadUUID</key>' "$da/pub/halos-ca.mobileconfig" | grep '<string>' | head -1)
    ub=$(grep -A1 '<key>PayloadUUID</key>' "$db/pub/halos-ca.mobileconfig" | grep '<string>' | head -1)
    [ -n "$ua" ] || { echo "no PayloadUUID found"; return 1; }
    if [ "$ua" = "$ub" ]; then
        echo "distinct CAs produced identical PayloadUUID ($ua) — fleet collision"
        return 1
    fi
}

test_publish_mobileconfig_refuses_directory_at_output() {
    local d="$TMPDIR_ROOT/case_mc_dir_at_out"
    local pub="$d/public"
    mkdir -p "$d" "$pub/halos-ca.mobileconfig"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_mobileconfig "$d/ca.crt" "$pub" "halosdev.local" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "directory at out_path must exit 1" || return 1
    [ -d "$pub/halos-ca.mobileconfig" ] || { echo "directory must be preserved"; return 1; }
    ! ls "$pub"/halos-ca.mobileconfig.new.* >/dev/null 2>&1 || { echo "no .new debris should remain"; return 1; }
}

test_publish_mobileconfig_no_new_debris_on_success() {
    local d="$TMPDIR_ROOT/case_mc_no_debris"
    local pub="$d/public"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_mobileconfig "$d/ca.crt" "$pub" "halosdev.local" || return 1
    ! ls "$pub"/halos-ca.mobileconfig.new.* >/dev/null 2>&1 || { echo ".new.<pid> sibling should not remain after success"; return 1; }
}

test_publish_mobileconfig_preserves_existing_on_failure() {
    local d="$TMPDIR_ROOT/case_mc_preserve"
    local pub="$d/public"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_publish_mobileconfig "$d/ca.crt" "$pub" "halosdev.local" || return 1
    local good_hash; good_hash=$(openssl dgst -sha256 "$pub/halos-ca.mobileconfig" | awk '{print $NF}')
    printf 'not a certificate\n' > "$d/bad.crt"
    halos_ca_publish_mobileconfig "$d/bad.crt" "$pub" "halosdev.local" >/dev/null 2>&1
    local rc=$?
    assert_eq "$rc" "1" "bad source must fail with rc=1" || return 1
    local after_hash; after_hash=$(openssl dgst -sha256 "$pub/halos-ca.mobileconfig" | awk '{print $NF}')
    assert_eq "$after_hash" "$good_hash" "previous .mobileconfig must be preserved on failure" || return 1
}

test_sign_leaf_validity_under_apple_825_day_cap() {
    # Apple's Secure Transport rejects SSL leaves with validity > 825 days
    # (CA/B Forum baseline + Apple policy since 2019-07-01). Catch any
    # future bump of HALOS_CA_LEAF_VALIDITY_DAYS that would break TLS validation on
    # macOS/iOS clients.
    local d="$TMPDIR_ROOT/case_leaf_validity_825"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local not_before not_after nb_epoch na_epoch validity_days
    not_before=$(openssl x509 -in "$d/leaf.crt" -noout -startdate | cut -d= -f2)
    not_after=$(openssl x509 -in "$d/leaf.crt" -noout -enddate | cut -d= -f2)
    nb_epoch=$(_parse_openssl_date "$not_before")
    na_epoch=$(_parse_openssl_date "$not_after")
    validity_days=$(( (na_epoch - nb_epoch) / 86400 ))
    # 825 is the Apple ceiling. Allow exactly 825 (the cert's notAfter -
    # notBefore is days, openssl computes inclusively). Reject anything
    # higher.
    if [ "$validity_days" -gt 825 ]; then
        echo "Leaf validity $validity_days days exceeds Apple's 825-day cap"
        return 1
    fi
}

test_leaf_needs_renewal_when_fresh_returns_false() {
    # A freshly signed leaf has ~825 days of validity, well above the 60-day
    # renewal threshold, so halos_ca_leaf_needs_renewal must report 1 (no
    # renewal needed).
    local d="$TMPDIR_ROOT/case_leaf_renewal_fresh"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    halos_ca_leaf_needs_renewal "$d/leaf.crt"
    local rc=$?
    assert_eq "$rc" "1" "fresh leaf must not need renewal" || return 1
}

test_leaf_needs_renewal_when_missing_returns_true() {
    # Defensive: a missing leaf is treated as "needs renewal" so the prestart
    # check covers the "leaf file deleted out from under us" case without
    # depending on the sentinel branch firing first.
    local d="$TMPDIR_ROOT/case_leaf_renewal_missing"
    mkdir -p "$d"
    halos_ca_leaf_needs_renewal "$d/no-such-leaf.crt"
    local rc=$?
    assert_eq "$rc" "0" "missing leaf must report needs-renewal" || return 1
}

test_leaf_needs_renewal_when_approaching_expiry_returns_true() {
    # Synthesize a leaf whose notAfter is 30 days away (< HALOS_CA_LEAF_RENEW_THRESHOLD_DAYS=60).
    # Renewal must fire even though the cert is still technically valid.
    local d="$TMPDIR_ROOT/case_leaf_renewal_approaching"
    mkdir -p "$d"
    local nb na
    nb=$(date -u -d "@$(( $(date -u +%s) - 7200 ))" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) - 7200 ))" +%Y%m%d%H%M%SZ)
    na=$(date -u -d "@$(( $(date -u +%s) + 30 * 86400 ))" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) + 30 * 86400 ))" +%Y%m%d%H%M%SZ)
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$d/throwaway.key" -out "$d/short-leaf.crt" \
        -not_before "$nb" -not_after "$na" \
        -subj "/CN=expiring" >/dev/null 2>&1 \
        || { echo "fixture cert generation failed"; return 1; }
    halos_ca_leaf_needs_renewal "$d/short-leaf.crt"
    local rc=$?
    assert_eq "$rc" "0" "leaf within renewal window must report needs-renewal" || return 1
}

test_leaf_needs_renewal_when_well_outside_window_returns_false() {
    # Leaf with 365 days remaining (well above the 60-day window) must not
    # trigger renewal — confirms the threshold is honored, not always-on.
    local d="$TMPDIR_ROOT/case_leaf_renewal_far"
    mkdir -p "$d"
    local nb na
    nb=$(date -u -d "@$(( $(date -u +%s) - 7200 ))" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) - 7200 ))" +%Y%m%d%H%M%SZ)
    na=$(date -u -d "@$(( $(date -u +%s) + 365 * 86400 ))" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) + 365 * 86400 ))" +%Y%m%d%H%M%SZ)
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$d/throwaway.key" -out "$d/long-leaf.crt" \
        -not_before "$nb" -not_after "$na" \
        -subj "/CN=fresh-enough" >/dev/null 2>&1 \
        || { echo "fixture cert generation failed"; return 1; }
    halos_ca_leaf_needs_renewal "$d/long-leaf.crt"
    local rc=$?
    assert_eq "$rc" "1" "leaf well outside renewal window must not need renewal" || return 1
}

test_leaf_needs_renewal_when_already_expired_returns_true() {
    # Leaf whose notAfter is in the past must report needs-renewal. Covers the
    # branch where _halos_ca_is_healthy fails because the cert is past its
    # validity window, distinct from the "approaching expiry" case (which is
    # still technically valid but inside the renew threshold).
    local d="$TMPDIR_ROOT/case_leaf_renewal_expired"
    mkdir -p "$d"
    local nb na
    nb=$(date -u -d "@$(( $(date -u +%s) - 7 * 86400 ))" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) - 7 * 86400 ))" +%Y%m%d%H%M%SZ)
    na=$(date -u -d "@$(( $(date -u +%s) - 86400 ))" +%Y%m%d%H%M%SZ 2>/dev/null \
        || date -u -r "$(( $(date -u +%s) - 86400 ))" +%Y%m%d%H%M%SZ)
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$d/throwaway.key" -out "$d/expired-leaf.crt" \
        -not_before "$nb" -not_after "$na" \
        -subj "/CN=expired" >/dev/null 2>&1 \
        || { echo "fixture cert generation failed"; return 1; }
    halos_ca_leaf_needs_renewal "$d/expired-leaf.crt"
    local rc=$?
    assert_eq "$rc" "0" "already-expired leaf must report needs-renewal" || return 1
}

test_sign_leaf_default_validity_uses_apple_compliant_days() {
    # Regression guard: a future change to HALOS_CA_LEAF_VALIDITY_DAYS that
    # crosses Apple's 825-day ceiling must be caught even when callers omit
    # the explicit 7th argument. Complements
    # test_sign_leaf_validity_under_apple_825_day_cap, which calls with the
    # constant directly via the default; this test asserts the default
    # actually IS the safe value (not coupled to which constant supplies it).
    local d="$TMPDIR_ROOT/case_leaf_default_validity"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    halos_ca_sign_leaf \
        "$d/ca.crt" "$d/ca.key" \
        "$d/leaf.crt" "$d/leaf.key" \
        "DNS:device.local" "device.local" \
        || return 1
    local not_before not_after nb_epoch na_epoch validity_days
    not_before=$(openssl x509 -in "$d/leaf.crt" -noout -startdate | cut -d= -f2)
    not_after=$(openssl x509 -in "$d/leaf.crt" -noout -enddate | cut -d= -f2)
    nb_epoch=$(_parse_openssl_date "$not_before")
    na_epoch=$(_parse_openssl_date "$not_after")
    validity_days=$(( (na_epoch - nb_epoch) / 86400 ))
    if [ "$validity_days" -gt 825 ]; then
        echo "Default leaf validity $validity_days days exceeds Apple's 825-day cap"
        return 1
    fi
    # Floor guard: catch an accidental drop to a uselessly short lifetime
    # (e.g., someone setting the constant to 1 by mistake). 30 days is a
    # generous lower bound — well below the documented 824 default but
    # above any value that would be obviously broken.
    if [ "$validity_days" -lt 30 ]; then
        echo "Default leaf validity $validity_days days is implausibly short"
        return 1
    fi
}

# --- Adoption sentinel -----------------------------------------------------

_stat_inode() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }

# Write a CA cert with an arbitrary subject CN at <path>, for CN-classification
# tests. Only the subject matters here; extensions are irrelevant to the
# adoption classifier (it reads the CN, not basicConstraints).
_mk_ca_with_cn() {
    local crt="$1" cn="$2"
    openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
        -keyout "${crt}.key" -out "$crt" -subj "/CN=${cn}" >/dev/null 2>&1
}

test_ensure_auto_sets_created_flag_on_bootstrap() {
    local d="$TMPDIR_ROOT/case_adopt_flag_bootstrap"
    mkdir -p "$d"
    HALOS_CA_AUTO_CREATED=
    halos_ca_ensure_auto "$d" || return 1
    assert_eq "$HALOS_CA_AUTO_CREATED" "1" "bootstrap must set HALOS_CA_AUTO_CREATED=1" || return 1
}

test_ensure_auto_clears_created_flag_on_reuse() {
    local d="$TMPDIR_ROOT/case_adopt_flag_reuse"
    mkdir -p "$d"
    halos_ca_ensure_auto "$d" || return 1
    HALOS_CA_AUTO_CREATED=
    halos_ca_ensure_auto "$d" || return 1
    assert_eq "$HALOS_CA_AUTO_CREATED" "0" "healthy reuse must set HALOS_CA_AUTO_CREATED=0" || return 1
}

test_adoption_init_pending_for_new_ca() {
    local d="$TMPDIR_ROOT/case_adopt_new"
    mkdir -p "$d"
    halos_ca_adoption_init "$d/adoption" "$d/ca.crt" "1" || return 1
    assert_eq "$(cat "$d/adoption")" "pending" "new CA must init pending" || return 1
}

test_adoption_init_adopted_for_legacy_bare_cn() {
    local d="$TMPDIR_ROOT/case_adopt_legacy"
    mkdir -p "$d"
    _mk_ca_with_cn "$d/ca.crt" "HaLOS Device CA" || { echo "fixture failed"; return 1; }
    halos_ca_adoption_init "$d/adoption" "$d/ca.crt" "0" || return 1
    assert_eq "$(cat "$d/adoption")" "adopted" "pre-existing bare-CN CA must init adopted (never orphan)" || return 1
}

test_adoption_init_pending_for_device_cn() {
    local d="$TMPDIR_ROOT/case_adopt_device_cn"
    mkdir -p "$d"
    _mk_ca_with_cn "$d/ca.crt" "HaLOS Device CA (halosdev.local)" || { echo "fixture failed"; return 1; }
    halos_ca_adoption_init "$d/adoption" "$d/ca.crt" "0" || return 1
    assert_eq "$(cat "$d/adoption")" "pending" "pre-existing device-CN CA must init pending" || return 1
}

test_adoption_init_adopted_when_no_auto_ca() {
    # Custom-CA mode: there is no auto-CA to classify, but the sentinel must
    # still exist (the sidecar bind-mounts it). Fail-safe to adopted.
    local d="$TMPDIR_ROOT/case_adopt_no_ca"
    mkdir -p "$d"
    halos_ca_adoption_init "$d/adoption" "$d/ca.crt" "0" || return 1
    assert_eq "$(cat "$d/adoption")" "adopted" "absent auto-CA must init adopted" || return 1
}

test_adoption_init_preserves_existing() {
    # An existing sentinel is load-bearing state; init must never overwrite it,
    # even when told the CA was just created.
    local d="$TMPDIR_ROOT/case_adopt_preserve"
    mkdir -p "$d"
    printf 'adopted' > "$d/adoption"
    local inode_before; inode_before=$(_stat_inode "$d/adoption")
    halos_ca_adoption_init "$d/adoption" "$d/ca.crt" "1" || return 1
    assert_eq "$(cat "$d/adoption")" "adopted" "existing sentinel must be preserved" || return 1
    assert_eq "$(_stat_inode "$d/adoption")" "$inode_before" "preserved sentinel must keep its inode" || return 1
}

test_adoption_init_creates_mode_0644() {
    local d="$TMPDIR_ROOT/case_adopt_mode"
    mkdir -p "$d"
    halos_ca_adoption_init "$d/adoption" "$d/ca.crt" "1" || return 1
    assert_eq "$(_stat_mode "$d/adoption")" "644" "sentinel must be created mode 0644" || return 1
}

test_adoption_init_creates_parent_dir() {
    # Custom-CA mode may run before AUTO_CA_DIR exists; init must create it.
    local d="$TMPDIR_ROOT/case_adopt_mkdir"
    halos_ca_adoption_init "$d/certs/ca/adoption" "$d/certs/ca/ca.crt" "0" || return 1
    [ -f "$d/certs/ca/adoption" ] || { echo "sentinel not created under missing parent"; return 1; }
}

test_is_adopted_pending_returns_false() {
    local d="$TMPDIR_ROOT/case_isadopt_pending"
    mkdir -p "$d"; printf 'pending' > "$d/adoption"
    halos_ca_is_adopted "$d/adoption"; assert_eq "$?" "1" "pending must report not-adopted" || return 1
}

test_is_adopted_adopted_returns_true() {
    local d="$TMPDIR_ROOT/case_isadopt_adopted"
    mkdir -p "$d"; printf 'adopted' > "$d/adoption"
    halos_ca_is_adopted "$d/adoption"; assert_eq "$?" "0" "adopted must report adopted" || return 1
}

test_is_adopted_unrecognized_returns_true() {
    # Fail safe: a corrupt value must read as adopted so a CN refresh can't
    # orphan an installed anchor.
    local d="$TMPDIR_ROOT/case_isadopt_garbage"
    mkdir -p "$d"; printf 'garbage' > "$d/adoption"
    halos_ca_is_adopted "$d/adoption"; assert_eq "$?" "0" "unrecognized must read as adopted" || return 1
}

test_is_adopted_missing_returns_true() {
    local d="$TMPDIR_ROOT/case_isadopt_missing"
    mkdir -p "$d"
    halos_ca_is_adopted "$d/no-such-file"; assert_eq "$?" "0" "missing sentinel must read as adopted" || return 1
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
run_test test_validate_pair_happy_path
run_test test_validate_pair_missing_args
run_test test_validate_pair_missing_files
run_test test_validate_pair_rejects_non_ca_cert
run_test test_validate_pair_rejects_mismatched_key
run_test test_validate_pair_rejects_corrupt_cert
run_test test_validate_pair_rejects_corrupt_key
run_test test_validate_pair_rejects_leaf_with_ca_substrings_in_dn
run_test test_validate_pair_warns_on_short_remaining
run_test test_validate_pair_no_warn_with_ample_remaining
run_test test_validate_pair_rejects_ca_without_keycertsign
run_test test_validate_pair_rejects_short_lived_ca
run_test test_select_active_retightens_custom_dir_mode
run_test test_select_active_partial_custom_key_only_fails_loud
run_test test_select_active_no_custom_uses_auto
run_test test_select_active_valid_custom_takes_precedence
run_test test_select_active_partial_custom_fails_loud
run_test test_select_active_invalid_custom_fails_loud
run_test test_select_active_switch_custom_to_auto
run_test test_select_active_switch_auto_to_custom
run_test test_cockpit_install_leaf_writes_valid_combined_pem
run_test test_cockpit_install_leaf_mode_is_0640
run_test test_cockpit_install_leaf_rejects_mismatched_pair
run_test test_cockpit_install_leaf_preserves_existing_on_failure
run_test test_cockpit_install_leaf_no_new_debris_on_success
run_test test_cockpit_install_leaf_missing_args_errors
run_test test_cockpit_install_leaf_missing_files_errors
run_test test_cockpit_install_leaf_missing_cert_only_isolates_branch
run_test test_cockpit_install_leaf_missing_key_only_isolates_branch
run_test test_cockpit_install_leaf_rejects_malformed_cert
run_test test_cockpit_install_leaf_rejects_malformed_key
run_test test_cockpit_install_leaf_logs_notice_when_group_missing
run_test test_cockpit_install_leaf_rc1_when_chown_fails_with_group_present
run_test test_cockpit_install_leaf_refuses_directory_at_out_path
run_test test_cockpit_install_leaf_no_symlink_follow_on_new
run_test test_cockpit_install_leaf_write_failure_with_missing_parent
run_test test_publish_public_happy_path
run_test test_publish_public_creates_parent_dir
run_test test_publish_public_swap_updates_content
run_test test_publish_public_missing_args_errors
run_test test_publish_public_missing_source_errors
run_test test_publish_public_rejects_non_cert_source
run_test test_publish_public_preserves_existing_on_failure
run_test test_publish_public_refuses_directory_at_output
run_test test_publish_public_no_new_debris_on_success
run_test test_publish_mobileconfig_happy_path
run_test test_publish_mobileconfig_der_round_trips
run_test test_publish_mobileconfig_embeds_display_host
run_test test_publish_mobileconfig_is_deterministic
run_test test_publish_mobileconfig_missing_args_errors
run_test test_publish_mobileconfig_missing_source_errors
run_test test_publish_mobileconfig_rejects_non_cert_source
run_test test_publish_mobileconfig_uuid_is_per_ca
run_test test_publish_mobileconfig_refuses_directory_at_output
run_test test_publish_mobileconfig_no_new_debris_on_success
run_test test_publish_mobileconfig_preserves_existing_on_failure
run_test test_sign_leaf_validity_under_apple_825_day_cap
run_test test_leaf_needs_renewal_when_fresh_returns_false
run_test test_leaf_needs_renewal_when_missing_returns_true
run_test test_leaf_needs_renewal_when_approaching_expiry_returns_true
run_test test_leaf_needs_renewal_when_well_outside_window_returns_false
run_test test_leaf_needs_renewal_when_already_expired_returns_true
run_test test_sign_leaf_default_validity_uses_apple_compliant_days
run_test test_ensure_auto_sets_created_flag_on_bootstrap
run_test test_ensure_auto_clears_created_flag_on_reuse
run_test test_adoption_init_pending_for_new_ca
run_test test_adoption_init_adopted_for_legacy_bare_cn
run_test test_adoption_init_pending_for_device_cn
run_test test_adoption_init_adopted_when_no_auto_ca
run_test test_adoption_init_preserves_existing
run_test test_adoption_init_creates_mode_0644
run_test test_adoption_init_creates_parent_dir
run_test test_is_adopted_pending_returns_false
run_test test_is_adopted_adopted_returns_true
run_test test_is_adopted_unrecognized_returns_true
run_test test_is_adopted_missing_returns_true

echo
echo "Passed: $PASSES, Failed: $FAILS"
[ "$FAILS" -eq 0 ]
