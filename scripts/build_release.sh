#!/usr/bin/env bash
#
# Builds a Release .app, signs it (Developer ID when available, ad-hoc otherwise),
# optionally notarizes it, and packages a DMG under build/.
#
# Usage:
#   ./scripts/build_release.sh
#   KAGIPEEK_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/build_release.sh
#   KAGIPEEK_NOTARY_PROFILE="kagipeek-notary" ./scripts/build_release.sh   # requires notarytool credentials
#   KAGIPEEK_SKIP_DMG=1 ./scripts/build_release.sh                        # app only

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

VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' KagiPeek.xcodeproj/project.pbxproj | head -1)"
BUILD_DIR="$ROOT/build"
DERIVED="$BUILD_DIR/DerivedData"
APP="$DERIVED/Build/Products/Release/KagiPeek.app"

echo "==> Building KagiPeek ${VERSION} (Release)"
xcodebuild     -project KagiPeek.xcodeproj     -scheme KagiPeek     -configuration Release     -derivedDataPath "$DERIVED"     CODE_SIGNING_ALLOWED=NO     build

# The bundle is the only single source of truth for the version: the project file carries
# MARKETING_VERSION twice (Debug and Release) and a `sed` that matches the wrong one, or
# nothing at all, would silently produce "KagiPeek-.dmg" and a "v" release tag.
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

IDENTITY="${KAGIPEEK_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
if [ -z "$IDENTITY" ]; then
    # Stable self-signed identity created by scripts/setup_signing.sh.
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(KagiPeek Local\)"/\1/p' | head -1)"
fi

if [ -n "$IDENTITY" ]; then
    echo "==> Signing with: $IDENTITY"
    if [ "$IDENTITY" = "KagiPeek Local" ]; then
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

if [ -n "$IDENTITY" ] && [ -n "${KAGIPEEK_NOTARY_PROFILE:-}" ]; then
    echo "==> Submitting for notarization"
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/KagiPeek.zip"
    xcrun notarytool submit "$BUILD_DIR/KagiPeek.zip" --keychain-profile "$KAGIPEEK_NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    codesign --verify --deep --strict "$APP"
fi

if [ "${KAGIPEEK_SKIP_DMG:-0}" = "1" ]; then
    echo "==> App: $APP"
    exit 0
fi

DMG="$BUILD_DIR/KagiPeek-${VERSION}.dmg"
STAGE="$BUILD_DIR/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Packaging $DMG"
rm -f "$DMG"
hdiutil create -volname "KagiPeek" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# The DMG is what users download, so it carries its own signature and notarization: a
# notarized app inside an unsigned disk image is still stopped by Gatekeeper.
if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    codesign --verify --strict "$DMG"
    if [ -n "${KAGIPEEK_NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$KAGIPEEK_NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
    fi
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo
echo "App: $APP"
echo "DMG: $DMG"
