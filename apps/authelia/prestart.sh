#!/bin/bash
# Prestart script for authelia-container
# Generates secrets on first boot, processes configuration template,
# and merges OIDC client snippets from /etc/halos/oidc-clients.d/
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

# CONTAINER_DATA_ROOT already points to the data directory
DATA_DIR="${CONTAINER_DATA_ROOT}"
TEMPLATE_FILE="${SCRIPT_DIR}/configuration.yml.template"
SECRETS_FILE="${DATA_DIR}/secrets.env"
CONFIG_FILE="${DATA_DIR}/configuration.yml"
OIDC_CLIENTS_FILE="${DATA_DIR}/oidc-clients.yml"
OIDC_CLIENTS_DIR="/etc/halos/oidc-clients.d"

# Create data directory
mkdir -p "${DATA_DIR}"

# Create OIDC clients directory if it doesn't exist
# This directory is owned by authelia-container and apps drop snippets here
mkdir -p "${OIDC_CLIENTS_DIR}"

# Generate secrets on first boot
generate_secrets() {
    echo "Generating Authelia secrets..."

    # Generate random secrets
    SESSION_SECRET=$(openssl rand -hex 32)
    OIDC_HMAC_SECRET=$(openssl rand -hex 32)
    STORAGE_ENCRYPTION_KEY=$(openssl rand -hex 32)
    RESET_PASSWORD_JWT_SECRET=$(openssl rand -hex 32)

    # Generate RSA private key for OIDC JWT signing
    OIDC_PRIVATE_KEY=$(openssl genrsa 4096 2>/dev/null)

    # Save secrets to file
    cat > "${SECRETS_FILE}" << EOF
SESSION_SECRET="${SESSION_SECRET}"
OIDC_HMAC_SECRET="${OIDC_HMAC_SECRET}"
STORAGE_ENCRYPTION_KEY="${STORAGE_ENCRYPTION_KEY}"
RESET_PASSWORD_JWT_SECRET="${RESET_PASSWORD_JWT_SECRET}"
EOF

    # Save private key separately (multi-line)
    echo "${OIDC_PRIVATE_KEY}" > "${DATA_DIR}/oidc_private_key.pem"

    # Restrict permissions
    chmod 600 "${SECRETS_FILE}" "${DATA_DIR}/oidc_private_key.pem"

    echo "Secrets generated successfully"
}

# Hash a plaintext secret using pbkdf2-sha512 (Authelia-compatible)
# Uses Authelia's own CLI to ensure correct format
# Returns non-zero on failure
hash_client_secret() {
    local plaintext="$1"

    # Use Authelia's own CLI for reliable hashing
    # The authelia container must be available (pulled or cached)
    local hash_output
    hash_output=$(docker run --rm authelia/authelia:4.39 authelia crypto hash generate pbkdf2 \
        --variant sha512 \
        --password "${plaintext}" 2>/dev/null)

    if [ $? -ne 0 ]; then
        return 1
    fi

    # Extract the hash from the output (format: "Digest: $pbkdf2-sha512$...")
    echo "$hash_output" | grep 'Digest:' | sed 's/Digest: //'
}

# Merge OIDC client snippets from .d directory
# YAML Parsing Limitations:
#   - Snippets must use simple YAML format (no anchors, aliases, or complex types)
#   - Values should not contain inline comments (# after value)
#   - Multi-line quoted strings are not supported
#   - Array items must be on separate lines with "- " prefix
#   - Scopes can use inline format: [openid, profile, email]
merge_oidc_clients() {
    echo "Merging OIDC client snippets..."

    local client_count=0
    local clients_yaml=""

    # Process each snippet file
    for snippet in "${OIDC_CLIENTS_DIR}"/*.yml; do
        # Skip if no files match
        [ -e "$snippet" ] || continue

        local snippet_name=$(basename "$snippet")
        echo "  Processing: ${snippet_name}"

        # Read required fields from snippet
        local client_id=$(grep -E '^client_id:' "$snippet" | sed 's/client_id:[[:space:]]*//' | tr -d "'\"")
        local client_name=$(grep -E '^client_name:' "$snippet" | sed 's/client_name:[[:space:]]*//' | tr -d "'\"")
        local client_secret_file=$(grep -E '^client_secret_file:' "$snippet" | sed 's/client_secret_file:[[:space:]]*//' | tr -d "'\"")
        local consent_mode=$(grep -E '^consent_mode:' "$snippet" | sed 's/consent_mode:[[:space:]]*//' | tr -d "'\"")
        local token_auth_method=$(grep -E '^token_endpoint_auth_method:' "$snippet" | sed 's/token_endpoint_auth_method:[[:space:]]*//' | tr -d "'\"")
        local userinfo_signed=$(grep -E '^userinfo_signed_response_alg:' "$snippet" | sed 's/userinfo_signed_response_alg:[[:space:]]*//' | tr -d "'\"")
        local id_token_signed=$(grep -E '^id_token_signed_response_alg:' "$snippet" | sed 's/id_token_signed_response_alg:[[:space:]]*//' | tr -d "'\"")

        # Validate required fields
        if [ -z "$client_id" ]; then
            echo "  WARNING: Skipping ${snippet_name} - missing client_id"
            continue
        fi

        # Read and hash client secret
        local client_secret_hash=""
        if [ -n "$client_secret_file" ] && [ -f "$client_secret_file" ]; then
            local plaintext_secret=$(cat "$client_secret_file")
            if ! client_secret_hash=$(hash_client_secret "$plaintext_secret"); then
                echo "  ERROR: Failed to hash client secret for ${snippet_name}"
                continue
            fi
            # Validate hash output format
            if [[ ! "$client_secret_hash" =~ ^\$pbkdf2-sha512\$ ]]; then
                echo "  ERROR: Invalid hash format for ${snippet_name}"
                continue
            fi
        else
            echo "  WARNING: Skipping ${snippet_name} - client_secret_file not found: ${client_secret_file}"
            continue
        fi

        # Extract redirect_uris (handle multi-line YAML array)
        local redirect_uris=""
        local in_redirect=false
        while IFS= read -r line; do
            if echo "$line" | grep -qE '^redirect_uris:'; then
                in_redirect=true
                continue
            fi
            if $in_redirect; then
                if echo "$line" | grep -qE '^[[:space:]]+-'; then
                    # Extract URI, substitute domain, and format
                    local uri=$(echo "$line" | sed "s/^[[:space:]]*-[[:space:]]*//" | tr -d "'\"")
                    uri="${uri//\$\{HALOS_DOMAIN\}/${HALOS_DOMAIN}}"
                    redirect_uris="${redirect_uris}          - '${uri}'\n"
                elif echo "$line" | grep -qE '^[a-z_]+:'; then
                    # New top-level key, stop reading redirect_uris
                    break
                fi
            fi
        done < "$snippet"

        # Extract scopes (handle YAML array on single line or multi-line)
        local scopes_line=$(grep -E '^scopes:' "$snippet")
        local scopes=""
        if echo "$scopes_line" | grep -qE '\[.*\]'; then
            # Inline array format: scopes: [openid, profile, email]
            scopes=$(echo "$scopes_line" | sed 's/scopes:[[:space:]]*//')
        else
            # Multi-line array - extract items
            local in_scopes=false
            local scope_items=""
            while IFS= read -r line; do
                if echo "$line" | grep -qE '^scopes:'; then
                    in_scopes=true
                    continue
                fi
                if $in_scopes; then
                    if echo "$line" | grep -qE '^[[:space:]]+-'; then
                        local item=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | tr -d "'\"")
                        scope_items="${scope_items}${item}, "
                    elif echo "$line" | grep -qE '^[a-z_]+:'; then
                        break
                    fi
                fi
            done < "$snippet"
            scopes="[${scope_items%, }]"
        fi

        # Build optional fields
        local extra_fields=""
        [ -n "$userinfo_signed" ] && extra_fields="${extra_fields}        userinfo_signed_response_alg: ${userinfo_signed}
"
        [ -n "$id_token_signed" ] && extra_fields="${extra_fields}        id_token_signed_response_alg: ${id_token_signed}
"

        # Append client to clients_yaml
        clients_yaml="${clients_yaml}      - client_id: ${client_id}
        client_name: '${client_name:-${client_id}}'
        client_secret: '${client_secret_hash}'
        public: false
        authorization_policy: one_factor
        redirect_uris:
$(echo -e "${redirect_uris}" | sed '/^$/d')
        scopes: ${scopes:-[openid, profile, email]}
        consent_mode: ${consent_mode:-implicit}
        token_endpoint_auth_method: ${token_auth_method:-client_secret_post}
${extra_fields}"

        client_count=$((client_count + 1))
    done

    # Only create OIDC config if there are valid clients
    if [ $client_count -eq 0 ]; then
        echo "  No OIDC client snippets found - OIDC will be disabled"
        # Create empty config file (Authelia requires file to exist but accepts empty)
        cat > "${OIDC_CLIENTS_FILE}" << 'EOF'
# Authelia OIDC Configuration
# Generated by authelia-container prestart
# No OIDC clients configured - OIDC is disabled
EOF
        chmod 600 "${OIDC_CLIENTS_FILE}"
    else
        echo "  Merged ${client_count} OIDC client(s)"

        # Indent private key for YAML (6 spaces for jwks key block)
        local indented_key
        indented_key=$(echo "${OIDC_PRIVATE_KEY}" | awk 'NR==1 {print} NR>1 {print "          " $0}')

        # Generate full OIDC configuration with clients
        cat > "${OIDC_CLIENTS_FILE}" << EOF
# Authelia OIDC Configuration
# Generated by authelia-container prestart - do not edit manually
# Client snippets are loaded from /etc/halos/oidc-clients.d/

identity_providers:
  oidc:
    hmac_secret: '${OIDC_HMAC_SECRET}'
    jwks:
      - key: |
          ${indented_key}
    clients:
${clients_yaml}
EOF
        chmod 600 "${OIDC_CLIENTS_FILE}"
    fi
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

# Write HALOS_DOMAIN to runtime.env for docker-compose label substitution
RUNTIME_ENV_DIR="/run/container-apps/${PACKAGE_NAME}"
mkdir -p "${RUNTIME_ENV_DIR}"
echo "HALOS_DOMAIN=${HALOS_DOMAIN}" >> "${RUNTIME_ENV_DIR}/runtime.env"

# Process configuration template
process_template() {
    echo "Processing Authelia configuration template..."

    # Read template
    local template
    template=$(cat "${TEMPLATE_FILE}")

    # Indent private key for YAML (10 spaces to match jwks key block)
    # First line doesn't need indentation (template already has it)
    # Subsequent lines need 10 spaces
    local indented_key
    indented_key=$(echo "${OIDC_PRIVATE_KEY}" | awk 'NR==1 {print} NR>1 {print "          " $0}')

    # Substitute variables
    template="${template//\$\{SESSION_SECRET\}/${SESSION_SECRET}}"
    template="${template//\$\{OIDC_HMAC_SECRET\}/${OIDC_HMAC_SECRET}}"
    template="${template//\$\{STORAGE_ENCRYPTION_KEY\}/${STORAGE_ENCRYPTION_KEY}}"
    template="${template//\$\{RESET_PASSWORD_JWT_SECRET\}/${RESET_PASSWORD_JWT_SECRET}}"
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

# Merge OIDC client snippets
merge_oidc_clients

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
