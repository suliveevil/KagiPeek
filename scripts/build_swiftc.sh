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
X="${KAGIPEEK_XCODE:-/Applications/Xcode-beta.app/Contents/Developer}"
[ -d "$X" ] || X="${KAGIPEEK_XCODE:-/Applications/Xcode.app/Contents/Developer}"
SDK="$X/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
TC="$X/Toolchains/XcodeDefault.xctoolchain/usr/bin"
PLUG="$X/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

# Fail as "no Xcode", not as "swiftc: No such file or directory": the second message sends
# you looking for a compiler bug when the actual problem is that the toolchain is not
# installed, and the Command Line Tools are not a substitute (they ship without
# libSwiftUIMacros, so every `@State` in the UI fails to expand).
if [ ! -x "$TC/swiftc" ]; then
    echo "error: no Xcode developer directory at $X" >&2
    echo "       install Xcode, or point KAGIPEEK_XCODE at one" >&2
    exit 1
fi

OUT="${KAGIPEEK_OUT:-$ROOT/build/manual}"
APP="$OUT/Kaname.app"

# The template comes from the repository first. It used to come only from
# /Applications/KagiPeek.app — a previously installed copy — which made the build depend on its
# own output: with the app deleted, nothing could be built at all (2026-11-02). The installed
# copy stays as a last resort for anyone who has one and no checkout-level template.
TEMPLATE="${KAGIPEEK_PLIST_SOURCE:-}"
if [ -z "$TEMPLATE" ]; then
    for candidate in "$ROOT/scripts/Info.plist" "/Applications/Kaname.app/Contents/Info.plist"; do
        if [ -f "$candidate" ]; then
            TEMPLATE="$candidate"
            break
        fi
    done
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

OPT="-Onone -g"
[ "$CONFIG" = "Release" ] && OPT="-O -whole-module-optimization"

echo "==> Compiling ($CONFIG, arm64, Swift 6)"
# These flags mirror the Xcode target exactly: `SWIFT_VERSION = 6.0`,
# `SWIFT_STRICT_CONCURRENCY = complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
# `SWIFT_APPROACHABLE_CONCURRENCY = YES` (whose two relevant upcoming features are spelled
# out below). Both build paths compile the same language and report the same diagnostics —
# the project is warning-free at `complete`, so a new warning here is a new warning there.
# shellcheck disable=SC2086
"$TC/swiftc" $OPT -o "$APP/Contents/MacOS/Kaname" \
    -sdk "$SDK" -target arm64-apple-macos14.0 -swift-version 6 \
    -default-isolation MainActor \
    -Xfrontend -strict-concurrency=complete \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature MemberImportVisibility \
    -enable-upcoming-feature InferIsolatedConformances \
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

# The Xcode path takes the version from `MARKETING_VERSION`; this path took it from whichever
# Info.plist template it found. A version bump that only touched the project file therefore
# produced a fallback build that named itself the previous release — the DMG said 2.2.0 and
# the About page said 2.1.0. The template still supplies everything else, but the two keys
# that name the build are read from the project file whenever it carries them.
PLIST="$APP/Contents/Info.plist"
PBXPROJ="$ROOT/KagiPeek.xcodeproj/project.pbxproj"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
PROJECT_VERSION="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$PBXPROJ" 2>/dev/null | head -1)"
PROJECT_BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' "$PBXPROJ" 2>/dev/null | head -1)"
if [ -n "$PROJECT_VERSION" ]; then
    if [ -n "$PLIST_VERSION" ] && [ "$PLIST_VERSION" != "$PROJECT_VERSION" ]; then
        # Said out loud rather than silently corrected: the template and the project file
        # disagreeing is what makes a fallback build differ from the one users get.
        echo "==> version $PLIST_VERSION (template) overridden by MARKETING_VERSION $PROJECT_VERSION"
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PROJECT_VERSION" "$PLIST"
fi
if [ -n "$PROJECT_BUILD" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PROJECT_BUILD" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $PROJECT_BUILD" "$PLIST"
fi
# Icons are compiled from the catalog in the repository rather than copied from next to the
# plist template: the template may now live in scripts/, and inheriting whichever icons the
# last installed copy happened to carry is how a stale icon survives a redesign. actool ships
# with Xcode, which this path already requires for the SDK and the toolchain.
# One actool invocation compiles both sources into a single Assets.car: the
# Icon Composer .icon supplies the layered Kaname app icon, and the catalog
# keeps MenuBarIcon (loaded at runtime with NSImage(named:)). Two separate
# invocations would overwrite each other's Assets.car. actool accepts .icon
# even at deployment target 14.0 and emits Kaname.icns for older macOS.
# The generated partial plist names Kaname for both icon keys; the template
# above carries those values because this path copies Info.plist verbatim.
ICON_SOURCE="$ROOT/KagiPeek/Kaname.icon"
CATALOG="$ROOT/KagiPeek/Assets.xcassets"
if [ -d "$ICON_SOURCE" ] && [ -d "$CATALOG" ]; then
    echo "==> Compiling Kaname.icon + asset catalog"
    xcrun actool --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0 \
        --app-icon Kaname \
        --output-partial-info-plist "$OUT/asset-partial.plist" \
        "$ICON_SOURCE" "$CATALOG" >/dev/null || {
        echo "warning: actool failed; the app will build without an icon" >&2
    }
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The About page shows this commit; it has to be in the plist before signing.
"$ROOT/scripts/stamp_commit.sh" "$APP"

# The self-signed `KagiPeek Local` key lives in its own keychain. Unlocking it with the
# passphrase file keeps `codesign` non-interactive: the login keychain's key ACL and
# partition list are managed by macOS, so signing from there asks for authorization over
# and over. The passphrase is read, never printed, and never stored in the repository.
SIGN_KEYCHAIN_FILE="${KAGIPEEK_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/kagipeek-signing.keychain-db}"
SIGN_PASS_FILE="${KAGIPEEK_SIGNING_PASS_FILE:-$HOME/Library/Application Support/KagiPeek/signing/keychain-pass}"

IDENTITY=""
SIGN_KEYCHAIN=""
if [ -f "$SIGN_KEYCHAIN_FILE" ] && [ -r "$SIGN_PASS_FILE" ]; then
    security unlock-keychain -p "$(<"$SIGN_PASS_FILE")" "$SIGN_KEYCHAIN_FILE" >/dev/null 2>&1 || true
    IDENTITY="$(security find-identity -v -p codesigning "$SIGN_KEYCHAIN_FILE" 2>/dev/null | sed -n 's/.*"\(KagiPeek Local\)"/\1/p' | head -1)"
    [ -n "$IDENTITY" ] && SIGN_KEYCHAIN="$SIGN_KEYCHAIN_FILE"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(KagiPeek Local\)"/\1/p' | head -1)"
fi

if [ -n "$IDENTITY" ]; then
    echo "==> Signing with $IDENTITY"
    if [ -n "$SIGN_KEYCHAIN" ]; then
        codesign --force --options runtime --sign "$IDENTITY" --keychain "$SIGN_KEYCHAIN" "$APP"
    else
        codesign --force --options runtime --sign "$IDENTITY" "$APP"
    fi
else
    echo "==> Ad-hoc signing"
    codesign --force --options runtime --sign - "$APP"
    # Verification only: ad-hoc output must not be installed into /Applications. Its cdhash
    # changes on every build, so macOS treats each rebuild as a new app and asks for
    # permissions again. `scripts/install.sh` refuses it; use `scripts/setup_signing.sh`.
    echo "    note: ad-hoc builds are for verification only; use setup_signing.sh before installing." >&2
fi
codesign --verify --strict --verbose=2 "$APP"

echo "App: $APP"
