#!/bin/sh
# Wait for Authelia to be ready before starting Traefik
# This prevents HTTP 500 errors during boot when forward-auth
# middleware tries to reach Authelia before it's healthy.

set -e

AUTHELIA_URL="${AUTHELIA_HEALTH_URL:-http://authelia:9091/api/health}"
MAX_WAIT="${AUTHELIA_WAIT_TIMEOUT:-60}"
WAIT_INTERVAL=1
ELAPSED=0

echo "Waiting for Authelia to be ready at ${AUTHELIA_URL}..."

while [ $ELAPSED -lt $MAX_WAIT ]; do
    if wget -q -O /dev/null --timeout=2 "${AUTHELIA_URL}" 2>/dev/null; then
        echo "Authelia is ready (waited ${ELAPSED}s)"
        break
    fi

    # Show status every 5 seconds
    if [ $((ELAPSED % 5)) -eq 0 ] && [ $ELAPSED -gt 0 ]; then
        echo "  Still waiting for Authelia... (${ELAPSED}s)"
    fi

    sleep $WAIT_INTERVAL
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo "WARNING: Authelia not ready after ${MAX_WAIT}s"
    echo "Starting Traefik anyway - forward-auth may return 500 until Authelia is ready"
fi

# Execute the original Traefik entrypoint
exec /entrypoint.sh "$@"
