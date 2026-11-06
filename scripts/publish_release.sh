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
        echo "Kaname ${VERSION}"
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
        echo "Full record: https://github.com/suliveevil/kaname/blob/main/docs/RELEASES.md"
    } > "$NOTES"
    echo "==> No hand-written notes for $TAG; generated them from the commits"
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "==> Tag $TAG already exists locally"
else
    git tag -a "$TAG" -m "Kaname $VERSION"
fi

# Repositories cloned over HTTPS need a credential helper; fall back to SSH.
git push origin "$TAG" 2>/dev/null || git push git@github.com:suliveevil/kaname.git "$TAG"

ARGS=(release create "$TAG" "$DMG" --repo suliveevil/kaname --title "Kaname $VERSION" --notes-file "$NOTES")
if [ "${1:-}" = "--prerelease" ]; then
    ARGS+=(--prerelease)
fi

# `gh` picks a repo from the git remotes and can land on the Voltline/Kaname remote when
# one exists; releases belong to the Kaname repository, so the script pins it. The .sha256
# sidecar is what README tells users to verify against, and `release create` uploads only
# the DMG.
gh "${ARGS[@]}"
gh release upload "$TAG" "$DMG.sha256" --repo suliveevil/kaname

# --- Homebrew cask ------------------------------------------------------------
# The cask points at the release asset, so the tap commit must come *after* both
# uploads: pushing it first makes every `brew install` a 404 until the asset lands.
# The rendered cask goes to build/kaname.rb; Distribution/kaname.rb stays a template
# so a tag never depends on a file that has to be edited after the tag is made.
if [ ! -f "$DMG.sha256" ]; then
    echo "error: $DMG.sha256 is missing; cannot render the cask" >&2
    exit 1
fi
SHA256="$(awk '{print $1}' "$DMG.sha256")"
case "$SHA256" in
    *[!0-9a-fA-F]*|"") echo "error: $DMG.sha256 does not contain a hex digest" >&2; exit 1 ;;
esac
if [ "${#SHA256}" -ne 64 ]; then
    echo "error: digest in $DMG.sha256 is ${#SHA256} characters, expected 64" >&2
    exit 1
fi

CASK_SRC="$ROOT/Distribution/kaname.rb"
CASK_OUT="$ROOT/build/kaname.rb"
if [ ! -f "$CASK_SRC" ]; then
    echo "error: cask template not found: $CASK_SRC" >&2
    exit 1
fi
mkdir -p "$ROOT/build"
# The template carries a block of notes that would be wrong in the tap ("this file is a
# template and must never be pushed"): it is stripped here rather than kept in a file that
# is *only* read inside this repository.
sed -e "s|__VERSION__|$VERSION|g" -e "s|__SHA256__|$SHA256|g" \
    -e '/^# TEMPLATE-ONLY-BEGIN$/,/^# TEMPLATE-ONLY-END$/d' "$CASK_SRC" > "$CASK_OUT"
if grep -q '__VERSION__\|__SHA256__' "$CASK_OUT"; then
    echo "error: rendering $CASK_OUT left a placeholder in place" >&2
    exit 1
fi
if grep -q 'TEMPLATE-ONLY' "$CASK_OUT"; then
    echo "error: rendering $CASK_OUT left a template-only block in place" >&2
    exit 1
fi
echo "==> Rendered cask: $CASK_OUT (version $VERSION, sha256 $SHA256)"

if [ -n "${KANAME_TAP_DIR:-}" ]; then
    TAP="$(cd "$KANAME_TAP_DIR" && pwd)"
    if [ ! -d "$TAP/.git" ]; then
        echo "error: KANAME_TAP_DIR is not a git checkout: $TAP" >&2
        exit 1
    fi
    mkdir -p "$TAP/Casks"
    cp "$CASK_OUT" "$TAP/Casks/kaname.rb"
    git -C "$TAP" add Casks/kaname.rb
    if git -C "$TAP" diff --cached --quiet; then
        echo "==> Tap already has kaname $VERSION; nothing to commit"
    else
        git -C "$TAP" commit -m "kaname $VERSION"
        git -C "$TAP" push
        echo "==> Tap updated: $TAP"
    fi
else
    echo "    KANAME_TAP_DIR is not set; no tap was pushed."
    echo "    After the release asset is live, copy build/kaname.rb to"
    echo "    <tap>/Casks/kaname.rb, commit and push it. Verify with:"
    echo "    brew audit --cask --strict suliveevil/tap/kaname"
fi
