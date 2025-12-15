#!/bin/sh
# Custom entrypoint that patches Homarr's nginx to serve local assets
# This eliminates the need for a separate asset-server container
#
# The patch adds location blocks for:
# - /icons/ -> /usr/share/pixmaps/ (system icons)
# - /branding/ -> /usr/share/halos-homarr-branding/ (HaLOS branding)
# - /<app>/assets/ -> /var/lib/container-apps/<app>/assets/ (per-container assets)

set -e

TEMPLATE="/etc/nginx/templates/nginx.conf"

# Patch nginx template (idempotent - only runs if not already patched)
if [ -f "$TEMPLATE" ] && ! grep -q "location /icons/" "$TEMPLATE"; then
    echo "Patching nginx template to serve local assets..."

    # Use awk to insert location blocks before "location / {"
    awk '
    /location \/ \{/ {
        print ""
        print "        # HaLOS: Serve system icons from /usr/share/pixmaps"
        print "        location /icons/ {"
        print "            alias /usr/share/pixmaps/;"
        print "            expires 1d;"
        print "            add_header Cache-Control \"public, immutable\";"
        print "        }"
        print ""
        print "        # HaLOS: Serve branding assets"
        print "        location /branding/ {"
        print "            alias /usr/share/halos-homarr-branding/;"
        print "            expires 1d;"
        print "            add_header Cache-Control \"public, immutable\";"
        print "        }"
        print ""
        print "        # HaLOS: Serve per-container assets"
        print "        location ~ ^/([^/]+)/assets/(.*)$ {"
        print "            alias /var/lib/container-apps/$1/assets/$2;"
        print "            expires 1d;"
        print "            add_header Cache-Control \"public\";"
        print "        }"
        print ""
    }
    { print }
    ' "$TEMPLATE" > "${TEMPLATE}.tmp" && mv "${TEMPLATE}.tmp" "$TEMPLATE"

    echo "Nginx template patched successfully"
fi

# Call original Homarr entrypoint
exec /app/entrypoint.sh "$@"
