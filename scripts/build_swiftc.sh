#!/usr/bin/env bash
# Fallback build path: compile the app with swiftc directly.
#
# Needed when xcodebuild cannot run on this machine (in this environment the build
# system wraps every compile in `sandbox-exec`, and nested sandboxing is denied:
# "sandbox-exec: sandbox_apply: Operation not permitted"). swiftc with an explicit
# `-load-plugin-library` expands the SwiftUI macros without the plugin server, so the
# same sources still produce a verifiable, signable app.
#
# Usage: scripts/build_swiftc.sh [Debug|Release]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-Release}"
X="/Applications/Xcode-beta.app/Contents/Developer"
[ -d "$X" ] || X="/Applications/Xcode.app/Contents/Developer"
SDK="$X/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
TC="$X/Toolchains/XcodeDefault.xctoolchain/usr/bin"
PLUG="$X/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

OUT="${KAGIPEEK_OUT:-$ROOT/build/manual}"
APP="$OUT/KagiPeek.app"
TEMPLATE="${KAGIPEEK_PLIST_SOURCE:-/Applications/KagiPeek.app/Contents/Info.plist}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

OPT="-Onone -g"
[ "$CONFIG" = "Release" ] && OPT="-O -whole-module-optimization"

echo "==> Compiling ($CONFIG, arm64)"
# shellcheck disable=SC2086
"$TC/swiftc" $OPT -o "$APP/Contents/MacOS/KagiPeek" \
    -sdk "$SDK" -target arm64-apple-macos14.0 -swift-version 5 \
    -load-plugin-library "$PLUG/libSwiftUIMacros.dylib" \
    -load-plugin-library "$PLUG/libSwiftMacros.dylib" \
    -load-plugin-library "$PLUG/libObservationMacros.dylib" \
    $(find KagiPeek -name '*.swift')

if [ -f "$TEMPLATE" ]; then
    echo "==> Info.plist from $TEMPLATE"
    cp "$TEMPLATE" "$APP/Contents/Info.plist"
else
    echo "error: no Info.plist template; pass KAGIPEEK_PLIST_SOURCE" >&2
    exit 1
fi
cp "$(dirname "$TEMPLATE")/Resources/Assets.car" "$APP/Contents/Resources/" 2>/dev/null || true
cp "$(dirname "$TEMPLATE")/Resources/AppIcon.icns" "$APP/Contents/Resources/" 2>/dev/null || true
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(KagiPeek Local\)"/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
    echo "==> Signing with $IDENTITY"
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
else
    echo "==> Ad-hoc signing"
    codesign --force --options runtime --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "App: $APP"
