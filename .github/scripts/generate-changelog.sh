#!/bin/bash
set -euo pipefail

# Generate debian/changelog from VERSION file
# Called by CI workflow with --upstream and --revision arguments

UPSTREAM=""
REVISION="1"
PKG_NAME="halos-core-containers"
MAINTAINER="Matti Airas <matti.airas@hatlabs.fi>"

while [[ $# -gt 0 ]]; do
    case $1 in
        --upstream)
            UPSTREAM="$2"
            shift 2
            ;;
        --revision)
            REVISION="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Read upstream from VERSION if not provided
if [[ -z "$UPSTREAM" ]]; then
    if [[ -f VERSION ]]; then
        UPSTREAM=$(cat VERSION)
    else
        echo "ERROR: VERSION file not found and --upstream not provided"
        exit 1
    fi
fi

# Generate debian/changelog
mkdir -p debian

cat > debian/changelog << EOF
${PKG_NAME} (${UPSTREAM}-${REVISION}) unstable; urgency=medium

  * Automated build

 -- ${MAINTAINER}  $(date -R)
EOF

echo "Generated debian/changelog with version ${UPSTREAM}-${REVISION}"
