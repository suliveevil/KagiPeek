#!/usr/bin/env bash
#
# Builds a Release .app, signs it (Developer ID when available, ad-hoc otherwise),
# optionally notarizes it, and packages a DMG under build/.
#
# Usage:
#   ./scripts/build_release.sh
#   KANAME_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/build_release.sh
#   KANAME_NOTARY_PROFILE="kaname-notary" ./scripts/build_release.sh   # requires notarytool credentials
#   KANAME_SKIP_DMG=1 ./scripts/build_release.sh                        # app only

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi
# xcodebuild refuses to run when xcode-select points at the Command Line Tools.
# Fall back to an installed Xcode (stable, then beta) instead of failing.
if ! xcodebuild -version >/dev/null 2>&1; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: xcodebuild requires full Xcode (Command Line Tools are not enough)." >&2
    echo "       sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' Kaname.xcodeproj/project.pbxproj | head -1)"
BUILD_DIR="$ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
APP="$DERIVED/Build/Products/Release/Kaname.app"

echo "==> Building Kaname ${VERSION} (Release)"
xcodebuild     -project Kaname.xcodeproj     -scheme Kaname     -configuration Release     -derivedDataPath "$DERIVED"     CODE_SIGNING_ALLOWED=NO     build

# The bundle is the only single source of truth for the version: the project file carries
# MARKETING_VERSION twice (Debug and Release) and a `sed` that matches the wrong one, or
# nothing at all, would silently produce "Kaname-.dmg" and a "v" release tag.
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$BUILT_VERSION" ]; then
    echo "error: could not read CFBundleShortVersionString from $APP" >&2
    exit 1
fi
if [ -n "$VERSION" ] && [ "$VERSION" != "$BUILT_VERSION" ]; then
    echo "error: MARKETING_VERSION ($VERSION) does not match the built bundle ($BUILT_VERSION)" >&2
    exit 1
fi
VERSION="$BUILT_VERSION"

# xcodebuild is incremental: replacing the app icon does not remove the old
# .icns from a previously built bundle, so a stale AppIcon.icns can be copied
# into /Applications and signed alongside the new Kaname.icns. Keep only the
# icon file named by the built plist. This has to happen before stamp_commit.sh
# and codesign, otherwise the signature covers a resource we meant to drop.
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$ICON_FILE" ]; then
    ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Contents/Info.plist" 2>/dev/null || true)"
fi
if [ -n "$ICON_FILE" ]; then
    case "$ICON_FILE" in
        *.icns) ;;
        *) ICON_FILE="$ICON_FILE.icns" ;;
    esac
    find "$APP/Contents/Resources" -maxdepth 1 -type f -name '*.icns' \
        ! -name "$ICON_FILE" -print -delete
fi

# The About page shows this commit; it has to be in the plist before signing.
"$ROOT/scripts/stamp_commit.sh" "$APP"

IDENTITY="${KANAME_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ]; then
    # Stable self-signed identity created by scripts/setup_signing.sh.
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Kaname Local\)"/\1/p' | head -1)"
fi

if [ -n "$IDENTITY" ]; then
    echo "==> Signing with: $IDENTITY"
    if [ "$IDENTITY" = "Kaname Local" ]; then
        echo "    (stable local identity: Accessibility grants survive rebuilds)"
        # A local self-signed build must not depend on Apple's timestamp service: offline
        # builds would otherwise fail at the last step.
        codesign --force --options runtime --sign "$IDENTITY" "$APP"
    else
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    fi
else
    echo "==> No code-signing identity found, signing ad-hoc (local use only)."
    echo "    Ad-hoc signatures change on every build, so macOS asks again."
    echo "    Run ./scripts/setup_signing.sh once to create a stable local identity."
    codesign --force --options runtime --sign - "$APP"
fi

# `--deep` is deprecated by Apple: verify the app and every nested item explicitly instead.
codesign --verify --strict --verbose=2 "$APP"

if [ -n "$IDENTITY" ] && [ -n "${KANAME_NOTARY_PROFILE:-}" ]; then
    echo "==> Submitting for notarization"
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/Kaname.zip"
    xcrun notarytool submit "$BUILD_DIR/Kaname.zip" --keychain-profile "$KANAME_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    codesign --verify --deep --strict "$APP"
fi

if [ "${KANAME_SKIP_DMG:-0}" = "1" ]; then
    echo "==> App: $APP"
    exit 0
fi

DMG="$BUILD_DIR/Kaname-${VERSION}.dmg"
STAGE="$BUILD_DIR/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Packaging $DMG"
rm -f "$DMG"
hdiutil create -volname "Kaname" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# The DMG is what users download, so it carries its own signature and notarization: a
# notarized app inside an unsigned disk image is still stopped by Gatekeeper.
if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    codesign --verify --strict "$DMG"
    if [ -n "${KANAME_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$KANAME_NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
    fi
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"

# `publish_release.sh` skips the build when the DMG already exists, so "already exists" has to
# mean "built from this commit". Without a stamp, a second run under the same version number
# published whatever the previous checkout happened to leave in build/ — the tag and the code
# inside the DMG could disagree, and nothing in the output said so. A dirty tree is recorded
# as such: the DMG then contains code no commit has, which the publisher warns about.
TREE_STATE="$(git rev-parse HEAD)"
if [ -n "$(git status --porcelain)" ]; then
    TREE_STATE="$TREE_STATE-dirty"
fi
printf '%s %s\n' "$VERSION" "$TREE_STATE" > "$BUILD_DIR/.release-stamp"

echo
echo "App: $APP"
echo "DMG: $DMG"
