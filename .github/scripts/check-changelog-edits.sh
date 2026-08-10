#!/usr/bin/env bash
#
# Pre-commit hook to prevent direct debian/changelog edits.
# The changelog a *release* ships is generated at build time by
# .github/scripts/generate-changelog.sh, so a hand-edit here never reaches a
# released .deb. It does still version local ./run build packages, which is how
# a dev build came to deploy as a downgrade (docs/solutions/2026-05-31-...).
#
# Bypass: SKIP_CHANGELOG_CHECK=1 git commit ...

set -o errexit
set -o pipefail
set -o nounset

# Manual override.
if [[ "${SKIP_CHANGELOG_CHECK:-}" == "1" ]]; then
    exit 0
fi

# Check if any debian/changelog files are staged
CHANGELOG_FILES=$(git diff --cached --name-only | grep -E 'debian/changelog$' || true)

if [[ -n "$CHANGELOG_FILES" ]]; then
    echo "ERROR: Direct debian/changelog edits are not allowed."
    echo ""
    echo "Staged changelog files:"
    echo "$CHANGELOG_FILES" | sed 's/^/  /'
    echo ""
    echo "Why: the changelog a release ships is written at build time by"
    echo ".github/scripts/generate-changelog.sh, so editing the tracked file"
    echo "changes nothing a released package carries. It does set the version of"
    echo "local './run build' .debs, which is how a dev build once deployed as a"
    echo "downgrade and evicted its dependents."
    echo ""
    echo "Solution: drop the edit."
    echo "  git restore --staged --worktree debian/changelog"
    echo ""
    echo "To open a new release cycle instead, run"
    echo "'./run bumpversion [patch|minor|major]', which bumps VERSION and"
    echo "commits that change -- it does not touch the changelog."
    echo ""
    echo "To override anyway (e.g. deliberately raising a local build's version"
    echo "so it installs over a released one):"
    echo "  SKIP_CHANGELOG_CHECK=1 git commit ..."
    echo ""
    exit 1
fi
