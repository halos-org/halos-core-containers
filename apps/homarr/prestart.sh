#!/bin/bash
# Prestart script for homarr-container
# Handles SECRET_ENCRYPTION_KEY generation, seed database, OIDC client registration, and SSO configuration
set -e

# Derive package name from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="$(basename "$SCRIPT_DIR")"
ETC_DIR="/etc/container-apps/${PACKAGE_NAME}"
RUN_DIR="/run/container-apps/${PACKAGE_NAME}"
RUNTIME_ENV="${RUN_DIR}/runtime.env"
ENV_FILE="${ETC_DIR}/env"
DATA_DIR="/var/lib/container-apps/${PACKAGE_NAME}/data"

# OIDC client configuration
OIDC_CLIENTS_DIR="/etc/halos/oidc-clients.d"
OIDC_SECRET_FILE="${DATA_DIR}/oidc-secret"
OIDC_SNIPPET_SRC="${SCRIPT_DIR}/assets/oidc-client.yml"
OIDC_SNIPPET_DST="${OIDC_CLIENTS_DIR}/homarr.yml"

# Seed database from halos-homarr-branding
SEED_DB="/var/lib/halos-homarr-branding/db-seed.sqlite3"

# Create runtime directory
mkdir -p "$(dirname "$RUNTIME_ENV")"
mkdir -p "${DATA_DIR}"

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

# Generate SECRET_ENCRYPTION_KEY if not set or empty.
# IMPORTANT: Use [ -z ] check (not grep) because regenerating this key causes
# data loss - Homarr uses it to encrypt secrets in the database.
if [ -z "$SECRET_ENCRYPTION_KEY" ]; then
    echo "Generating SECRET_ENCRYPTION_KEY..."
    SECRET_ENCRYPTION_KEY=$(openssl rand -hex 32)
    echo "SECRET_ENCRYPTION_KEY=\"${SECRET_ENCRYPTION_KEY}\"" >> "${ENV_FILE}"
fi

# Generate AUTH_SECRET for NextAuth.js (required for OIDC state encryption).
# Use stricter check requiring non-empty quoted value - regeneration only
# requires re-login, not data loss.
if ! grep -qE "^AUTH_SECRET=\"[^\"]+\"" "${ENV_FILE}" 2>/dev/null; then
    echo "Generating AUTH_SECRET..."
    AUTH_SECRET=$(openssl rand -hex 32)
    echo "AUTH_SECRET=\"${AUTH_SECRET}\"" >> "${ENV_FILE}"
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

# ============================================
# OIDC Client Registration
# ============================================
echo "Setting up OIDC client registration..."

# Generate OIDC client secret if it doesn't exist
if [ ! -f "${OIDC_SECRET_FILE}" ]; then
    echo "Generating OIDC client secret..."
    openssl rand -hex 32 > "${OIDC_SECRET_FILE}"
    chmod 600 "${OIDC_SECRET_FILE}"
    echo "OIDC client secret generated at ${OIDC_SECRET_FILE}"
fi

# Read the client secret for environment configuration
OIDC_CLIENT_SECRET=$(cat "${OIDC_SECRET_FILE}")

# Install OIDC client snippet to the .d directory
# Create directory if it doesn't exist (idempotent, avoids race condition with Authelia)
mkdir -p "${OIDC_CLIENTS_DIR}"

if [ -f "${OIDC_SNIPPET_SRC}" ]; then
    echo "Installing OIDC client snippet to ${OIDC_SNIPPET_DST}"
    cp "${OIDC_SNIPPET_SRC}" "${OIDC_SNIPPET_DST}"
    chmod 644 "${OIDC_SNIPPET_DST}"
else
    echo "WARNING: OIDC snippet source not found at ${OIDC_SNIPPET_SRC}"
fi

# ============================================
# SSO Configuration for Homarr
# ============================================
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

# Set client secret (use our generated secret)
if ! grep -q "^AUTH_OIDC_CLIENT_SECRET=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_OIDC_CLIENT_SECRET=\"${OIDC_CLIENT_SECRET}\"" >> "${ENV_FILE}"
    echo "Configured OIDC client secret"
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

# Force userinfo endpoint usage (required for Authelia v4.39+)
# See https://github.com/homarr-labs/homarr/issues/2635
if ! grep -q "^AUTH_OIDC_FORCE_USERINFO=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_OIDC_FORCE_USERINFO=\"true\"" >> "${ENV_FILE}"
fi

# Enable account linking to allow OIDC users to link to existing accounts.
# The name sounds scary, but in HaLOS's single-user device context (where the
# same person owns both local and OIDC accounts), this is the expected behavior.
if ! grep -q "^AUTH_OIDC_ENABLE_DANGEROUS_ACCOUNT_LINKING=" "${ENV_FILE}" 2>/dev/null; then
    echo "AUTH_OIDC_ENABLE_DANGEROUS_ACCOUNT_LINKING=\"true\"" >> "${ENV_FILE}"
fi

echo "Homarr prestart complete"
