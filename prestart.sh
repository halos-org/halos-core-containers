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

# HALOS_DOMAIN (the canonical hostname / OIDC issuer) is resolved once by
# halos-resolve-domain.service and provided to this unit via
# EnvironmentFile=/run/halos/domain.env. We consume it from the environment
# rather than deriving it here, so there is a single canonical-hostname
# resolver and no stale-EnvironmentFile feedback loop (we never write
# HALOS_DOMAIN back into runtime.env).
#
# The hostname *list* is still loaded here: the Authelia per-hostname
# session.cookies block and the OIDC redirect_uris expansion below iterate
# HALOS_HOSTNAMES_DNS[] (via halos_dns_hostnames / halos_expand_oidc_redirect_uri
# / _halos_short_hostname), which the canonical-only domain.env does not carry.
LIB_HOSTNAMES="/usr/lib/halos-core-containers/lib-hostnames.sh"
if [ ! -f "$LIB_HOSTNAMES" ]; then
    # Source from package assets when running uninstalled (development).
    LIB_HOSTNAMES="${SCRIPT_DIR}/assets/lib-hostnames.sh"
fi
# shellcheck source=assets/lib-hostnames.sh
. "$LIB_HOSTNAMES"
halos_load_hostnames

# The OIDC client merger is shared with /usr/bin/reload-oidc-clients so a
# boot-time render and a hot reload can never disagree.
LIB_OIDC_CLIENTS="/usr/lib/halos-core-containers/lib-oidc-clients.sh"
if [ ! -f "$LIB_OIDC_CLIENTS" ]; then
    LIB_OIDC_CLIENTS="${SCRIPT_DIR}/assets/lib-oidc-clients.sh"
fi
# shellcheck source=assets/lib-oidc-clients.sh
. "$LIB_OIDC_CLIENTS"

HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname | cut -d. -f1)

# Write common runtime environment
cat > "${RUNTIME_ENV}" << EOF
HOSTNAME=${HOSTNAME_SHORT}
EOF

# An empty HALOS_DOMAIN renders into the OIDC issuer, Authelia's cookie domain
# and Traefik's redirects, producing a stack that looks healthy and whose every
# login fails. Since the resolver is only wanted by this unit, not required, the
# stack now starts even when it failed, so refuse here instead.
#
# The resolver's file is checked, not just the variable: /run is tmpfs so a
# stale domain.env cannot outlive a reboot, but an in-place upgrade can leave a
# pre-upgrade HALOS_DOMAIN in runtime.env, which must not satisfy this.
#
# Both units retry with backoff, so a transient resolver failure heals without
# help: the resolver republishes and a later retry here picks it up.
if [ ! -s /run/halos/domain.env ] || [ -z "${HALOS_DOMAIN:-}" ]; then
    echo "HALOS_DOMAIN_UNSET: halos-resolve-domain.service has not published /run/halos/domain.env" >&2
    exit 1
fi

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

# TLS leaf + CA artifacts are provisioned by a separate unit; see docs/CERTS.md.

# The ca-download sidecar bind-mounts the adoption sentinel as a *file*, and
# halos-manage-certs.service is what normally creates it — but the stack only
# Wants= that unit now, so a failed cert run would let Docker create a directory
# at the mount source instead. lib-ca.sh then repairs the host path on its next
# successful run while the running sidecar keeps the removed inode mounted, so
# adoption is never recorded and the CN-refresh gate can orphan a trust anchor
# the operator already installed. Guarantee the file here, with the same call
# the cert manager makes: an existing sentinel is preserved verbatim, and with
# no auto-CA yet the value is the documented fail-safe ("adopted", CN frozen).
LIB_CA="/usr/lib/halos-core-containers/lib-ca.sh"
if [ ! -f "$LIB_CA" ]; then
    LIB_CA="${SCRIPT_DIR}/assets/lib-ca.sh"
fi
# shellcheck source=assets/lib-ca.sh
. "$LIB_CA"
AUTO_CA_DIR="${CONTAINER_DATA_ROOT}/${PACKAGE_NAME}/certs/ca"
halos_ca_adoption_init "${AUTO_CA_DIR}/adoption" "${AUTO_CA_DIR}/ca.crt" 0
chown "${HALOS_CA_DOWNLOAD_UID}:${HALOS_CA_DOWNLOAD_UID}" "${AUTO_CA_DIR}/adoption" 2>/dev/null || true

# Dynamic Configuration Directory
DYNAMIC_DIR="/etc/halos/traefik-dynamic.d"
DYNAMIC_SRC_DIR="${SCRIPT_DIR}/assets/traefik/dynamic"
mkdir -p "${DYNAMIC_DIR}"

# Generate dynamic TLS configuration.
#
# IMPORTANT: assets/halos-manage-certs hardcodes the filename "tls-default.yml"
# in TRAEFIK_TLS_CONFIG and touches it on leaf rotation to force Traefik's
# file-watcher to re-read the cert. Renaming this file requires updating that
# script as well, or rotation-driven cert reload silently falls into the
# "Skipping Traefik cert reload" branch and Traefik keeps serving the stale
# leaf until the next halos-core-containers.service restart.
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
            echo "Installing dynamic config: ${filename}"
            cp "${src_file}" "${dest_file}"
            chmod 644 "${dest_file}"
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

# Process Authelia configuration template
process_authelia_template() {
    echo "Processing Authelia configuration template..."
    local template
    template=$(cat "${AUTHELIA_TEMPLATE}")

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
    template="${template//\$\{STORAGE_ENCRYPTION_KEY\}/${STORAGE_ENCRYPTION_KEY}}"
    template="${template//\$\{RESET_PASSWORD_JWT_SECRET\}/${RESET_PASSWORD_JWT_SECRET}}"
    template="${template//\$\{REDIS_PASSWORD\}/${REDIS_PASSWORD}}"
    template="${template//\$\{HALOS_DOMAIN\}/${HALOS_DOMAIN}}"

    printf '%s\n' "${template}" > "${AUTHELIA_CONFIG_FILE}"

    chmod 600 "${AUTHELIA_CONFIG_FILE}"

    # The hostname list this config's session.cookies block was built from.
    # reload-oidc-clients expands redirect_uris against it rather than against a
    # live resolution, so the two halves of Authelia's config cannot disagree
    # between stack starts.
    halos_dns_hostnames > "${AUTHELIA_DATA}/hostnames.snapshot"

    echo "Authelia configuration generated"
}

process_authelia_template
# A failed merge keeps the previous registration and is not worth refusing to
# boot over: the stack coming up with a stale client list beats the stack not
# coming up at all. halos-oidc-clients-reload.service runs after this unit
# reaches active and retries, so the failure is not terminal.
if halos_oidc_merge_clients; then
    if [ "${HALOS_OIDC_CHANGED}" -eq 1 ]; then
        # Nothing to apply separately: the containers start immediately after.
        halos_oidc_commit
    else
        echo "OIDC client registration already current"
    fi
else
    echo "WARNING: OIDC client merge failed - Authelia keeps its previous client registration" >&2
fi

# Write Redis password to runtime environment for docker-compose
echo "REDIS_PASSWORD=${REDIS_PASSWORD}" >> "${RUNTIME_ENV}"

# Create initial admin user if not exists
if [ ! -f "${AUTHELIA_DATA}/users_database.yml" ]; then
    echo "Creating initial admin user..."
    DEFAULT_PASSWORD="halos"
    # Plaintext through the environment, not argv: /proc/<pid>/cmdline is
    # world-readable, and this is the pattern _halos_oidc_hash_secret uses for
    # the same CLI. Docker's own output is kept: without it an unreachable
    # registry, a rate-limited pull and a stopped daemon all reduce to one
    # generic line, with the whole stack down and nothing to attribute it to.
    if ! HASH_OUTPUT=$(HALOS_ADMIN_PW="${DEFAULT_PASSWORD}" docker run --rm \
        -e HALOS_ADMIN_PW "${HALOS_OIDC_AUTHELIA_IMAGE}" \
        sh -c 'authelia crypto hash generate argon2 --password "$HALOS_ADMIN_PW"' 2>&1); then
        echo "ERROR: could not generate the initial password hash" >&2
        printf 'docker: %s\n' "${HASH_OUTPUT}" >&2
        exit 1
    fi
    INITIAL_HASH=$(printf '%s\n' "${HASH_OUTPUT}" | grep 'Digest:' | sed 's/Digest: //')

    if [ -z "${INITIAL_HASH}" ]; then
        echo "ERROR: password hashing produced no digest" >&2
        printf 'docker: %s\n' "${HASH_OUTPUT}" >&2
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
