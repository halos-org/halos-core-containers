#!/bin/bash
# Prestart script for homarr-container
# Custom script to handle SECRET_ENCRYPTION_KEY generation and runtime env setup
set -e

# Derive package name from script location
# Script is at /var/lib/container-apps/<package-name>/prestart.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="$(basename "$SCRIPT_DIR")"
ETC_DIR="/etc/container-apps/${PACKAGE_NAME}"
RUN_DIR="/run/container-apps/${PACKAGE_NAME}"
RUNTIME_ENV="${RUN_DIR}/runtime.env"
ENV_FILE="${ETC_DIR}/env"

# Create runtime directory
mkdir -p "$(dirname "$RUNTIME_ENV")"

# Load config values from env files
set -a
[ -f "${ETC_DIR}/env.defaults" ] && . "${ETC_DIR}/env.defaults"
[ -f "${ENV_FILE}" ] && . "${ENV_FILE}"
set +a

# Generate SECRET_ENCRYPTION_KEY if not set or empty
if [ -z "$SECRET_ENCRYPTION_KEY" ]; then
    echo "Generating SECRET_ENCRYPTION_KEY..."
    SECRET_ENCRYPTION_KEY=$(openssl rand -hex 32)
    # Persist the generated key to the user env file
    echo "SECRET_ENCRYPTION_KEY=\"${SECRET_ENCRYPTION_KEY}\"" >> "${ENV_FILE}"
fi

# Set hostname
HOSTNAME="$(hostname -s)"
echo "HOSTNAME=$HOSTNAME" > "$RUNTIME_ENV"

# Compute Homarr URL
# Use PORT variable if set, otherwise default to 80
PORT="${PORT:-80}"
HOMARR_URL="http://${HOSTNAME}.local:${PORT}/"
echo "HOMARR_URL=$HOMARR_URL" >> "$RUNTIME_ENV"
