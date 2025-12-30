#!/bin/bash
# Build all container app packages (no store package for core apps)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${REPO_ROOT}/build"

echo "Building all core container packages..."
echo "Repository root: $REPO_ROOT"
echo "Build directory: $BUILD_DIR"

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build container app packages using container-packaging-tools
if command -v uvx >/dev/null 2>&1; then
    echo ""
    echo "=== Building container app packages ==="

    # Determine tools source: local path, git ref, or default
    TOOLS_PATH="${CONTAINER_TOOLS_PATH:-}"
    TOOLS_REF="${CONTAINER_TOOLS_REF:-}"
    if [ -n "$TOOLS_PATH" ]; then
        TOOLS_SOURCE="$TOOLS_PATH"
        echo "Using local container-packaging-tools from: $TOOLS_PATH"
    elif [ -n "$TOOLS_REF" ]; then
        TOOLS_SOURCE="git+https://github.com/hatlabs/container-packaging-tools.git@${TOOLS_REF}"
        echo "Using container-packaging-tools ref: $TOOLS_REF"
    else
        TOOLS_SOURCE="git+https://github.com/hatlabs/container-packaging-tools.git"
        echo "Using container-packaging-tools from main branch"
    fi

    for app_dir in "${REPO_ROOT}/apps"/*; do
        if [ -d "$app_dir" ]; then
            app_name=$(basename "$app_dir")
            echo "Building package for: $app_name"
            if ! uvx --from "$TOOLS_SOURCE" \
                     generate-container-packages -o "$BUILD_DIR" --prefix halos "$app_dir"; then
                echo "ERROR: Failed to build package for $app_name" >&2
                exit 1
            fi
        fi
    done
else
    echo ""
    echo "WARNING: uvx not installed"
    echo "Install with: pip install uv"
    echo "Skipping container app package generation"
    exit 1
fi

# List built packages
echo ""
echo "=== Built packages ==="
ls -lh "$BUILD_DIR"/*.deb 2>/dev/null || echo "No .deb files found"

echo ""
echo "Build complete! Packages are in: $BUILD_DIR"
