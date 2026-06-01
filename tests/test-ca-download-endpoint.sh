#!/usr/bin/env bash
# Integration tests for the ca-download sidecar (busybox httpd + CGI).
#
# Spins up the real httpd.conf + docroot (assets/ca-download/www) in a throwaway
# busybox container with a dummy published CA + profile and a "pending" adoption
# sentinel bind-mounted as a single file, then asserts the served URL layout and
# the end-to-end adoption flip:
#   /ca/halos-ca.crt          → 200, x-x509-ca-cert, attachment; flips sentinel
#   /ca/halos-ca.mobileconfig → 200, aspen, NO attachment (#169); flips sentinel
#   /ca                       → 302 /ca/ (busybox-native, relative Location)
#   /ca/                      → 200, text/html landing page
#   /halos-ca.crt             → 410 + canonical Link hint
#   /healthz                  → 200 (liveness), never touches the sentinel
#   HEAD/POST                 → no adoption; POST rejected 405
#
# The container writes the sentinel in place as the dropped uid; the host then
# reads the flipped value, proving host↔container inode coherence.
#
# Requires Docker. Skips cleanly (exit 0) where Docker is unavailable so the
# pure-bash suite still passes in minimal CI; the skip is logged, not silent.
# The CGI adoption logic also has Docker-free coverage in test-ca-download-cgi.sh.
#
# Run from repo root:  bash tests/test-ca-download-endpoint.sh

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HTTPD_CONF="$REPO_ROOT/assets/ca-download/httpd.conf"
DOCROOT="$REPO_ROOT/assets/ca-download/www"
IMAGE="busybox:1.37"
CTR="halos-ca-download-test-$$"
PORT=18080
BASE="http://127.0.0.1:${PORT}"

if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'; else GREEN=""; RED=""; RESET=""; fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP test-ca-download-endpoint.sh: Docker unavailable (sidecar not exercised here)"
    exit 0
fi

PASSES=0
FAILS=0
# Under the repo tree, not $TMPDIR: Docker Desktop on macOS doesn't share
# /var/folders (where mktemp -d lands) for bind mounts, while the repo path
# is shared by default. Harmless on Linux CI. Cleaned up by the EXIT trap.
TMP="$(mktemp -d "$REPO_ROOT/.catest.XXXXXX")"
cleanup() { docker rm -f "$CTR" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

# Dummy published CA + profile — content is irrelevant; the test asserts
# headers/status and the adoption flip, not the bytes.
mkdir -p "$TMP/srv"
printf -- '-----BEGIN CERTIFICATE-----\ndummy\n-----END CERTIFICATE-----\n' > "$TMP/srv/halos-ca.crt"
printf '<?xml version="1.0"?><plist></plist>\n' > "$TMP/srv/halos-ca.mobileconfig"
# Device download filename the cert-manager would publish (from the CA's CN);
# the cert CGI reads it for Content-Disposition.
printf 'halos-ca-testdev.example.crt' > "$TMP/srv/download-filename"
# Single-file adoption sentinel. 0666 so the dropped uid (65534) can rewrite it
# regardless of host ownership (Linux CI) — production chowns it to that uid.
SENTINEL="$TMP/adoption"
printf 'pending' > "$SENTINEL"
chmod 0666 "$SENTINEL"

reset_sentinel() { printf 'pending' > "$SENTINEL"; }

if ! docker run -d --name "$CTR" -p "${PORT}:80" \
        -v "$DOCROOT:/www:ro" \
        -v "$HTTPD_CONF:/etc/httpd.conf:ro" \
        -v "$TMP/srv:/srv:ro" \
        -v "$SENTINEL:/adoption:rw" \
        "$IMAGE" httpd -f -p 80 -u 65534:65534 -h /www -c /etc/httpd.conf >/dev/null 2>&1; then
    echo "${RED}FAIL${RESET} could not start $IMAGE container"
    exit 1
fi

# Wait for httpd to accept connections.
for _ in $(seq 1 30); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/healthz" 2>/dev/null)" = "200" ] && break
    sleep 0.5
done

# check <description> <expected> <actual>
check() {
    if [ "$2" = "$3" ]; then
        PASSES=$((PASSES + 1)); printf '%sPASS%s %s\n' "$GREEN" "$RESET" "$1"
    else
        FAILS=$((FAILS + 1)); printf '%sFAIL%s %s (expected %q, got %q)\n' "$RED" "$RESET" "$1" "$2" "$3"
    fi
}

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# hdr <header-name> <url>: print one response header value, trimmed of CR.
# Case-insensitive on the header NAME only (busybox lowercases header names,
# e.g. "Content-type"); BSD awk lacks IGNORECASE, so match via tolower().
hdr() {
    curl -sI "$2" | tr -d '\r' | awk -v h="$1" '
        { p = index($0, ":"); if (p == 0) next
          if (tolower(substr($0, 1, p - 1)) == tolower(h)) {
              v = substr($0, p + 1); sub(/^ +/, "", v); print v; exit } }'
}

# --- /healthz: liveness only, never adopts ---------------------------------
reset_sentinel
check "GET /healthz status"                "200" "$(code "$BASE/healthz")"
check "GET /healthz leaves sentinel"       "pending" "$(cat "$SENTINEL")"

# --- /ca/halos-ca.crt: attachment + adoption flip --------------------------
reset_sentinel
check "GET /ca/halos-ca.crt status"        "200" "$(code "$BASE/ca/halos-ca.crt")"
check "GET /ca/halos-ca.crt content-type"  "application/x-x509-ca-cert" "$(hdr Content-Type "$BASE/ca/halos-ca.crt")"
# Device-specific filename from the cert-manager-published name file (derived
# from the CA's CN). A server filename overrides the page's download attribute,
# which is why this must come from the server.
check "GET /ca/halos-ca.crt disposition"   'attachment; filename="halos-ca-testdev.example.crt"' "$(hdr Content-Disposition "$BASE/ca/halos-ca.crt")"
# Cross-boundary: the in-container CGI flipped the host-visible sentinel.
check "completed cert GET adopts"          "adopted" "$(cat "$SENTINEL")"
# Idempotent: a second download with the sentinel already adopted is a no-op.
check "second cert GET stays adopted"      "adopted" "$(cat "$SENTINEL")"

# --- /ca/halos-ca.mobileconfig: inline (#169) + adoption -------------------
reset_sentinel
check "GET /ca/halos-ca.mobileconfig status"       "200" "$(code "$BASE/ca/halos-ca.mobileconfig")"
check "GET /ca/halos-ca.mobileconfig content-type" "application/x-apple-aspen-config" "$(hdr Content-Type "$BASE/ca/halos-ca.mobileconfig")"
# Load-bearing: inline (no attachment) is what lets iOS Safari hand it to the
# profile installer instead of the Files app (#169).
check "GET /ca/halos-ca.mobileconfig no attachment" "" "$(hdr Content-Disposition "$BASE/ca/halos-ca.mobileconfig")"
check "completed profile GET adopts"       "adopted" "$(cat "$SENTINEL")"

# --- HEAD / POST: no adoption, method guard --------------------------------
reset_sentinel
check "HEAD /ca/halos-ca.crt status"       "200" "$(code -I "$BASE/ca/halos-ca.crt")"
check "HEAD does not adopt"                "pending" "$(cat "$SENTINEL")"
check "POST /ca/halos-ca.crt rejected"     "405" "$(code -X POST "$BASE/ca/halos-ca.crt")"
check "POST does not adopt"                "pending" "$(cat "$SENTINEL")"

# --- bare /ca: native trailing-slash redirect ------------------------------
check "GET /ca redirect status"            "302" "$(code "$BASE/ca")"
# Location must be RELATIVE (/ca/), not scheme-qualified: behind Traefik's TLS
# termination an absolute http:// Location downgrades the client.
check "GET /ca Location is relative /ca/"  "/ca/" "$(hdr Location "$BASE/ca")"

# --- /ca/: landing page ----------------------------------------------------
check "GET /ca/ status"                    "200" "$(code "$BASE/ca/")"
case "$(hdr Content-Type "$BASE/ca/")" in text/html*) ct_ok=1 ;; *) ct_ok=0 ;; esac
check "GET /ca/ is text/html"              "1" "$ct_ok"
case "$(curl -s "$BASE/ca/")" in *"HaLOS device trust"*) body_ok=1 ;; *) body_ok=0 ;; esac
check "GET /ca/ serves landing body"       "1" "$body_ok"
# Per-OS walkthrough *content* is asserted in tests/test_landing_content.py
# (Docker-free), which the trixie CI container runs; content checks stay there.

# --- legacy /halos-ca.crt: 410 + canonical hint ----------------------------
check "GET /halos-ca.crt status"           "410" "$(code "$BASE/halos-ca.crt")"
case "$(hdr Link "$BASE/halos-ca.crt")" in *"/ca/halos-ca.crt"*) link_ok=1 ;; *) link_ok=0 ;; esac
check "GET /halos-ca.crt canonical hint"   "1" "$link_ok"

# --- unknown path ----------------------------------------------------------
check "GET /nope status"                   "404" "$(code "$BASE/nope")"

echo ""
echo "Passed: $PASSES   Failed: $FAILS"
[ "$FAILS" -eq 0 ]
