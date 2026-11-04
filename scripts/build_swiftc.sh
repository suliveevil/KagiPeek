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
APP="$OUT/KagiPeek.app"

# The template comes from the repository first. It used to come only from
# /Applications/KagiPeek.app — a previously installed copy — which made the build depend on its
# own output: with the app deleted, nothing could be built at all (2026-11-02). The installed
# copy stays as a last resort for anyone who has one and no checkout-level template.
TEMPLATE="${KAGIPEEK_PLIST_SOURCE:-}"
if [ -z "$TEMPLATE" ]; then
    for candidate in "$ROOT/scripts/Info.plist" "/Applications/KagiPeek.app/Contents/Info.plist"; do
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
"$TC/swiftc" $OPT -o "$APP/Contents/MacOS/KagiPeek" \
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
# Icons are compiled from the catalog in the repository rather than copied from next to the
# plist template: the template may now live in scripts/, and inheriting whichever icons the
# last installed copy happened to carry is how a stale icon survives a redesign. actool ships
# with Xcode, which this path already requires for the SDK and the toolchain.
CATALOG="$ROOT/KagiPeek/Assets.xcassets"
if [ -d "$CATALOG" ]; then
    echo "==> Compiling the asset catalog"
    xcrun actool --compile "$APP/Contents/Resources" \
        --platform macosx --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$OUT/asset-partial.plist" \
        "$CATALOG" >/dev/null || {
        echo "warning: actool failed; the app will build without an icon" >&2
    }
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The About page shows this commit; it has to be in the plist before signing.
"$ROOT/scripts/stamp_commit.sh" "$APP"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(KagiPeek Local\)"/\1/p' | head -1)"
if [ -n "$IDENTITY" ]; then
    echo "==> Signing with $IDENTITY"
    codesign --force --options runtime --sign "$IDENTITY" "$APP"
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
