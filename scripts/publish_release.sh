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

VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' Kaname.xcodeproj/project.pbxproj | head -1)"
TAG="v${VERSION}"
DMG="build/Kaname-${VERSION}.dmg"
NOTES="docs/releases/${TAG}.md"

if ! gh auth status >/dev/null 2>&1; then
    echo "error: GitHub CLI is not authenticated. Run: gh auth login" >&2
    exit 1
fi

# A DMG that merely exists is not a DMG for *this* commit: the version number is what names
# the file, so an unchanged version after a fix would publish the previous build under the
# new tag. `build_release.sh` stamps its output with the version and the commit it was built
# from; anything else — no stamp, an older commit, a dirty tree — rebuilds first.
STAMP="$ROOT/build/.release-stamp"
EXPECTED="$(printf '%s %s' "$VERSION" "$(git rev-parse HEAD)")"
STAMPED="$(cat "$STAMP" 2>/dev/null || true)"
if [ ! -f "$DMG" ] || [ "$STAMPED" != "$EXPECTED" ]; then
    echo "==> $DMG is missing or stale (stamp: ${STAMPED:-none}, expected: $EXPECTED); rebuilding"
    ./scripts/build_release.sh
    STAMPED="$(cat "$STAMP" 2>/dev/null || true)"
    if [ "$STAMPED" != "$EXPECTED" ]; then
        echo "warning: the fresh DMG is stamped '$STAMPED' rather than '$EXPECTED' (uncommitted changes?); publishing it as $TAG" >&2
    fi
fi

# The notes are a per-release file when one exists (a hand-written body), and otherwise the
# commits since the previous tag: the repository keeps one merged record in docs/RELEASES.md
# rather than a file per version, so the generated body is the normal case, not a failure.
if [ ! -f "$NOTES" ]; then
    PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    NOTES="$(mktemp -t kaname-release-notes)"
    trap 'rm -f "$NOTES"' EXIT
    {
        echo "Kaname "
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
    git tag -a "$TAG" -m "Kaname $VERSION"
fi

# Repositories cloned over HTTPS need a credential helper; fall back to SSH.
git push origin "$TAG" 2>/dev/null || git push git@github.com:suliveevil/KagiPeek.git "$TAG"

ARGS=(release create "$TAG" "$DMG" --repo suliveevil/KagiPeek --title "Kaname $VERSION" --notes-file "$NOTES")
if [ "${1:-}" = "--prerelease" ]; then
    ARGS+=(--prerelease)
fi

# `gh` picks a repo from the git remotes and lands on `upstream` (Voltline/KagiPeek) when
# one exists; releases belong to this fork, so the script pins it. The .sha256 sidecar is
# what README tells users to verify against, and `release create` uploads only the DMG.
gh "${ARGS[@]}"
gh release upload "$TAG" "$DMG.sha256" --repo suliveevil/KagiPeek
