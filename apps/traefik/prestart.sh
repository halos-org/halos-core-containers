#!/bin/bash
# Prestart script for traefik-container
# Creates acme.json with proper permissions for Let's Encrypt certificates
set -e

# Derive package name from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="$(basename "$SCRIPT_DIR")"
ETC_DIR="/etc/container-apps/${PACKAGE_NAME}"

# Load config values from env files
set -a
[ -f "${ETC_DIR}/env.defaults" ] && . "${ETC_DIR}/env.defaults"
[ -f "${ETC_DIR}/env" ] && . "${ETC_DIR}/env"
set +a

# Create data directory
mkdir -p "${CONTAINER_DATA_ROOT}"

# Create acme.json with proper permissions if it doesn't exist
# Traefik requires this file to have 600 permissions
ACME_FILE="${CONTAINER_DATA_ROOT}/acme.json"
if [ ! -f "${ACME_FILE}" ]; then
    touch "${ACME_FILE}"
    chmod 600 "${ACME_FILE}"
fi
