#!/usr/bin/env bash
# Tests for the ca-download sidecar nginx config (assets/ca-download/nginx.conf).
#
# Spins up the real nginx config in a throwaway nginx:alpine container with the
# real landing asset and a dummy CA cert, then asserts the served URL layout:
#   /ca/halos-ca.crt  → 200, x-x509-ca-cert, attachment
#   /ca/              → 200, text/html landing page
#   /halos-ca.crt     → 410 + canonical Link hint (moved 2026-05-28)
#   POST /ca/...      → 405 (read-only)
#
# Requires Docker. Skips cleanly (exit 0) where Docker is unavailable so the
# pure-bash suite still passes in minimal CI; the skip is logged, not silent.
#
# Run from repo root:  bash tests/test-ca-download-endpoint.sh

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NGINX_CONF="$REPO_ROOT/assets/ca-download/nginx.conf"
LANDING_DIR="$REPO_ROOT/assets/ca-download/landing"
IMAGE="nginx:1.27-alpine"
CTR="halos-ca-download-test-$$"
PORT=18080
BASE="http://127.0.0.1:${PORT}"

if [ -t 1 ]; then GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'; else GREEN=""; RED=""; RESET=""; fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP test-ca-download-endpoint.sh: Docker unavailable (sidecar config not exercised here)"
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

# Dummy CA cert bytes — content is irrelevant; the test asserts headers/status,
# not the PEM itself.
mkdir -p "$TMP/public"
printf -- '-----BEGIN CERTIFICATE-----\ndummy\n-----END CERTIFICATE-----\n' > "$TMP/public/halos-ca.crt"

# Mirror the docker-compose mount layout, including the nested /srv/landing
# mount under the read-only /srv parent — this is the layout that ships.
if ! docker run -d --name "$CTR" -p "${PORT}:80" \
        -v "$NGINX_CONF:/etc/nginx/nginx.conf:ro" \
        -v "$TMP/public:/srv:ro" \
        -v "$LANDING_DIR:/srv-landing:ro" \
        "$IMAGE" >/dev/null 2>&1; then
    echo "${RED}FAIL${RESET} could not start $IMAGE container"
    exit 1
fi

# Wait for nginx to accept connections.
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
# Print a single response header value (lowercased name match), trimmed of CR.
hdr() { curl -sI "$1" | tr -d '\r' | awk -v h="$2" 'BEGIN{IGNORECASE=1} $1==h":"{ $1=""; sub(/^ /,""); print; exit }'; }

# /ca/halos-ca.crt — the moved cert endpoint.
check "GET /ca/halos-ca.crt status"        "200" "$(code "$BASE/ca/halos-ca.crt")"
check "GET /ca/halos-ca.crt content-type"  "application/x-x509-ca-cert" "$(hdr "$BASE/ca/halos-ca.crt" Content-Type)"
check "GET /ca/halos-ca.crt disposition"   'attachment; filename="halos-ca.crt"' "$(hdr "$BASE/ca/halos-ca.crt" Content-Disposition)"

# /ca/ — landing page (proves the nested /srv/landing mount serves index.html).
check "GET /ca/ status"                    "200" "$(code "$BASE/ca/")"
case "$(hdr "$BASE/ca/" Content-Type)" in text/html*) ct_ok=1 ;; *) ct_ok=0 ;; esac
check "GET /ca/ is text/html"              "1" "$ct_ok"
case "$(curl -s "$BASE/ca/")" in *"HaLOS device trust"*) body_ok=1 ;; *) body_ok=0 ;; esac
check "GET /ca/ serves landing body"       "1" "$body_ok"

# /halos-ca.crt — moved; 410 Gone with a canonical hint.
check "GET /halos-ca.crt status"           "410" "$(code "$BASE/halos-ca.crt")"
case "$(hdr "$BASE/halos-ca.crt" Link)" in *"/ca/halos-ca.crt"*) link_ok=1 ;; *) link_ok=0 ;; esac
check "GET /halos-ca.crt canonical hint"   "1" "$link_ok"

# Read-only guard still holds on the new path. `limit_except ... deny all`
# returns 403 (the preserved pre-move behavior), not a 405 + Allow.
check "POST /ca/halos-ca.crt rejected"     "403" "$(code -X POST "$BASE/ca/halos-ca.crt")"

# Unknown path still 404s.
check "GET /nope status"                   "404" "$(code "$BASE/nope")"

echo ""
echo "Passed: $PASSES   Failed: $FAILS"
[ "$FAILS" -eq 0 ]
