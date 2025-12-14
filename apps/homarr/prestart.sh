#!/bin/bash
# Prestart script for homarr-container
# Custom script to handle SECRET_ENCRYPTION_KEY generation and asset-server config
set -e

PACKAGE_NAME="homarr-container"
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

# Create nginx config for asset-server
NGINX_CONF="${CONTAINER_DATA_ROOT}/nginx-assets.conf"
cat > "$NGINX_CONF" << 'NGINX_EOF'
server {
    listen 80;

    # System icons from /usr/share/pixmaps
    location /icons/ {
        alias /mnt/pixmaps/;
        autoindex off;
        expires 1d;
        add_header Cache-Control "public, immutable";
    }

    # Branding assets from /usr/share/homarr-branding-halos
    location /branding/ {
        alias /mnt/branding/;
        autoindex off;
        expires 1d;
        add_header Cache-Control "public, immutable";
    }

    # Per-container assets - ONLY exposes /assets/ subdirectory
    # Example: /signalk-container/assets/bg.png -> /mnt/container-apps/signalk-container/assets/bg.png
    location ~ ^/([^/]+)/assets/(.*)$ {
        alias /mnt/container-apps/$1/assets/$2;
        autoindex off;
        expires 1d;
        add_header Cache-Control "public";
    }
}
NGINX_EOF
echo "Created nginx config at $NGINX_CONF"
