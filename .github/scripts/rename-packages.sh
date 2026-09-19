#!/bin/bash
set -euo pipefail

# Rename all .deb packages in build/ directory with distro+component suffix
# Usage: rename-packages.sh --version <debian-version> --distro <distro> --component <component>
# Example: rename-packages.sh --version 0.2.0-1 --distro trixie --component main

VERSION=""
DISTRO=""
COMPONENT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --distro)
            DISTRO="$2"
            shift 2
            ;;
        --component)
            COMPONENT="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            echo "Usage: $0 --version <version> --distro <distro> --component <component>" >&2
            exit 1
            ;;
    esac
done

if [ -z "$VERSION" ] || [ -z "$DISTRO" ] || [ -z "$COMPONENT" ]; then
    echo "Error: --version, --distro, and --component are required" >&2
    echo "Usage: $0 --version <version> --distro <distro> --component <component>" >&2
    exit 1
fi

# Clear root-level packages first. The build-deb action copies build/*.deb to
# the checkout root so the shared workflows' root-level lintian glob can see
# them (see that action's comment). Those copies are unsuffixed duplicates of
# what is about to be renamed, and the release asset glob further down
# build-release.yml is also root-level -- so leaving them would attach two .deb
# assets per release, one without the +distro+component suffix APT expects.
rm -f ./*.deb

# Rename all .deb packages in build/ directory
for deb in build/*.deb; do
    if [ -f "$deb" ]; then
        # Extract base name (without .deb extension)
        basename=$(basename "$deb" .deb)
        # Append suffix before .deb
        newname="build/${basename}+${DISTRO}+${COMPONENT}.deb"
        echo "Renaming: $(basename $deb) -> $(basename $newname)"
        mv "$deb" "$newname"
    fi
done

# Move renamed packages to root for release
mv build/*.deb ./ 2>/dev/null || true

echo "Package renaming complete"
ls -lh *.deb 2>/dev/null || echo "No .deb files found in root"
