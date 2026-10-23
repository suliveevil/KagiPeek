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

# The notes are a per-release file when one exists (a hand-written body), and otherwise the
# commits since the previous tag: the repository keeps one merged record in docs/RELEASES.md
# rather than a file per version, so the generated body is the normal case, not a failure.
if [ ! -f "$NOTES" ]; then
    PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    NOTES="$(mktemp -t kagipeek-release-notes)"
    trap 'rm -f "$NOTES"' EXIT
    {
        echo "KagiPeek ${VERSION}"
        echo
        if [ -n "$PREVIOUS" ]; then
            echo "## Changes since ${PREVIOUS}"
            git log --no-merges --pretty='- %s' "${PREVIOUS}..HEAD"
        else
            # No tag can reach HEAD (a squashed history, or the first release): the last 20
            # subjects are a better body than the entire history.
            echo "## Changes"
            git log --no-merges --pretty='- %s' -n 20
        fi
        echo
        echo "Full record: https://github.com/suliveevil/KagiPeek/blob/main/docs/RELEASES.md"
    } > "$NOTES"
    echo "==> No hand-written notes for $TAG; generated them from the commits"
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
