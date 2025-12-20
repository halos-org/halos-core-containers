#!/bin/bash
# Prestart script for authelia-container
# Generates secrets on first boot and processes configuration template
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

DATA_DIR="${CONTAINER_DATA_ROOT}/data"
TEMPLATE_FILE="${SCRIPT_DIR}/configuration.yml.template"
SECRETS_FILE="${DATA_DIR}/secrets.env"
CONFIG_FILE="${DATA_DIR}/configuration.yml"

# Create data directory
mkdir -p "${DATA_DIR}"

# Generate secrets on first boot
generate_secrets() {
    echo "Generating Authelia secrets..."

    # Generate random secrets
    SESSION_SECRET=$(openssl rand -hex 32)
    OIDC_HMAC_SECRET=$(openssl rand -hex 32)
    HOMARR_CLIENT_SECRET=$(openssl rand -hex 32)

    # Generate RSA private key for OIDC JWT signing
    OIDC_PRIVATE_KEY=$(openssl genrsa 4096 2>/dev/null)

    # Save secrets to file
    cat > "${SECRETS_FILE}" << EOF
SESSION_SECRET="${SESSION_SECRET}"
OIDC_HMAC_SECRET="${OIDC_HMAC_SECRET}"
HOMARR_CLIENT_SECRET="${HOMARR_CLIENT_SECRET}"
EOF

    # Save private key separately (multi-line)
    echo "${OIDC_PRIVATE_KEY}" > "${DATA_DIR}/oidc_private_key.pem"

    # Restrict permissions
    chmod 600 "${SECRETS_FILE}" "${DATA_DIR}/oidc_private_key.pem"

    echo "Secrets generated successfully"
}

# Load or generate secrets
if [ ! -f "${SECRETS_FILE}" ]; then
    generate_secrets
fi

# Load secrets
. "${SECRETS_FILE}"
OIDC_PRIVATE_KEY=$(cat "${DATA_DIR}/oidc_private_key.pem")

# Auto-detect domain from hostname (matches mDNS publisher)
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
HALOS_DOMAIN="${HOSTNAME_SHORT}.local"

# Process configuration template
process_template() {
    echo "Processing Authelia configuration template..."

    # Read template
    local template
    template=$(cat "${TEMPLATE_FILE}")

    # Indent private key for YAML (8 spaces)
    local indented_key
    indented_key=$(echo "${OIDC_PRIVATE_KEY}" | sed 's/^/          /')

    # Substitute variables
    template="${template//\$\{SESSION_SECRET\}/${SESSION_SECRET}}"
    template="${template//\$\{OIDC_HMAC_SECRET\}/${OIDC_HMAC_SECRET}}"
    template="${template//\$\{HOMARR_CLIENT_SECRET\}/${HOMARR_CLIENT_SECRET}}"
    template="${template//\$\{HALOS_DOMAIN\}/${HALOS_DOMAIN}}"

    # Handle private key separately (multi-line)
    # Use awk for multi-line substitution
    echo "${template}" | awk -v key="${indented_key}" '
        /\$\{OIDC_PRIVATE_KEY\}/ {
            sub(/\$\{OIDC_PRIVATE_KEY\}/, key)
        }
        { print }
    ' > "${CONFIG_FILE}"

    chmod 600 "${CONFIG_FILE}"
    echo "Configuration generated at ${CONFIG_FILE}"
}

# Always regenerate config (in case template or domain changed)
process_template

# Create empty users database if it doesn't exist
# This will be populated by homarr-container-adapter credential sync
if [ ! -f "${DATA_DIR}/users_database.yml" ]; then
    echo "Creating empty users database..."
    cat > "${DATA_DIR}/users_database.yml" << 'EOF'
# Authelia Users Database
# This file is managed by homarr-container-adapter
# Manual edits may be overwritten

users: {}
EOF
    chmod 600 "${DATA_DIR}/users_database.yml"
fi

echo "Authelia prestart complete"
