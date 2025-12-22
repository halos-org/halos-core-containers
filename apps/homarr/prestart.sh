#!/bin/bash
# Prestart script for homarr-container
# Handles SECRET_ENCRYPTION_KEY generation, seed database, and SSO configuration
set -e

# Derive package name from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="$(basename "$SCRIPT_DIR")"
ETC_DIR="/etc/container-apps/${PACKAGE_NAME}"
RUN_DIR="/run/container-apps/${PACKAGE_NAME}"
RUNTIME_ENV="${RUN_DIR}/runtime.env"
ENV_FILE="${ETC_DIR}/env"
DATA_DIR="/var/lib/container-apps/${PACKAGE_NAME}/data"

# Seed database from halos-homarr-branding
SEED_DB="/var/lib/halos-homarr-branding/db-seed.sqlite3"

# Authelia secrets location
AUTHELIA_SECRETS="/var/lib/container-apps/authelia-container/data/secrets.env"

# Create runtime directory
mkdir -p "$(dirname "$RUNTIME_ENV")"

# Initialize Homarr database from seed if not present
# The seed database contains pre-configured settings and bootstrap API key
# Note: Homarr v1.x uses /appdata/db/db.sqlite inside container
HOMARR_DB="${DATA_DIR}/data/db/db.sqlite"
if [ ! -f "$HOMARR_DB" ] && [ -f "$SEED_DB" ]; then
    echo "Initializing Homarr database from seed..."
    mkdir -p "$(dirname "$HOMARR_DB")"
    cp "$SEED_DB" "$HOMARR_DB"
    chmod 644 "$HOMARR_DB"
    echo "Homarr database initialized with pre-configured settings"
fi

# Load config values from env files
set -a
[ -f "${ETC_DIR}/env.defaults" ] && . "${ETC_DIR}/env.defaults"
[ -f "${ENV_FILE}" ] && . "${ENV_FILE}"
set +a

# Generate SECRET_ENCRYPTION_KEY if not set or empty
if [ -z "$SECRET_ENCRYPTION_KEY" ]; then
    echo "Generating SECRET_ENCRYPTION_KEY..."
    SECRET_ENCRYPTION_KEY=$(openssl rand -hex 32)
    echo "SECRET_ENCRYPTION_KEY=\"${SECRET_ENCRYPTION_KEY}\"" >> "${ENV_FILE}"
fi

# Set hostname and domain (matches mDNS publisher)
HOSTNAME="$(hostname -s)"
HALOS_DOMAIN="${HOSTNAME}.local"
echo "HOSTNAME=$HOSTNAME" > "$RUNTIME_ENV"
echo "HALOS_DOMAIN=$HALOS_DOMAIN" >> "$RUNTIME_ENV"

# Write HALOS_DOMAIN to env file for docker-compose labels
if ! grep -q "^HALOS_DOMAIN=" "${ENV_FILE}" 2>/dev/null; then
    echo "HALOS_DOMAIN=\"${HALOS_DOMAIN}\"" >> "${ENV_FILE}"
fi

# Compute Homarr URL (goes through Traefik)
HOMARR_URL="https://${HALOS_DOMAIN}/"
echo "HOMARR_URL=$HOMARR_URL" >> "$RUNTIME_ENV"

# Configure SSO with Authelia (enabled by default)
echo "Configuring SSO with Authelia..."

# Enable OIDC-only authentication (no credentials login)
# The homarr-container-adapter uses API key authentication instead
if ! grep -q "^AUTH_PROVIDERS=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_PROVIDERS=\"oidc\"" >> "${ENV_FILE}"
fi

# Set OIDC issuer URL
if ! grep -q "^AUTH_OIDC_ISSUER=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_OIDC_ISSUER=\"https://auth.${HALOS_DOMAIN}\"" >> "${ENV_FILE}"
fi

# Set client ID
if ! grep -q "^AUTH_OIDC_CLIENT_ID=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_OIDC_CLIENT_ID=\"homarr\"" >> "${ENV_FILE}"
fi

# Get client secret from Authelia
if ! grep -q "^AUTH_OIDC_CLIENT_SECRET=" "${ENV_FILE}" 2>/dev/null; then
    if [ -f "$AUTHELIA_SECRETS" ]; then
        # Source Authelia secrets to get HOMARR_CLIENT_SECRET
        . "$AUTHELIA_SECRETS"
        if [ -n "$HOMARR_CLIENT_SECRET" ]; then
            echo "AUTH_OIDC_CLIENT_SECRET=\"${HOMARR_CLIENT_SECRET}\"" >> "${ENV_FILE}"
            echo "Retrieved OIDC client secret from Authelia"
        else
            echo "WARNING: HOMARR_CLIENT_SECRET not found in Authelia secrets"
        fi
    else
        echo "WARNING: Authelia secrets file not found at $AUTHELIA_SECRETS"
        echo "SSO will not work until Authelia is installed and configured"
    fi
fi

# Set provider display name
if ! grep -q "^AUTH_OIDC_CLIENT_NAME=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_OIDC_CLIENT_NAME=\"HaLOS\"" >> "${ENV_FILE}"
fi

# Set OIDC scopes
if ! grep -q "^AUTH_OIDC_SCOPE_OVERWRITE=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_OIDC_SCOPE_OVERWRITE=\"openid profile email groups\"" >> "${ENV_FILE}"
fi

# Set logout redirect URL
if ! grep -q "^AUTH_LOGOUT_REDIRECT_URL=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_LOGOUT_REDIRECT_URL=\"https://auth.${HALOS_DOMAIN}/logout\"" >> "${ENV_FILE}"
fi

echo "Homarr prestart complete"
