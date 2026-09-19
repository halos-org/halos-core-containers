#!/usr/bin/env bash
# Copy built packages to the checkout root.
#
# REMOVE when https://github.com/halos-org/shared-workflows/issues/49 retires
# pr-checks.yml and build-release.yml. This whole script goes, along with the
# build-deb action step that calls it; nothing else depends on it.
#
# https://github.com/halos-org/shared-workflows/issues/32: both frozen workflows
# glob *.deb at the checkout root, while build-all.sh writes to build/, so their
# lintian steps inspect nothing and report success. The guard below is the point
# -- a silent zero-package pass is what made the required check meaningless.
#
# Runs in the release path too, where rename-packages.sh clears these copies
# before collecting release assets.

set -euo pipefail

BUILD_DIR="${1:-build}"
DEST_DIR="${2:-.}"

shopt -s nullglob
debs=("${BUILD_DIR}"/*.deb)

if [ ${#debs[@]} -eq 0 ]; then
    echo "::error::no .deb in ${BUILD_DIR} — lintian would pass without checking anything" >&2
    exit 1
fi

cp "${debs[@]}" "${DEST_DIR}/"
echo "Exposed ${#debs[@]} package(s) in ${DEST_DIR}:"
printf '  %s\n' "${debs[@]}"
