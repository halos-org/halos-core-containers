#!/usr/bin/env bash
# Docker-free unit tests for the ca-download CGI scripts
# (assets/ca-download/www/{ca/halos-ca.crt,ca/halos-ca.mobileconfig,halos-ca.crt}).
#
# Each CGI is invoked directly with the busybox-httpd CGI contract (REQUEST_METHOD
# env, headers/blank-line/body on stdout) and the cert/profile/sentinel paths
# pointed at a scratch dir via the HALOS_* env seam. This exercises the adoption
# logic — flip on completed GET, no flip on HEAD / torn download / wrong method —
# without Docker, so it runs in CI. The full served URL layout (status codes,
# native /ca redirect, routing) is covered by the Docker-gated
# test-ca-download-endpoint.sh.
#
# Run from repo root:  bash tests/test-ca-download-cgi.sh

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CERT_CGI="$REPO_ROOT/assets/ca-download/www/ca/halos-ca.crt"
PROFILE_CGI="$REPO_ROOT/assets/ca-download/www/ca/halos-ca.mobileconfig"
GONE_CGI="$REPO_ROOT/assets/ca-download/www/halos-ca.crt"

for f in "$CERT_CGI" "$PROFILE_CGI" "$GONE_CGI"; do
    [ -f "$f" ] || { echo "missing fixture: $f" >&2; exit 2; }
done

PASSES=0
FAILS=0
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'; else GREEN=""; RED=""; RESET=""; fi

assert_eq() {
    if [ "$1" = "$2" ]; then return 0; fi
    printf '%s    actual:   %q\n    expected: %q\n' "$3" "$1" "$2" >&2
    return 1
}

run_test() {
    local name="$1" out
    if out=$("$name" 2>&1); then
        PASSES=$((PASSES + 1)); printf '%sPASS%s %s\n' "$GREEN" "$RESET" "$name"
    else
        FAILS=$((FAILS + 1)); printf '%sFAIL%s %s\n%s\n' "$RED" "$RESET" "$name" "$out"
    fi
}

_stat_inode() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }

# Build a scratch /srv + sentinel for one case. $1 = cert byte count.
new_scratch() {
    local d="$TMPDIR_ROOT/$1"
    mkdir -p "$d"
    # A realistic-ish cert blob; size is a parameter so the torn-download test
    # can make the body exceed the pipe buffer.
    local bytes="${2:-2048}"
    { printf -- '-----BEGIN CERTIFICATE-----\n'; head -c "$bytes" /dev/zero | tr '\0' 'A'; printf '\n-----END CERTIFICATE-----\n'; } > "$d/halos-ca.crt"
    printf '<?xml version="1.0"?><plist>PROFILE</plist>\n' > "$d/halos-ca.mobileconfig"
    printf 'pending' > "$d/adoption"
    # The cert-manager publishes the device download name here; default generic.
    printf 'halos-ca.crt' > "$d/download-filename"
    printf '%s' "$d"
}

# Invoke a CGI with the scratch paths wired in. Usage:
#   invoke <cgi> <scratch> <method>
invoke() {
    HALOS_CA_PUBLIC_CRT="$2/halos-ca.crt" \
    HALOS_CA_PUBLIC_PROFILE="$2/halos-ca.mobileconfig" \
    HALOS_ADOPTION_FILE="$2/adoption" \
    HALOS_CA_DOWNLOAD_NAME="$2/download-filename" \
    REQUEST_METHOD="$3" \
    sh "$1"
}

# Pull a single header value (case-insensitive) from CGI output.
cgi_hdr() { printf '%s\n' "$1" | awk -v h="$2" 'BEGIN{IGNORECASE=1} tolower($1)==tolower(h)":"{ $1=""; sub(/^ /,""); print; exit }'; }
cgi_status() { printf '%s\n' "$1" | awk 'tolower($1)=="status:"{ $1=""; sub(/^ /,""); print; exit }'; }

# --- cert CGI --------------------------------------------------------------

test_cert_get_serves_and_adopts() {
    local d; d=$(new_scratch cert_get)
    local out; out=$(invoke "$CERT_CGI" "$d" GET)
    assert_eq "$(cgi_status "$out")" "200 OK" "GET status" || return 1
    assert_eq "$(cgi_hdr "$out" Content-Type)" "application/x-x509-ca-cert" "content-type" || return 1
    assert_eq "$(cgi_hdr "$out" Content-Disposition)" 'attachment; filename="halos-ca.crt"' "disposition" || return 1
    case "$out" in *"BEGIN CERTIFICATE"*) ;; *) echo "body missing cert"; return 1 ;; esac
    assert_eq "$(cat "$d/adoption")" "adopted" "completed GET must adopt" || return 1
}

test_cert_filename_from_name_file_is_device_specific() {
    # The saved filename comes from the cert-manager-published name file (derived
    # from the CA's CN), so it names the cert's identity, not how the page was
    # reached. (The CN-to-name derivation itself is tested in test-lib-ca.sh.)
    local d; d=$(new_scratch cert_namefile)
    printf 'halos-ca-halosdev.local.crt' > "$d/download-filename"
    local out; out=$(invoke "$CERT_CGI" "$d" GET)
    assert_eq "$(cgi_hdr "$out" Content-Disposition)" 'attachment; filename="halos-ca-halosdev.local.crt"' "device-specific filename from name file" || return 1
}

test_cert_filename_default_when_name_file_absent() {
    local d; d=$(new_scratch cert_no_namefile)
    rm -f "$d/download-filename"
    local out; out=$(invoke "$CERT_CGI" "$d" GET)
    assert_eq "$(cgi_hdr "$out" Content-Disposition)" 'attachment; filename="halos-ca.crt"' "generic name when file absent" || return 1
}

test_cert_filename_rejects_unsafe_name_file() {
    # A name file with anything outside the expected halos-ca[-<safe>].crt shape
    # (e.g. tampering, header-breaking chars) falls back to the generic name —
    # no quote-breakout or header injection from the file contents.
    local d; d=$(new_scratch cert_bad_namefile)
    printf 'evil" \r\nSet-Cookie: x.crt' > "$d/download-filename"
    local out; out=$(invoke "$CERT_CGI" "$d" GET)
    assert_eq "$(cgi_hdr "$out" Content-Disposition)" 'attachment; filename="halos-ca.crt"' "unsafe name file rejected" || return 1
    local cd_lines; cd_lines=$(printf '%s\n' "$out" | grep -ci '^Content-Disposition:')
    assert_eq "$cd_lines" "1" "exactly one Content-Disposition line" || return 1
    if printf '%s\n' "$out" | grep -qi '^Set-Cookie:'; then echo "name file injected a header"; return 1; fi
}

test_cert_filename_rejects_empty_device_part() {
    # A name with no device part after the prefix (halos-ca-.crt) — which the
    # cert-manager never produces — must fall back to the generic name.
    local d; d=$(new_scratch cert_empty_dev)
    printf 'halos-ca-.crt' > "$d/download-filename"
    local out; out=$(invoke "$CERT_CGI" "$d" GET)
    assert_eq "$(cgi_hdr "$out" Content-Disposition)" 'attachment; filename="halos-ca.crt"' "empty device part rejected" || return 1
}

test_cert_head_uses_device_filename() {
    # HEAD shares emit_headers (the landing page reads the name via HEAD), so it
    # must carry the same device-specific name.
    local d; d=$(new_scratch cert_head_name)
    printf 'halos-ca-halosdev.local.crt' > "$d/download-filename"
    local out; out=$(invoke "$CERT_CGI" "$d" HEAD)
    assert_eq "$(cgi_hdr "$out" Content-Disposition)" 'attachment; filename="halos-ca-halosdev.local.crt"' "HEAD device filename" || return 1
}

test_cert_get_adopt_is_in_place() {
    # The flip must truncate-rewrite the same inode (single-file bind mount is
    # inode-pinned at container start; a tmp+mv would desync it).
    local d; d=$(new_scratch cert_inode)
    local inode_before; inode_before=$(_stat_inode "$d/adoption")
    invoke "$CERT_CGI" "$d" GET >/dev/null
    assert_eq "$(cat "$d/adoption")" "adopted" "GET must adopt" || return 1
    assert_eq "$(_stat_inode "$d/adoption")" "$inode_before" "adoption flip must preserve inode" || return 1
}

test_cert_head_serves_headers_without_adopting() {
    local d; d=$(new_scratch cert_head)
    local out; out=$(invoke "$CERT_CGI" "$d" HEAD)
    assert_eq "$(cgi_status "$out")" "200 OK" "HEAD status" || return 1
    case "$out" in *"BEGIN CERTIFICATE"*) echo "HEAD must not emit a body"; return 1 ;; esac
    assert_eq "$(cat "$d/adoption")" "pending" "HEAD must not adopt" || return 1
}

test_cert_post_rejected_without_adopting() {
    local d; d=$(new_scratch cert_post)
    local out; out=$(invoke "$CERT_CGI" "$d" POST)
    assert_eq "$(cgi_status "$out")" "405 Method Not Allowed" "POST status" || return 1
    assert_eq "$(cgi_hdr "$out" Allow)" "GET, HEAD" "Allow header" || return 1
    assert_eq "$(cat "$d/adoption")" "pending" "POST must not adopt" || return 1
}

test_cert_torn_download_does_not_adopt() {
    # A disconnect mid-body breaks the stdout pipe; cat dies (SIGPIPE) before
    # the flip. Body is sized past the pipe buffer and the reader closes after a
    # few hundred bytes, so the disconnect lands inside the body stream. NB this
    # proves the large-payload path only: under busybox httpd a payload that
    # fits one socket buffer (every real cert) is flushed before any disconnect
    # is observable, so it adopts on serve — which is safe (see the CGI header).
    local d; d=$(new_scratch cert_torn 262144)
    invoke "$CERT_CGI" "$d" GET | head -c 256 >/dev/null
    assert_eq "$(cat "$d/adoption")" "pending" "torn download must not adopt" || return 1
}

test_cert_missing_source_returns_503_without_adopting() {
    local d; d=$(new_scratch cert_missing)
    rm -f "$d/halos-ca.crt"
    local out; out=$(invoke "$CERT_CGI" "$d" GET)
    assert_eq "$(cgi_status "$out")" "503 Service Unavailable" "missing cert status" || return 1
    assert_eq "$(cat "$d/adoption")" "pending" "503 must not adopt" || return 1
}

test_cert_second_download_is_idempotent() {
    local d; d=$(new_scratch cert_twice)
    invoke "$CERT_CGI" "$d" GET >/dev/null
    invoke "$CERT_CGI" "$d" GET >/dev/null
    assert_eq "$(cat "$d/adoption")" "adopted" "second download stays adopted" || return 1
}

# --- profile CGI -----------------------------------------------------------

test_profile_get_inline_and_adopts() {
    local d; d=$(new_scratch profile_get)
    local out; out=$(invoke "$PROFILE_CGI" "$d" GET)
    assert_eq "$(cgi_status "$out")" "200 OK" "GET status" || return 1
    assert_eq "$(cgi_hdr "$out" Content-Type)" "application/x-apple-aspen-config" "aspen content-type" || return 1
    # #169: an attachment disposition routes the profile to the iOS Files app and
    # the installer never fires. It must be served inline.
    assert_eq "$(cgi_hdr "$out" Content-Disposition)" "" "profile must NOT carry attachment disposition (#169)" || return 1
    assert_eq "$(cat "$d/adoption")" "adopted" "completed profile GET must adopt" || return 1
}

# --- 410 CGI ---------------------------------------------------------------

test_gone_returns_410_with_canonical_hint() {
    local out; out=$(REQUEST_METHOD=GET sh "$GONE_CGI")
    assert_eq "$(cgi_status "$out")" "410 Gone" "410 status" || return 1
    case "$(cgi_hdr "$out" Link)" in *"/ca/halos-ca.crt"*) ;; *) echo "missing canonical Link"; return 1 ;; esac
}

run_test test_cert_get_serves_and_adopts
run_test test_cert_filename_from_name_file_is_device_specific
run_test test_cert_filename_default_when_name_file_absent
run_test test_cert_filename_rejects_unsafe_name_file
run_test test_cert_filename_rejects_empty_device_part
run_test test_cert_head_uses_device_filename
run_test test_cert_get_adopt_is_in_place
run_test test_cert_head_serves_headers_without_adopting
run_test test_cert_post_rejected_without_adopting
run_test test_cert_torn_download_does_not_adopt
run_test test_cert_missing_source_returns_503_without_adopting
run_test test_cert_second_download_is_idempotent
run_test test_profile_get_inline_and_adopts
run_test test_gone_returns_410_with_canonical_hint

echo
echo "Passed: $PASSES, Failed: $FAILS"
[ "$FAILS" -eq 0 ]
