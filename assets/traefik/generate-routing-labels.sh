#!/bin/bash
# Generate Traefik Docker labels from generic routing declarations
# This script reads /etc/halos/routing.d/*.yml and generates:
# 1. Docker-compose override files in /run/halos/routing-labels/
# 2. Per-app ForwardAuth middleware in /etc/halos/traefik-dynamic.d/
# 3. Path redirect configs in /etc/halos/traefik-dynamic.d/
# 4. HALOS_EXTERNAL_PORT in each app's runtime env directory
#
# This is the bulk version — processes all routing files at once.
# Individual apps use configure-container-routing instead.

set -e

# Directories can be overridden via environment variables for testing
ROUTING_DIR="${ROUTING_DIR:-/etc/halos/routing.d}"
OUTPUT_DIR="${OUTPUT_DIR:-/run/halos/routing-labels}"
MIDDLEWARE_DIR="${MIDDLEWARE_DIR:-/etc/halos/traefik-dynamic.d}"

# Ensure output directories exist
mkdir -p "${OUTPUT_DIR}"
mkdir -p "${MIDDLEWARE_DIR}"

# Get HALOS_DOMAIN from environment or derive from hostname
if [ -z "${HALOS_DOMAIN}" ]; then
    HOSTNAME="$(hostname -s)"
    HALOS_DOMAIN="${HOSTNAME}.local"
fi

log() {
    echo "[generate-routing-labels] $1" >&2
}

# Main: Process all routing files using configure-container-routing
main() {
    log "Starting routing label generation"
    log "HALOS_DOMAIN=${HALOS_DOMAIN}"

    if [ ! -d "${ROUTING_DIR}" ]; then
        log "Routing directory does not exist: ${ROUTING_DIR}"
        log "No routing files to process"
        return 0
    fi

    local count=0
    for routing_file in "${ROUTING_DIR}"/*.yml; do
        if [ -f "${routing_file}" ]; then
            local app_id
            app_id=$(grep "^app_id:" "$routing_file" | sed 's/^app_id:[[:space:]]*//' | sed 's/^"//' | sed 's/"$//')
            if [ -n "${app_id}" ]; then
                /usr/bin/configure-container-routing "${app_id}" && ((count++)) || true
            fi
        fi
    done

    log "Processed ${count} routing file(s)"
}

main "$@"
