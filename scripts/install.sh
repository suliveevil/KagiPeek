#!/usr/bin/env bash
#
# Builds a Release app and replaces the copy in /Applications.
#
# The replacement is atomic and reversible: the new bundle is staged next to the target,
# verified, swapped in with `mv`, and the previous bundle is kept as
# `KagiPeek.previous.app`. Any failure between "the app is gone" and "the app is back"
# restores the previous copy, so a failed install cannot leave the user without an app.
#
# Local-use helper: signing falls back to ad-hoc, which changes the code signature, so
# macOS will ask for Accessibility again after every install.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEST="${KAGIPEEK_INSTALL_PATH:-/Applications/KagiPeek.app}"
case "$DEST" in
    *.app) ;;
    *) echo "error: KAGIPEEK_INSTALL_PATH must end in .app (got '$DEST')" >&2; exit 1 ;;
esac
if [ "$DEST" = "/.app" ] || [ "$DEST" = "/Applications/.app" ]; then
    echo "error: refusing to install to '$DEST'" >&2
    exit 1
fi

DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/KagiPeek.app"
STAGE="${DEST}.new"
PREV="${DEST%.app}.previous.app"

KAGIPEEK_SKIP_DMG=1 "$ROOT/scripts/build_release.sh" || {
    # On machines where the Xcode build system cannot run (for example when `sandbox-exec`
    # is unavailable, so every per-file compile fails), fall back to compiling the same
    # sources with swiftc and loading the SwiftUI macros explicitly.
    echo "==> xcodebuild failed; falling back to the swiftc build" >&2
    "$ROOT/scripts/build_swiftc.sh" Release
    APP="$ROOT/build/manual/KagiPeek.app"
}

# `sudo` only when the destination directory is not writable, and then for every step so a
# half-root, half-user install cannot happen.
SUDO=""
if [ ! -w "$(dirname "$DEST")" ]; then
    SUDO="sudo"
fi

echo "==> Stopping running instances"
# Quit by bundle id first: `pkill -f` matches any process whose command line contains the
# path, including a build copy or another user's instance.
osascript -e 'tell application id "com.voltline.kagipeek" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
    pgrep -f "$DEST/Contents/MacOS/KagiPeek" >/dev/null 2>&1 || break
    sleep 0.25
done
if pgrep -f "$DEST/Contents/MacOS/KagiPeek" >/dev/null 2>&1; then
    echo "    still running; terminating"
    pkill -f "$DEST/Contents/MacOS/KagiPeek" 2>/dev/null || true
    sleep 0.5
fi

echo "==> Staging $STAGE"
$SUDO rm -rf "$STAGE"
$SUDO ditto "$APP" "$STAGE"
if ! codesign --verify --strict "$STAGE" 2>/dev/null; then
    $SUDO rm -rf "$STAGE"
    echo "error: the staged copy is not correctly signed; nothing was installed" >&2
    exit 1
fi

echo "==> Installing to $DEST"
$SUDO rm -rf "$PREV"
if [ -d "$DEST" ]; then
    $SUDO mv "$DEST" "$PREV"
fi
if ! $SUDO mv "$STAGE" "$DEST"; then
    echo "error: could not move the new build into place; restoring the previous copy" >&2
    if [ -d "$PREV" ]; then $SUDO mv "$PREV" "$DEST"; fi
    exit 1
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -F -- "KagiPeek Local" >/dev/null; then
    echo "==> Signed with the stable local identity: the Accessibility grant survives rebuilds."
else
    echo "==> Ad-hoc signed: macOS will treat this build as a new app and ask again."
    echo "    Run ./scripts/setup_signing.sh once to keep the grant across rebuilds."
fi

echo "==> Launching"
open "$DEST"

if security find-identity -v -p codesigning 2>/dev/null | grep -F -- "KagiPeek Local" >/dev/null; then
    cat <<'NOTICE'

KagiPeek installed and signed with the stable "KagiPeek Local" identity.

If this is the first install signed with that identity, grant Accessibility once:
  System Settings → Privacy & Security → Accessibility → enable KagiPeek.
After that, rebuilds keep the grant: the designated requirement is
"identifier com.voltline.kagipeek and certificate root = H<cert>", which does
not change when the code changes. Input Monitoring is only needed if key events
do not arrive.

The previous build is kept at the path printed above as "*.previous.app":
  mv KagiPeek.previous.app KagiPeek.app     # roll back a bad install
NOTICE
else
    cat <<'NOTICE'

KagiPeek installed (ad-hoc signed).

Ad-hoc signatures change on every build, so macOS treats each rebuild as a new
app and the previous Accessibility grant no longer applies:
  1. Run ./scripts/setup_signing.sh once to create a stable local identity.
  2. Reinstall; grant Accessibility once and keep it across rebuilds.

NOTICE
fi
