#!/bin/bash
# Unified prestart script for halos-core-containers
# Initializes Traefik, Authelia, and Homarr in the correct order
set -e

# ============================================
# Common Setup
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="$(basename "$SCRIPT_DIR")"
ETC_DIR="/etc/container-apps/${PACKAGE_NAME}"
RUN_DIR="/run/container-apps/${PACKAGE_NAME}"
RUNTIME_ENV="${RUN_DIR}/runtime.env"

# Load config values from env files
set -a
[ -f "${ETC_DIR}/env.defaults" ] && . "${ETC_DIR}/env.defaults"
[ -f "${ETC_DIR}/env" ] && . "${ETC_DIR}/env"
set +a

# Create runtime directory
mkdir -p "${RUN_DIR}"

# Load hostname list — the canonical hostname becomes HALOS_DOMAIN.
# Falls back to ${hostname}.local when /etc/halos/hostnames.conf is
# missing/invalid; HALOS_HOSTNAMES_FALLBACK is set in that case.
LIB_HOSTNAMES="/usr/lib/halos-core-containers/lib-hostnames.sh"
if [ ! -f "$LIB_HOSTNAMES" ]; then
    # Source from package assets when running uninstalled (development).
    LIB_HOSTNAMES="${SCRIPT_DIR}/assets/lib-hostnames.sh"
fi
# shellcheck source=assets/lib-hostnames.sh
. "$LIB_HOSTNAMES"
halos_load_hostnames

HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)
HALOS_DOMAIN="$(halos_canonical_hostname)"

# Write common runtime environment
cat > "${RUNTIME_ENV}" << EOF
HALOS_DOMAIN=${HALOS_DOMAIN}
HOSTNAME=${HOSTNAME_SHORT}
EOF

echo "HaLOS Core Containers prestart"
echo "Domain: ${HALOS_DOMAIN}"

# Data directories for each service
TRAEFIK_DATA="${CONTAINER_DATA_ROOT}/traefik"
AUTHELIA_DATA="${CONTAINER_DATA_ROOT}/authelia"
HOMARR_DATA="${CONTAINER_DATA_ROOT}/homarr"

mkdir -p "${TRAEFIK_DATA}" "${AUTHELIA_DATA}" "${AUTHELIA_DATA}/valkey" "${HOMARR_DATA}"

# ============================================
# Traefik Setup
# ============================================
echo ""
echo "=== Traefik Setup ==="

# Create acme.json with proper permissions if it doesn't exist
ACME_FILE="${TRAEFIK_DATA}/acme.json"
if [ ! -f "${ACME_FILE}" ]; then
    touch "${ACME_FILE}"
    chmod 600 "${ACME_FILE}"
    echo "Created acme.json"
fi

# Self-Signed TLS Certificate Generation
CERTS_DIR="${TRAEFIK_DATA}/certs"
CERT_FILE="${CERTS_DIR}/halos.crt"
KEY_FILE="${CERTS_DIR}/halos.key"
DOMAIN_FILE="${CERTS_DIR}/.domain"

mkdir -p "${CERTS_DIR}"

# Check if certificate needs to be (re)generated.
# Change-detection: SHA256 hash of the sorted hostname list, stored in
# ${DOMAIN_FILE}. Three-state read:
#   - file absent          → regenerate
#   - exactly 64 hex chars → compare as hash
#   - anything else        → legacy hostname string from older versions; regenerate once
HOSTNAMES_HASH="$(halos_hostnames_hash)"
NEED_CERT=false
if [ ! -f "${CERT_FILE}" ] || [ ! -f "${KEY_FILE}" ]; then
    echo "Certificate files not found, generating..."
    NEED_CERT=true
elif [ -f "${DOMAIN_FILE}" ]; then
    STORED=$(cat "${DOMAIN_FILE}")
    if [[ "${STORED}" =~ ^[0-9a-f]{64}$ ]]; then
        if [ "${STORED}" != "${HOSTNAMES_HASH}" ]; then
            echo "Hostname list changed, regenerating certificate..."
            NEED_CERT=true
        fi
    else
        echo "Legacy domain sentinel detected, migrating to hostname-list hash..."
        NEED_CERT=true
    fi
else
    echo "Domain tracking file not found, regenerating certificate..."
    NEED_CERT=true
fi

if [ "${NEED_CERT}" = true ]; then
    # Build subjectAltName: DNS: entries followed by IP: entries, sorted
    # for deterministic output. Each value passed through the loader has
    # already been validated; we still quote at use site (defense-in-depth).
    SAN_ENTRIES=""
    while IFS= read -r dns_entry; do
        [ -z "$dns_entry" ] && continue
        SAN_ENTRIES="${SAN_ENTRIES}${SAN_ENTRIES:+,}DNS:${dns_entry}"
    done < <(halos_dns_hostnames | LC_ALL=C sort)
    if [ "${#HALOS_HOSTNAMES_IPS[@]}" -gt 0 ]; then
        while IFS= read -r ip_entry; do
            [ -z "$ip_entry" ] && continue
            SAN_ENTRIES="${SAN_ENTRIES}${SAN_ENTRIES:+,}IP:${ip_entry}"
        done < <(printf '%s\n' "${HALOS_HOSTNAMES_IPS[@]}" | LC_ALL=C sort)
    fi

    echo "Generating self-signed TLS certificate (CN=${HALOS_DOMAIN}, SANs=${SAN_ENTRIES})..."
    KEY_NEW="${KEY_FILE}.new"
    CERT_NEW="${CERT_FILE}.new"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${KEY_NEW}" \
        -out "${CERT_NEW}" \
        -subj "/CN=${HALOS_DOMAIN}" \
        -addext "subjectAltName=${SAN_ENTRIES}"
    chmod 600 "${KEY_NEW}"
    chmod 644 "${CERT_NEW}"
    # Atomic swap: key first (Traefik tolerates a brief key-without-cert
    # window better than the inverse), then cert. Traefik only reloads
    # when tls-default.yml mtime changes (re-touched below).
    mv "${KEY_NEW}" "${KEY_FILE}"
    mv "${CERT_NEW}" "${CERT_FILE}"
    printf '%s' "${HOSTNAMES_HASH}" > "${DOMAIN_FILE}"
    echo "Certificate generated successfully"
else
    echo "Using existing certificate for ${HALOS_DOMAIN}"
fi

# Dynamic Configuration Directory
DYNAMIC_DIR="/etc/halos/traefik-dynamic.d"
DYNAMIC_SRC_DIR="${SCRIPT_DIR}/assets/traefik/dynamic"
mkdir -p "${DYNAMIC_DIR}"

# Generate dynamic TLS configuration
TLS_CONFIG_FILE="${DYNAMIC_DIR}/tls-default.yml"
cat > "${TLS_CONFIG_FILE}" << EOF
# Default TLS certificate configuration
# Auto-generated by halos-core-containers prestart
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /certs/halos.crt
        keyFile: /certs/halos.key
EOF
chmod 644 "${TLS_CONFIG_FILE}"

# Generate Cockpit path redirect configuration
# Cockpit has native HTTPS on port 9090 — just a path redirect for discoverability.
# Path-only routing: any inbound Host on /cockpit/* is redirected, the regex
# capture preserves Host. Auth still gates on Cockpit's own ForwardAuth at :9090.
COCKPIT_CONFIG_FILE="${DYNAMIC_DIR}/cockpit.yml"
cat > "${COCKPIT_CONFIG_FILE}" << EOF
# Cockpit path redirect — /cockpit/ → :9090
# Auto-generated by halos-core-containers prestart
http:
  routers:
    cockpit-redirect:
      rule: "PathPrefix(\`/cockpit/\`)"
      entrypoints:
        - websecure
      tls: {}
      middlewares:
        - cockpit-redirect
      service: noop@internal
      priority: 100
    cockpit-redirect-bare:
      rule: "Path(\`/cockpit\`)"
      entrypoints:
        - websecure
      tls: {}
      middlewares:
        - cockpit-add-slash
      service: noop@internal
      priority: 101
    cockpit-redirect-http:
      rule: "PathPrefix(\`/cockpit/\`)"
      entrypoints:
        - web
      middlewares:
        - redirect-to-https
      service: noop@internal
      priority: 100
    cockpit-redirect-bare-http:
      rule: "Path(\`/cockpit\`)"
      entrypoints:
        - web
      middlewares:
        - redirect-to-https
      service: noop@internal
      priority: 101
  middlewares:
    cockpit-redirect:
      redirectRegex:
        regex: "^https://([^/]+)/cockpit/(.*)"
        replacement: "https://\${1}:9090/\${2}"
        permanent: false
    cockpit-add-slash:
      redirectRegex:
        regex: "^https://([^/]+)/cockpit$"
        replacement: "https://\${1}/cockpit/"
        permanent: false
EOF
chmod 644 "${COCKPIT_CONFIG_FILE}"

# Authelia routing is done via Docker labels in docker-compose.yml (PathPrefix /sso/)

# Install dynamic config files from package
if [ -d "${DYNAMIC_SRC_DIR}" ]; then
    for src_file in "${DYNAMIC_SRC_DIR}"/*.yml; do
        if [ -f "${src_file}" ]; then
            filename=$(basename "${src_file}")
            dest_file="${DYNAMIC_DIR}/${filename}"
            if [ ! -f "${dest_file}" ]; then
                echo "Installing dynamic config: ${filename}"
                cp "${src_file}" "${dest_file}"
                chmod 644 "${dest_file}"
            fi
        fi
    done
fi

# Localhost redirect configuration
# Redirects http(s)://localhost to https://${HALOS_DOMAIN}
LOCALHOST_REDIRECT_FILE="${DYNAMIC_DIR}/localhost-redirect.yml"
cat > "${LOCALHOST_REDIRECT_FILE}" << EOF
# Localhost to mDNS redirect
# Auto-generated by halos-core-containers prestart
http:
  routers:
    localhost-http:
      rule: "Host(\`localhost\`)"
      entrypoints:
        - web
      middlewares:
        - localhost-to-mdns
      service: noop@internal
      priority: 1000

    localhost-https:
      rule: "Host(\`localhost\`)"
      entrypoints:
        - websecure
      middlewares:
        - localhost-to-mdns
      service: noop@internal
      priority: 1000
      tls: {}

  middlewares:
    localhost-to-mdns:
      redirectRegex:
        regex: "^https?://localhost(.*)"
        replacement: "https://${HALOS_DOMAIN}\${1}"
        permanent: false
EOF
chmod 644 "${LOCALHOST_REDIRECT_FILE}"

echo "Traefik setup complete"

# ============================================
# Homarr OIDC Client Setup (before Authelia merge)
# ============================================
echo ""
echo "=== Homarr OIDC Setup ==="

OIDC_CLIENTS_DIR="/etc/halos/oidc-clients.d"
OIDC_SECRET_FILE="${HOMARR_DATA}/oidc-secret"
OIDC_SNIPPET_SRC="${SCRIPT_DIR}/assets/homarr/oidc-client.yml"
OIDC_SNIPPET_DST="${OIDC_CLIENTS_DIR}/homarr.yml"

mkdir -p "${OIDC_CLIENTS_DIR}"

# Generate OIDC client secret if it doesn't exist
if [ ! -f "${OIDC_SECRET_FILE}" ]; then
    echo "Generating OIDC client secret..."
    openssl rand -hex 32 > "${OIDC_SECRET_FILE}"
    chmod 600 "${OIDC_SECRET_FILE}"
fi
OIDC_CLIENT_SECRET=$(cat "${OIDC_SECRET_FILE}")

# Install OIDC client snippet
if [ -f "${OIDC_SNIPPET_SRC}" ]; then
    echo "Installing OIDC client snippet to ${OIDC_SNIPPET_DST}"
    cp "${OIDC_SNIPPET_SRC}" "${OIDC_SNIPPET_DST}"
    chmod 644 "${OIDC_SNIPPET_DST}"
fi

# Configure Homarr SSO environment
ENV_FILE="${ETC_DIR}/env"

# Generate SECRET_ENCRYPTION_KEY if not set
if [ -z "$SECRET_ENCRYPTION_KEY" ]; then
    echo "Generating SECRET_ENCRYPTION_KEY..."
    SECRET_ENCRYPTION_KEY=$(openssl rand -hex 32)
    echo "SECRET_ENCRYPTION_KEY=\"${SECRET_ENCRYPTION_KEY}\"" >> "${ENV_FILE}"
fi

# Generate AUTH_SECRET for NextAuth.js
if ! grep -qE "^AUTH_SECRET=\"[^\"]+\"" "${ENV_FILE}" 2>/dev/null; then
    echo "Generating AUTH_SECRET..."
    AUTH_SECRET=$(openssl rand -hex 32)
    echo "AUTH_SECRET=\"${AUTH_SECRET}\"" >> "${ENV_FILE}"
fi

# Set OIDC configuration for Homarr
declare -A HOMARR_SSO_CONFIG=(
    ["AUTH_PROVIDERS"]="oidc"
    ["AUTH_OIDC_ISSUER"]="https://${HALOS_DOMAIN}/sso"
    ["AUTH_OIDC_CLIENT_ID"]="homarr"
    ["AUTH_OIDC_CLIENT_SECRET"]="${OIDC_CLIENT_SECRET}"
    ["AUTH_OIDC_CLIENT_NAME"]="HaLOS"
    ["AUTH_OIDC_SCOPE_OVERWRITE"]="openid profile email groups"
    ["AUTH_LOGOUT_REDIRECT_URL"]="https://${HALOS_DOMAIN}/sso/logout"
    ["AUTH_OIDC_FORCE_USERINFO"]="true"
    ["AUTH_OIDC_ENABLE_DANGEROUS_ACCOUNT_LINKING"]="true"
)

# Always update all OIDC keys so that URL changes (e.g., routing scheme
# migration) take effect on existing installs without manual intervention.
for key in "${!HOMARR_SSO_CONFIG[@]}"; do
    if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${HOMARR_SSO_CONFIG[$key]}\"|" "${ENV_FILE}"
    else
        echo "${key}=\"${HOMARR_SSO_CONFIG[$key]}\"" >> "${ENV_FILE}"
    fi
done

echo "Homarr OIDC setup complete"

# ============================================
# Authelia Setup
# ============================================
echo ""
echo "=== Authelia Setup ==="

AUTHELIA_SECRETS_FILE="${AUTHELIA_DATA}/secrets.env"
AUTHELIA_CONFIG_FILE="${AUTHELIA_DATA}/configuration.yml"
AUTHELIA_OIDC_FILE="${AUTHELIA_DATA}/oidc-clients.yml"
AUTHELIA_TEMPLATE="${SCRIPT_DIR}/assets/authelia/configuration.yml.template"

# Generate Authelia secrets on first boot
if [ ! -f "${AUTHELIA_SECRETS_FILE}" ]; then
    echo "Generating Authelia secrets..."
    SESSION_SECRET=$(openssl rand -hex 32)
    OIDC_HMAC_SECRET=$(openssl rand -hex 32)
    STORAGE_ENCRYPTION_KEY=$(openssl rand -hex 32)
    RESET_PASSWORD_JWT_SECRET=$(openssl rand -hex 32)
    REDIS_PASSWORD=$(openssl rand -hex 32)
    OIDC_PRIVATE_KEY=$(openssl genrsa 4096 2>/dev/null)

    cat > "${AUTHELIA_SECRETS_FILE}" << EOF
SESSION_SECRET="${SESSION_SECRET}"
OIDC_HMAC_SECRET="${OIDC_HMAC_SECRET}"
STORAGE_ENCRYPTION_KEY="${STORAGE_ENCRYPTION_KEY}"
RESET_PASSWORD_JWT_SECRET="${RESET_PASSWORD_JWT_SECRET}"
REDIS_PASSWORD="${REDIS_PASSWORD}"
EOF
    echo "${OIDC_PRIVATE_KEY}" > "${AUTHELIA_DATA}/oidc_private_key.pem"
    chmod 600 "${AUTHELIA_SECRETS_FILE}" "${AUTHELIA_DATA}/oidc_private_key.pem"
    echo "Authelia secrets generated"
fi

# Migration: Add REDIS_PASSWORD to existing secrets file if missing
if ! grep -q "^REDIS_PASSWORD=" "${AUTHELIA_SECRETS_FILE}" 2>/dev/null; then
    echo "Adding REDIS_PASSWORD to existing secrets..."
    REDIS_PASSWORD=$(openssl rand -hex 32)
    echo "REDIS_PASSWORD=\"${REDIS_PASSWORD}\"" >> "${AUTHELIA_SECRETS_FILE}"
fi

# Load secrets
. "${AUTHELIA_SECRETS_FILE}"
OIDC_PRIVATE_KEY=$(cat "${AUTHELIA_DATA}/oidc_private_key.pem")

# Hash a plaintext secret using Authelia's CLI
hash_client_secret() {
    local plaintext="$1"
    local hash_output
    hash_output=$(docker run --rm authelia/authelia:4.39 authelia crypto hash generate pbkdf2 \
        --variant sha512 \
        --password "${plaintext}" 2>/dev/null)
    if [ $? -ne 0 ]; then
        return 1
    fi
    echo "$hash_output" | grep 'Digest:' | sed 's/Digest: //'
}

# Merge OIDC client snippets from .d directory
merge_oidc_clients() {
    echo "Merging OIDC client snippets..."
    local client_count=0
    local clients_yaml=""

    for snippet in "${OIDC_CLIENTS_DIR}"/*.yml; do
        [ -e "$snippet" ] || continue
        local snippet_name=$(basename "$snippet")
        echo "  Processing: ${snippet_name}"

        # Read fields from snippet
        local client_id=$(grep -E '^client_id:' "$snippet" | sed 's/client_id:[[:space:]]*//' | tr -d "'\"")
        local client_name=$(grep -E '^client_name:' "$snippet" | sed 's/client_name:[[:space:]]*//' | tr -d "'\"")
        local client_secret_file=$(grep -E '^client_secret_file:' "$snippet" | sed 's/client_secret_file:[[:space:]]*//' | tr -d "'\"")
        local consent_mode=$(grep -E '^consent_mode:' "$snippet" | sed 's/consent_mode:[[:space:]]*//' | tr -d "'\"")
        local token_auth_method=$(grep -E '^token_endpoint_auth_method:' "$snippet" | sed 's/token_endpoint_auth_method:[[:space:]]*//' | tr -d "'\"")

        [ -z "$client_id" ] && { echo "  WARNING: Skipping ${snippet_name} - missing client_id"; continue; }

        # Read and hash client secret
        local client_secret_hash=""
        if [ -n "$client_secret_file" ] && [ -f "$client_secret_file" ]; then
            local plaintext_secret=$(cat "$client_secret_file")
            if ! client_secret_hash=$(hash_client_secret "$plaintext_secret"); then
                echo "  ERROR: Failed to hash client secret for ${snippet_name}"
                continue
            fi
        else
            echo "  WARNING: Skipping ${snippet_name} - client_secret_file not found: ${client_secret_file}"
            continue
        fi

        # Extract redirect_uris and expand ${HALOS_DOMAIN} placeholder
        # to one URI per configured DNS hostname (IPs excluded — see
        # halos_expand_oidc_redirect_uri in lib-hostnames.sh).
        local redirect_uris=""
        local in_redirect=false
        while IFS= read -r line; do
            if echo "$line" | grep -qE '^redirect_uris:'; then
                in_redirect=true
                continue
            fi
            if $in_redirect; then
                if echo "$line" | grep -qE '^[[:space:]]+-'; then
                    local uri
                    uri=$(echo "$line" | sed "s/^[[:space:]]*-[[:space:]]*//" | tr -d "'\"")
                    while IFS= read -r expanded_uri; do
                        [ -z "$expanded_uri" ] && continue
                        redirect_uris="${redirect_uris}          - '${expanded_uri}'\n"
                    done < <(halos_expand_oidc_redirect_uri "$uri")
                elif echo "$line" | grep -qE '^[a-z_]+:'; then
                    break
                fi
            fi
        done < "$snippet"

        # Extract scopes
        local scopes_line=$(grep -E '^scopes:' "$snippet")
        local scopes=""
        if echo "$scopes_line" | grep -qE '\[.*\]'; then
            scopes=$(echo "$scopes_line" | sed 's/scopes:[[:space:]]*//')
        else
            scopes="[openid, profile, email]"
        fi

        # Build client YAML
        clients_yaml="${clients_yaml}      - client_id: ${client_id}
        client_name: '${client_name:-${client_id}}'
        client_secret: '${client_secret_hash}'
        public: false
        authorization_policy: one_factor
        redirect_uris:
$(echo -e "${redirect_uris}" | sed '/^$/d')
        scopes: ${scopes}
        consent_mode: ${consent_mode:-implicit}
        token_endpoint_auth_method: ${token_auth_method:-client_secret_post}
"
        client_count=$((client_count + 1))
    done

    if [ $client_count -eq 0 ]; then
        echo "  No OIDC client snippets found - OIDC will be disabled"
        cat > "${AUTHELIA_OIDC_FILE}" << 'EOF'
# Authelia OIDC Configuration - No clients configured
EOF
    else
        echo "  Merged ${client_count} OIDC client(s)"
        local indented_key
        indented_key=$(echo "${OIDC_PRIVATE_KEY}" | awk 'NR==1 {print} NR>1 {print "          " $0}')

        cat > "${AUTHELIA_OIDC_FILE}" << EOF
# Authelia OIDC Configuration
# Auto-generated by halos-core-containers prestart
identity_providers:
  oidc:
    hmac_secret: '${OIDC_HMAC_SECRET}'
    jwks:
      - key: |
          ${indented_key}
    clients:
${clients_yaml}
EOF
    fi
    chmod 600 "${AUTHELIA_OIDC_FILE}"
}

# Process Authelia configuration template
process_authelia_template() {
    echo "Processing Authelia configuration template..."
    local template
    template=$(cat "${AUTHELIA_TEMPLATE}")

    local indented_key
    indented_key=$(echo "${OIDC_PRIVATE_KEY}" | awk 'NR==1 {print} NR>1 {print "          " $0}')

    # Build session.cookies block — one entry per configured multi-label
    # DNS hostname. Two exclusions:
    #
    # 1. IP entries: RFC 6265 forbids the Domain cookie attribute from
    #    being an IP literal; browsers silently drop any Set-Cookie
    #    scoped to an IP address. (Already excluded by reading from
    #    halos_dns_hostnames, which only emits DNS entries.)
    #
    # 2. Single-label DNS entries (e.g., bare `halosdev`): Authelia 4.39+
    #    rejects them at config-load time with "must have at least a
    #    single period or be an ip address", which matches RFC 6265 §5.3
    #    step 5 (single-label Domain attributes are ignored by user
    #    agents anyway). Bare hostnames remain valid as cert SANs and
    #    as Traefik path-only matchers — users accessing via bare host
    #    just won't have an SSO session cookie scoped to that name.
    #
    # Each entry's authelia_url matches its own domain because Authelia
    # validates that the ForwardAuth redirect URL shares a cookie scope
    # with the cookie domain. The OIDC single-canonical concern is
    # separate: AUTH_OIDC_ISSUER and the discovery-served
    # authorization_endpoint stay bound to the canonical hostname via
    # Homarr's environment.
    local cookies_block=""
    while IFS= read -r host; do
        [ -z "$host" ] && continue
        # Skip single-label hostnames — Authelia rejects them as cookie domains.
        case "$host" in
            *.*) ;;
            *) continue ;;
        esac
        cookies_block+="    - domain: '${host}'"$'\n'
        cookies_block+="      authelia_url: 'https://${host}/sso'"$'\n'
        cookies_block+="      default_redirection_url: 'https://${host}'"$'\n'
    done < <(halos_dns_hostnames)
    cookies_block="${cookies_block%$'\n'}"
    if [ -z "$cookies_block" ]; then
        # Every DNS entry was filtered (admin-pinned single-label config or
        # similar pathological case). An empty cookies: block in Authelia's
        # config makes it crash-loop at startup. Synthesize a fallback entry
        # from the always-multi-label mDNS canonical so the device boots and
        # the operator can see the misconfiguration via working access on
        # ${hostname}.local rather than via container logs only.
        local _fallback_canonical
        _fallback_canonical="$(_halos_short_hostname).local"
        echo "WARN: hostnames.conf produced no multi-label DNS entries for Authelia cookies; falling back to ${_fallback_canonical}" >&2
        cookies_block+="    - domain: '${_fallback_canonical}'"$'\n'
        cookies_block+="      authelia_url: 'https://${_fallback_canonical}/sso'"$'\n'
        cookies_block+="      default_redirection_url: 'https://${_fallback_canonical}'"
    fi

    # Substitute the marker first so ${HALOS_DOMAIN} inside rendered
    # cookies is caught by the global pass. Single-shot bash replacement
    # is used here (rather than awk -v) because mawk/awk implementations
    # vary on whether -v values may contain newlines.
    local cookies_marker='    ### HALOS_SESSION_COOKIES ###'
    if [[ "${template}" != *"${cookies_marker}"* ]]; then
        echo "ERROR: Authelia template missing HALOS_SESSION_COOKIES marker" >&2
        return 1
    fi
    template="${template/${cookies_marker}/${cookies_block}}"

    template="${template//\$\{SESSION_SECRET\}/${SESSION_SECRET}}"
    template="${template//\$\{OIDC_HMAC_SECRET\}/${OIDC_HMAC_SECRET}}"
    template="${template//\$\{STORAGE_ENCRYPTION_KEY\}/${STORAGE_ENCRYPTION_KEY}}"
    template="${template//\$\{RESET_PASSWORD_JWT_SECRET\}/${RESET_PASSWORD_JWT_SECRET}}"
    template="${template//\$\{REDIS_PASSWORD\}/${REDIS_PASSWORD}}"
    template="${template//\$\{HALOS_DOMAIN\}/${HALOS_DOMAIN}}"

    echo "${template}" | awk -v key="${indented_key}" '
        /\$\{OIDC_PRIVATE_KEY\}/ { sub(/\$\{OIDC_PRIVATE_KEY\}/, key) }
        { print }
    ' > "${AUTHELIA_CONFIG_FILE}"

    chmod 600 "${AUTHELIA_CONFIG_FILE}"
    echo "Authelia configuration generated"
}

process_authelia_template
merge_oidc_clients

# Write Redis password to runtime environment for docker-compose
echo "REDIS_PASSWORD=${REDIS_PASSWORD}" >> "${RUNTIME_ENV}"

# Create initial admin user if not exists
if [ ! -f "${AUTHELIA_DATA}/users_database.yml" ]; then
    echo "Creating initial admin user..."
    DEFAULT_PASSWORD="halos"
    INITIAL_HASH=$(docker run --rm authelia/authelia:4.39 authelia crypto hash generate argon2 \
        --password "${DEFAULT_PASSWORD}" 2>/dev/null | grep 'Digest:' | sed 's/Digest: //')

    if [ -z "${INITIAL_HASH}" ]; then
        echo "ERROR: Failed to generate password hash"
        exit 1
    fi

    cat > "${AUTHELIA_DATA}/users_database.yml" << EOF
# Authelia Users Database
# Default admin password is "halos" - please change after first login
users:
  admin:
    displayname: "Administrator"
    email: admin@${HALOS_DOMAIN}
    password: "${INITIAL_HASH}"
    groups:
      - admins
EOF
    chmod 600 "${AUTHELIA_DATA}/users_database.yml"
    echo "Created admin user with default password 'halos'"
fi

echo "Authelia setup complete"

# ============================================
# Homarr Database Initialization
# ============================================
echo ""
echo "=== Homarr Database Setup ==="

SEED_DB="/var/lib/halos-homarr-branding/db-seed.sqlite3"
HOMARR_DB="${HOMARR_DATA}/data/db/db.sqlite"

if [ ! -f "$HOMARR_DB" ] && [ -f "$SEED_DB" ]; then
    echo "Initializing Homarr database from seed..."
    mkdir -p "$(dirname "$HOMARR_DB")"
    cp "$SEED_DB" "$HOMARR_DB"
    chmod 644 "$HOMARR_DB"
    echo "Homarr database initialized"
else
    echo "Homarr database already exists or no seed available"
fi

echo ""
echo "=== HaLOS Core Containers prestart complete ==="
