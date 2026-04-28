#!/usr/bin/env bash
# Tests for assets/lib-hostnames.sh
#
# Run from repo root:
#   bash tests/test-lib-hostnames.sh
#
# Each test is a function prefixed with `test_`. Failures print a diagnostic
# and bump FAILS; the script exits non-zero if any test failed.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/assets/lib-hostnames.sh"

if [ ! -f "$LIB" ]; then
    echo "lib-hostnames.sh not found at $LIB" >&2
    exit 2
fi

PASSES=0
FAILS=0
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Colors only when stdout is a TTY.
if [ -t 1 ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; RESET=""
fi

# Reload the lib in a fresh subshell context (so test isolation is real).
# Each test function runs in this script process, but we reset state explicitly.
_reset_state() {
    HALOS_HOSTNAMES_FILE="$1"
    unset HALOS_HOSTNAMES_DNS HALOS_HOSTNAMES_IPS
    unset HALOS_HOSTNAMES_CANONICAL HALOS_HOSTNAMES_FALLBACK
    unset HALOS_HOSTNAMES_FALLBACK_REASON
    # shellcheck source=/dev/null
    . "$LIB"
}

# assert_eq <actual> <expected> <msg>
assert_eq() {
    if [ "$1" = "$2" ]; then
        return 0
    fi
    printf '%s    actual:   %q\n    expected: %q\n' "$3" "$1" "$2" >&2
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

# Helper to fabricate a hostnames.conf
write_conf() {
    local path="$1"; shift
    printf '%s\n' "$@" > "$path"
}

# ---------------------------------------------------------------------------

test_happy_path_dns_and_ip() {
    local f="$TMPDIR_ROOT/happy.conf"
    write_conf "$f" "halosdev.local" "halosdev.example.com" "10.0.0.50"
    _reset_state "$f"
    halos_load_hostnames

    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "fallback should not fire on happy path"
    assert_eq "$(halos_canonical_hostname)" "halosdev.local" "canonical wrong"
    assert_eq "$(halos_dns_hostnames | tr '\n' ',')" "halosdev.local,halosdev.example.com," "DNS list wrong"
    assert_eq "$(halos_all_hostnames | tr '\n' ',')" "halosdev.local,halosdev.example.com,10.0.0.50," "all-list wrong"
}

test_comments_and_blank_lines_ignored() {
    local f="$TMPDIR_ROOT/comments.conf"
    {
        echo "# heading"
        echo ""
        echo "halosdev.local"
        echo "  # indented comment"
        echo ""
        echo "halosdev.example.com"
    } > "$f"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "should parse cleanly"
    assert_eq "$(halos_dns_hostnames | wc -l | tr -d ' ')" "2" "expected 2 DNS entries"
}

test_missing_file_fallback() {
    _reset_state "$TMPDIR_ROOT/does-not-exist.conf"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "fallback should fire on missing file"
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$(halos_canonical_hostname)" "${short}.local" "fallback canonical wrong"
}

test_empty_file_fallback() {
    local f="$TMPDIR_ROOT/empty.conf"
    : > "$f"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "fallback should fire on empty file"
}

test_only_ips_fallback() {
    local f="$TMPDIR_ROOT/onlyips.conf"
    write_conf "$f" "10.0.0.1" "10.0.0.2"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "fallback should fire when no DNS entries"
}

test_cap_exceeded_fallback() {
    local f="$TMPDIR_ROOT/cap.conf"
    : > "$f"
    local i
    for i in $(seq 1 17); do
        echo "h${i}.example.com" >> "$f"
    done
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "fallback should fire when cap exceeded"
}

test_invalid_entries_fallback() {
    # NB: bare single labels like "myhost" are now valid (regex relaxation
    # for SOHO router DHCP+DNS integrations and single-label DHCP domains).
    local cases=(
        "foo..bar.com"
        "*.foo.com"
        ".foo.com"
        "host with space"
    )
    local case
    for case in "${cases[@]}"; do
        local f="$TMPDIR_ROOT/inv.conf"
        printf '%s\n' "$case" > "$f"
        _reset_state "$f"
        halos_load_hostnames
        if [ "$HALOS_HOSTNAMES_FALLBACK" != "1" ]; then
            echo "expected fallback for invalid entry: $case" >&2
            return 1
        fi
    done
}

test_dangerous_chars_rejected() {
    local f="$TMPDIR_ROOT/dangerous.conf"
    printf '%s\n' 'foo`whoami`.example.com' > "$f"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "backtick must trigger fallback"
}

test_unreadable_file_fallback() {
    local f="$TMPDIR_ROOT/unreadable.conf"
    write_conf "$f" "halosdev.local"
    chmod 0000 "$f"
    _reset_state "$f"
    halos_load_hostnames
    local fb="$HALOS_HOSTNAMES_FALLBACK"
    chmod 0644 "$f"
    # Skip when running as root (can read mode-0000 files).
    if [ "$(id -u)" = "0" ]; then
        return 0
    fi
    assert_eq "$fb" "1" "fallback should fire on unreadable file"
}

test_hostname_token_expansion() {
    local f="$TMPDIR_ROOT/expand.conf"
    write_conf "$f" '${hostname}.local' 'vpn.${hostname}.example.com'
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "expansion should produce valid entries"
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$(halos_canonical_hostname)" "${short}.local" "canonical should be expanded"
    local list; list="$(halos_dns_hostnames | tr '\n' ',')"
    assert_eq "$list" "${short}.local,vpn.${short}.example.com," "expanded list wrong"
}

# Resolver injection helpers (Unit 1).
_resolver_example_com() { printf 'example.com'; }
_resolver_empty() { printf ''; }
_resolver_with_whitespace() { printf '  example.com  \n'; }
_resolver_hal() { printf 'hal'; }
_resolver_local() { printf 'local'; }
_resolver_with_dollar() { printf 'evil$bad.example.com'; }
_resolver_with_backtick() { printf 'evil`id`.example.com'; }
_resolver_counting() { echo >> "${_RESOLVER_COUNT_FILE:-/dev/null}"; printf 'example.com'; }

test_resolver_injection_returns_value() {
    local f="$TMPDIR_ROOT/r1.conf"
    write_conf "$f" "halosdev.local"
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_example_com
    halos_load_hostnames
    local d; d="$(_halos_resolve_domain)"
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$d" "example.com" "resolver should return injected value"
}

test_resolver_injection_empty() {
    local f="$TMPDIR_ROOT/r2.conf"
    write_conf "$f" "halosdev.local"
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_empty
    halos_load_hostnames
    local d; d="$(_halos_resolve_domain)"
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$d" "" "resolver returning empty should yield empty domain"
}

test_resolver_trims_whitespace() {
    local f="$TMPDIR_ROOT/r3.conf"
    write_conf "$f" "halosdev.local"
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_with_whitespace
    halos_load_hostnames
    local d; d="$(_halos_resolve_domain)"
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$d" "example.com" "resolver output should be trimmed"
}

test_resolver_non_existent_function_falls_through() {
    # HALOS_DOMAIN_RESOLVER set to an undefined name must NOT short-circuit
    # the real resolver chain — defense against stray env-var leak in prod.
    local f="$TMPDIR_ROOT/r-fall.conf"
    write_conf "$f" "halosdev.local"
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=does_not_exist_anywhere
    halos_load_hostnames
    local d; d="$(_halos_resolve_domain)"
    unset HALOS_DOMAIN_RESOLVER
    # The real `hostname -d` may or may not return a value on the test host —
    # the assertion is that the chain proceeds, not that it returns any
    # specific value. Easiest signal: the cache was set (some value, possibly
    # empty), and the load completed without erroring.
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "load should not fall back from a stray env var alone"
}

test_resolver_cache_prevents_repeated_calls() {
    # Multiple ${fqdn}/${domain} lines in one load should call the resolver
    # exactly once thanks to HALOS_HOSTNAMES_DOMAIN_CACHE being primed in
    # the parent process at load start. (Counter via file because
    # _halos_resolve_domain invokes the resolver in a command substitution
    # subshell, so shell-variable counters don't propagate.)
    local f="$TMPDIR_ROOT/r-count.conf"
    local counter="$TMPDIR_ROOT/r-count.tally"
    : > "$counter"
    write_conf "$f" '${fqdn}' '${domain}' '${hostname}.${domain}'
    _reset_state "$f"
    _RESOLVER_COUNT_FILE="$counter"
    HALOS_DOMAIN_RESOLVER=_resolver_counting
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER _RESOLVER_COUNT_FILE
    local n; n="$(wc -l < "$counter" | tr -d ' ')"
    assert_eq "$n" "1" "resolver should be called exactly once per load"
}

test_resolver_dangerous_chars_passed_through_caught_by_validation() {
    # An injected resolver returning shell metacharacters must result in the
    # expanded entries being rejected by _halos_has_dangerous_chars (hard
    # fallback), not silently slipping into cert SANs.
    local f="$TMPDIR_ROOT/r-evil.conf"
    write_conf "$f" '${fqdn}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_with_dollar
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "dollar-sign in resolver output must trigger hard fallback"

    write_conf "$f" '${fqdn}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_with_backtick
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "backtick in resolver output must trigger hard fallback"
}

test_resolver_cache_clears_on_reload() {
    local f="$TMPDIR_ROOT/r4.conf"
    write_conf "$f" "halosdev.local"

    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_example_com
    halos_load_hostnames
    local d1; d1="$(_halos_resolve_domain)"

    # Re-load with a different injected resolver — cache must clear.
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_hal
    halos_load_hostnames
    local d2; d2="$(_halos_resolve_domain)"
    unset HALOS_DOMAIN_RESOLVER

    assert_eq "$d1" "example.com" "first load should see first resolver"
    assert_eq "$d2" "hal" "second load should see new resolver after cache reset"
}

# Unit 2: regex relaxation, ${fqdn}/${domain} expansion, soft-drop -----------

test_single_label_literal_accepted() {
    local f="$TMPDIR_ROOT/sl1.conf"
    write_conf "$f" "halosdev"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "single-label literal should be valid"
    assert_eq "$(halos_canonical_hostname)" "halosdev" "canonical should be the single label"
}

test_single_label_hostname_token_accepted() {
    local f="$TMPDIR_ROOT/sl2.conf"
    write_conf "$f" '${hostname}'
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "bare \${hostname} should be valid under relaxed regex"
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$(halos_canonical_hostname)" "$short" "canonical should be the short hostname"
}

test_fqdn_token_with_resolver() {
    local f="$TMPDIR_ROOT/fqdn1.conf"
    write_conf "$f" '${fqdn}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_example_com
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "fqdn with resolver should expand cleanly"
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$(halos_canonical_hostname)" "${short}.example.com" "fqdn should be <short>.example.com"
}

test_hostname_dot_domain_equivalent_to_fqdn() {
    local f="$TMPDIR_ROOT/hd.conf"
    write_conf "$f" '${hostname}.${domain}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_example_com
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$(halos_canonical_hostname)" "${short}.example.com" "\${hostname}.\${domain} should match \${fqdn}"
}

test_bare_domain_with_resolver_multilabel() {
    local f="$TMPDIR_ROOT/bd1.conf"
    write_conf "$f" '${domain}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_example_com
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "bare \${domain} multi-label should be valid"
    assert_eq "$(halos_canonical_hostname)" "example.com" "canonical should be the resolved domain"
}

test_bare_domain_with_resolver_single_label() {
    local f="$TMPDIR_ROOT/bd2.conf"
    write_conf "$f" '${domain}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_hal
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "single-label \${domain} should be valid under relaxed regex"
    assert_eq "$(halos_canonical_hostname)" "hal" "canonical should be the single-label domain"
}

test_soft_drop_fqdn_with_other_valid_entries() {
    local f="$TMPDIR_ROOT/sd1.conf"
    local err="$TMPDIR_ROOT/sd1.err"
    write_conf "$f" '${hostname}.local' '${fqdn}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_empty
    halos_load_hostnames 2>"$err"
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "soft-drop must not trigger fallback when others valid"
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$(halos_canonical_hostname)" "${short}.local" "canonical should remain mDNS entry"
    assert_eq "$(halos_dns_hostnames | wc -l | tr -d ' ')" "1" "expected 1 surviving DNS entry"
    if ! grep -q HALOS_HOSTNAMES_SKIP "$err"; then
        echo "expected HALOS_HOSTNAMES_SKIP diagnostic; got:" >&2
        cat "$err" >&2
        return 1
    fi
    # The diagnostic must include the offending line so admins can grep it.
    if ! grep -F 'dropping line: ${fqdn}' "$err" >/dev/null; then
        echo "expected SKIP diagnostic to name the dropped line; got:" >&2
        cat "$err" >&2
        return 1
    fi
}

test_shipped_default_with_single_label_dhcp_domain() {
    # Real-world halosdev.local with DHCP option 15 = 'hal'. Mirrors the
    # shipped /etc/halos/hostnames.conf default (mDNS + ${fqdn}).
    local f="$TMPDIR_ROOT/shipped.conf"
    write_conf "$f" '${hostname}.local' '${fqdn}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_hal
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "shipped default + single-label resolver should parse cleanly"
    assert_eq "$(halos_canonical_hostname)" "${short}.local" "canonical = mDNS"
    assert_eq "$(halos_dns_hostnames | tr '\n' ',')" "${short}.local,${short}.hal," "DNS list should be mDNS + fqdn"
}

test_soft_drop_only_fqdn_falls_back() {
    local f="$TMPDIR_ROOT/sd2.conf"
    write_conf "$f" '${fqdn}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_empty
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "all-soft-dropped file should fall back to default"
}

test_soft_drop_bare_domain_empty_resolver() {
    local f="$TMPDIR_ROOT/sd3.conf"
    write_conf "$f" '${hostname}.local' '${domain}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_empty
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "soft-drop of bare \${domain} should not trigger fallback"
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$(halos_dns_hostnames | tr '\n' ',')" "${short}.local," "only the mDNS entry should survive"
}

test_admin_typo_with_fqdn_neighbor_hard_fails() {
    # An admin-typed invalid line must still trigger hard fallback
    # regardless of whether ${fqdn} on another line soft-drops.
    local f="$TMPDIR_ROOT/typo.conf"
    write_conf "$f" '${fqdn}' "bad..name"
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_empty
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "admin typo must hard-fail even with fqdn neighbor"
}

test_full_default_layout_with_resolver() {
    # Loader API coverage for a mixed token+literal+IP config including a
    # bare ${hostname} entry. The actually-shipped default is mDNS + ${fqdn}
    # only — see test_shipped_default_with_single_label_dhcp_domain. Bare
    # ${hostname} stays tested here because it remains a valid admin opt-in,
    # filtered downstream by prestart.sh's Authelia cookie loop.
    local f="$TMPDIR_ROOT/full.conf"
    write_conf "$f" '${hostname}.local' '${hostname}' '${fqdn}' "10.0.0.50"
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_example_com
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "full default should parse cleanly"
    assert_eq "$(halos_canonical_hostname)" "${short}.local" "canonical = mDNS"
    assert_eq "$(halos_dns_hostnames | tr '\n' ',')" "${short}.local,${short},${short}.example.com," "DNS list wrong"
    assert_eq "$(halos_all_hostnames | tail -1)" "10.0.0.50" "IP should be present"
}

test_dedup_dns_entries_case_insensitive() {
    # Admin lists halosdev.local literally and ${fqdn} resolves to the same
    # value (DHCP option 15 = 'local' on a SOHO router). The loader must
    # collapse the duplicate so cert SANs and Authelia cookies don't carry
    # repeated entries (Authelia 4.39+ rejects duplicate cookie domains).
    local f="$TMPDIR_ROOT/dedup1.conf"
    write_conf "$f" "halosdev.local" "HALOSDEV.local" '${fqdn}'
    _reset_state "$f"
    HALOS_DOMAIN_RESOLVER=_resolver_local
    halos_load_hostnames
    unset HALOS_DOMAIN_RESOLVER
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "0" "dedup should not trigger fallback"
    assert_eq "$(halos_dns_hostnames | wc -l | tr -d ' ')" "1" "duplicates must collapse to one"
    assert_eq "$(halos_canonical_hostname)" "halosdev.local" "first occurrence preserved"
}

test_dedup_ip_entries() {
    local f="$TMPDIR_ROOT/dedup2.conf"
    write_conf "$f" "halosdev.local" "10.0.0.50" "10.0.0.50"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$(halos_all_hostnames | grep -c '^10\.0\.0\.50$' | tr -d ' ')" "1" "duplicate IP must collapse"
}

test_hash_stable_across_reorderings() {
    local fa="$TMPDIR_ROOT/order-a.conf"
    local fb="$TMPDIR_ROOT/order-b.conf"
    write_conf "$fa" "halosdev.local" "halosdev.example.com" "10.0.0.50"
    write_conf "$fb" "10.0.0.50" "halosdev.example.com" "halosdev.local"

    _reset_state "$fa"; halos_load_hostnames
    local ha; ha="$(halos_hostnames_hash)"
    _reset_state "$fb"; halos_load_hostnames
    local hb; hb="$(halos_hostnames_hash)"

    assert_eq "$ha" "$hb" "hash must be order-invariant"
    # 64 hex chars
    if ! [[ "$ha" =~ ^[0-9a-f]{64}$ ]]; then
        echo "hash format wrong: $ha" >&2
        return 1
    fi
}

test_hash_default_state_consistent() {
    local missing="$TMPDIR_ROOT/no-such.conf"
    local single="$TMPDIR_ROOT/single.conf"
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    write_conf "$single" "${short}.local"

    _reset_state "$missing"; halos_load_hostnames
    local h_missing; h_missing="$(halos_hostnames_hash)"

    _reset_state "$single"; halos_load_hostnames
    local h_single; h_single="$(halos_hostnames_hash)"

    assert_eq "$h_missing" "$h_single" "missing-file hash must match single-default-entry hash"
}

test_hash_changes_on_membership_change() {
    local f1="$TMPDIR_ROOT/m1.conf"
    local f2="$TMPDIR_ROOT/m2.conf"
    write_conf "$f1" "halosdev.local"
    write_conf "$f2" "halosdev.local" "halosdev.example.com"
    _reset_state "$f1"; halos_load_hostnames
    local h1; h1="$(halos_hostnames_hash)"
    _reset_state "$f2"; halos_load_hostnames
    local h2; h2="$(halos_hostnames_hash)"
    if [ "$h1" = "$h2" ]; then
        echo "hash should change when membership changes ($h1)" >&2
        return 1
    fi
}

test_invalid_ipv4_octet_rejected() {
    local f="$TMPDIR_ROOT/badip.conf"
    write_conf "$f" "halosdev.local" "10.0.0.999"
    _reset_state "$f"
    halos_load_hostnames
    assert_eq "$HALOS_HOSTNAMES_FALLBACK" "1" "invalid IPv4 octet must trigger fallback"
}

test_expand_redirect_uri_no_placeholder() {
    local f="$TMPDIR_ROOT/exp1.conf"
    write_conf "$f" "halosdev.local" "halosdev.example.com"
    _reset_state "$f"
    halos_load_hostnames
    local out
    out=$(halos_expand_oidc_redirect_uri "https://literal.example.com/cb")
    assert_eq "$out" "https://literal.example.com/cb" "non-placeholder URI should pass through unchanged"
}

test_expand_redirect_uri_placeholder_per_dns() {
    local f="$TMPDIR_ROOT/exp2.conf"
    write_conf "$f" "halosdev.local" "halosdev.example.com" "10.0.0.50"
    _reset_state "$f"
    halos_load_hostnames
    local out; out=$(halos_expand_oidc_redirect_uri 'https://${HALOS_DOMAIN}/api/auth/callback' | tr '\n' ',')
    assert_eq "$out" "https://halosdev.local/api/auth/callback,https://halosdev.example.com/api/auth/callback," "placeholder must expand per DNS hostname (IPs excluded)"
}

test_expand_redirect_uri_subdomain_placeholder() {
    local f="$TMPDIR_ROOT/exp3.conf"
    write_conf "$f" "halosdev.local" "halosdev.example.com"
    _reset_state "$f"
    halos_load_hostnames
    local out; out=$(halos_expand_oidc_redirect_uri 'https://auth.${HALOS_DOMAIN}/cb' | tr '\n' ',')
    assert_eq "$out" "https://auth.halosdev.local/cb,https://auth.halosdev.example.com/cb," "subdomain placeholder must expand"
}

test_expand_redirect_uri_default_fallback() {
    _reset_state "$TMPDIR_ROOT/missing.conf"
    halos_load_hostnames
    local short; short="$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"
    local out; out=$(halos_expand_oidc_redirect_uri 'https://${HALOS_DOMAIN}/cb' | tr '\n' ',')
    assert_eq "$out" "https://${short}.local/cb," "fallback should expand to single canonical URI"
}

# ---------------------------------------------------------------------------

run_test test_happy_path_dns_and_ip
run_test test_comments_and_blank_lines_ignored
run_test test_missing_file_fallback
run_test test_empty_file_fallback
run_test test_only_ips_fallback
run_test test_cap_exceeded_fallback
run_test test_invalid_entries_fallback
run_test test_dangerous_chars_rejected
run_test test_unreadable_file_fallback
run_test test_hostname_token_expansion
run_test test_resolver_injection_returns_value
run_test test_resolver_injection_empty
run_test test_resolver_trims_whitespace
run_test test_resolver_cache_clears_on_reload
run_test test_resolver_non_existent_function_falls_through
run_test test_resolver_cache_prevents_repeated_calls
run_test test_resolver_dangerous_chars_passed_through_caught_by_validation
run_test test_single_label_literal_accepted
run_test test_single_label_hostname_token_accepted
run_test test_fqdn_token_with_resolver
run_test test_hostname_dot_domain_equivalent_to_fqdn
run_test test_bare_domain_with_resolver_multilabel
run_test test_bare_domain_with_resolver_single_label
run_test test_soft_drop_fqdn_with_other_valid_entries
run_test test_soft_drop_only_fqdn_falls_back
run_test test_soft_drop_bare_domain_empty_resolver
run_test test_admin_typo_with_fqdn_neighbor_hard_fails
run_test test_full_default_layout_with_resolver
run_test test_shipped_default_with_single_label_dhcp_domain
run_test test_dedup_dns_entries_case_insensitive
run_test test_dedup_ip_entries
run_test test_hash_stable_across_reorderings
run_test test_hash_default_state_consistent
run_test test_hash_changes_on_membership_change
run_test test_invalid_ipv4_octet_rejected
run_test test_expand_redirect_uri_no_placeholder
run_test test_expand_redirect_uri_placeholder_per_dns
run_test test_expand_redirect_uri_subdomain_placeholder
run_test test_expand_redirect_uri_default_fallback

echo ""
echo "Passed: $PASSES   Failed: $FAILS"
[ "$FAILS" -eq 0 ]
