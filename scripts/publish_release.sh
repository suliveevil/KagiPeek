#!/usr/bin/env bash
#
# Publishes the GitHub release for the current MARKETING_VERSION.
# Requires the GitHub CLI to be authenticated:  gh auth login
#
#   ./scripts/publish_release.sh
#   ./scripts/publish_release.sh --prerelease
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' KagiPeek.xcodeproj/project.pbxproj | head -1)"
TAG="v${VERSION}"
DMG="build/KagiPeek-${VERSION}.dmg"
NOTES="docs/releases/${TAG}.md"

if ! gh auth status >/dev/null 2>&1; then
    echo "error: GitHub CLI is not authenticated. Run: gh auth login" >&2
    exit 1
fi

if [ ! -f "$DMG" ]; then
    echo "==> $DMG missing, building it"
    ./scripts/build_release.sh
fi

if [ ! -f "$NOTES" ]; then
    echo "error: release notes not found: $NOTES" >&2
    exit 1
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "==> Tag $TAG already exists locally"
else
    git tag -a "$TAG" -m "KagiPeek $VERSION"
fi

# Repositories cloned over HTTPS need a credential helper; fall back to SSH.
git push origin "$TAG" 2>/dev/null || git push git@github.com:suliveevil/KagiPeek.git "$TAG"

ARGS=(release create "$TAG" "$DMG" --title "KagiPeek $VERSION" --notes-file "$NOTES")
if [ "${1:-}" = "--prerelease" ]; then
    ARGS+=(--prerelease)
fi

gh "${ARGS[@]}"
