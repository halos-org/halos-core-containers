#!/bin/bash
# Prestart script for traefik-container
# Copies static configuration from assets to the config directory
set -e

# Derive package name from script location
# Script is at /var/lib/container-apps/<package-name>/prestart.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="$(basename "$SCRIPT_DIR")"
ETC_DIR="/etc/container-apps/${PACKAGE_NAME}"

# Load config values from env files
set -a
[ -f "${ETC_DIR}/env.defaults" ] && . "${ETC_DIR}/env.defaults"
[ -f "${ETC_DIR}/env" ] && . "${ETC_DIR}/env"
set +a

ASSETS_DIR="${SCRIPT_DIR}/assets"
CONFIG_DIR="${CONTAINER_DATA_ROOT}/config"
DATA_DIR="${CONTAINER_DATA_ROOT}/data"

# Create directory structure
mkdir -p "${CONFIG_DIR}/dynamic"
mkdir -p "${DATA_DIR}"

# Copy static configuration files (always overwrite to get updates)
cp "${ASSETS_DIR}/traefik.yml" "${CONFIG_DIR}/traefik.yml"
cp "${ASSETS_DIR}/dynamic/authelia.yml" "${CONFIG_DIR}/dynamic/authelia.yml"

# Create acme.json with proper permissions if it doesn't exist
if [ ! -f "${DATA_DIR}/acme.json" ]; then
    touch "${DATA_DIR}/acme.json"
    chmod 600 "${DATA_DIR}/acme.json"
fi
