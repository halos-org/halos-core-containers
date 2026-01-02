#!/bin/bash
# Build halos-core-containers Debian package

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${REPO_ROOT}/build"

echo "Building halos-core-containers package..."
echo "Repository root: $REPO_ROOT"
echo "Build directory: $BUILD_DIR"

cd "$REPO_ROOT"

# Read version from VERSION file
if [ ! -f VERSION ]; then
    echo "ERROR: VERSION file not found"
    exit 1
fi
VERSION=$(cat VERSION)
echo "Package version: $VERSION"

# Generate changelog only if not already present (CI generates it with correct revision)
if [ ! -f debian/changelog ]; then
    echo "Generating debian/changelog..."
    .github/scripts/generate-changelog.sh --upstream "$VERSION" --revision 1
else
    echo "Using existing debian/changelog"
fi

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build the package
echo ""
echo "=== Building Debian package ==="
dpkg-buildpackage -b -us -uc

# Move artifacts to build directory
echo ""
echo "=== Moving artifacts to build directory ==="
mv ../*.deb "$BUILD_DIR/" 2>/dev/null || true
mv ../*.buildinfo "$BUILD_DIR/" 2>/dev/null || true
mv ../*.changes "$BUILD_DIR/" 2>/dev/null || true

# List built packages
echo ""
echo "=== Built packages ==="
ls -lh "$BUILD_DIR"/*.deb 2>/dev/null || echo "No .deb files found"

echo ""
echo "Build complete! Packages are in: $BUILD_DIR"
