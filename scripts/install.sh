#!/usr/bin/env bash
#
# Builds a Release app and replaces the copy in /Applications.
#
# The replacement is atomic and reversible: the new bundle is staged next to the target,
# verified, swapped in with `mv`, and the bundle it replaced is copied to
# `~/Library/Application Support/Kaname/backups/` as
# `Kaname-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app` (the five most
# recent are kept). Any failure between "the app is gone" and "the app is back" restores
# the backup, so a failed install cannot leave the user without an app.
#
# Never leave a second `.app` in /Applications: LaunchServices registers every copy under
# the same bundle id, and an ad-hoc copy gets its own TCC identity, which is how stale
# names end up in System Settings → Input Monitoring. The previous name's bundle
# (`/Applications/KagiPeek.app`, `com.voltline.kagipeek`) is stopped, backed up and removed
# for the same reason.
#
# Only a build with a stable signature (`Kaname Local` or a Developer ID) may be
# installed. An ad-hoc build changes cdhash on every compile, so macOS treats each
# rebuild as a new app: permissions are asked again and old rows pile up. Ad-hoc builds
# are for `codesign --verify` checks in a temporary directory only.
#
# Set `KANAME_SKIP_BUILD=1` to install the artifact already produced by
# `scripts/build_swiftc.sh Release` instead of running a build here.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DEST="${KANAME_INSTALL_PATH:-/Applications/Kaname.app}"
case "$DEST" in
    *.app) ;;
    *) echo "error: KANAME_INSTALL_PATH must end in .app (got '$DEST')" >&2; exit 1 ;;
esac
if [ "$DEST" = "/.app" ] || [ "$DEST" = "/Applications/.app" ]; then
    echo "error: refusing to install to '$DEST'" >&2
    exit 1
fi

LEGACY_DEST="/Applications/KagiPeek.app"
LEGACY_BUNDLE_ID="com.voltline.kagipeek"

DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/Kaname.app"
STAGE="${DEST}.new"

if [ "${KANAME_SKIP_BUILD:-0}" = "1" ]; then
    APP="$ROOT/build/manual/Kaname.app"
    if [ ! -d "$APP" ]; then
        echo "error: KANAME_SKIP_BUILD=1 but $APP does not exist" >&2
        echo "       run scripts/build_swiftc.sh Release first" >&2
        exit 1
    fi
else
    KANAME_SKIP_DMG=1 "$ROOT/scripts/build_release.sh" || {
        # On machines where the Xcode build system cannot run (for example when `sandbox-exec`
        # is unavailable, so every per-file compile fails), fall back to compiling the same
        # sources with swiftc and loading the SwiftUI macros explicitly.
        echo "==> xcodebuild failed; falling back to the swiftc build" >&2
        "$ROOT/scripts/build_swiftc.sh" Release
        APP="$ROOT/build/manual/Kaname.app"
    }
fi

# `sudo` only when the destination directory is not writable, and then for every step so a
# half-root, half-user install cannot happen.
SUDO=""
if [ ! -w "$(dirname "$DEST")" ]; then
    SUDO="sudo"
fi

echo "==> Stopping running instances"
# Quit by bundle id first: `pkill -f` matches any process whose command line contains the
# path, including a build copy or another user's instance. Both the current and the
# previous bundle id are stopped so an old copy cannot keep its event tap alive.
osascript -e "tell application id \"com.suliveevil.kaname\" to quit" >/dev/null 2>&1 || true
osascript -e "tell application id \"$LEGACY_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
    pgrep -f "$DEST/Contents/MacOS/Kaname" >/dev/null 2>&1 || break
    sleep 0.25
done
if pgrep -f "$DEST/Contents/MacOS/Kaname" >/dev/null 2>&1; then
    echo "    still running; terminating"
    pkill -f "$DEST/Contents/MacOS/Kaname" 2>/dev/null || true
    sleep 0.5
fi
if [ "$LEGACY_DEST" != "$DEST" ] && pgrep -f "$LEGACY_DEST/Contents/MacOS/KagiPeek" >/dev/null 2>&1; then
    echo "    old KagiPeek still running; terminating"
    pkill -f "$LEGACY_DEST/Contents/MacOS/KagiPeek" 2>/dev/null || true
    sleep 0.5
fi

LEGACY_BACKUP=""
if [ -d "$LEGACY_DEST" ] && [ "$LEGACY_DEST" != "$DEST" ]; then
    echo "==> Backing up the old KagiPeek build"
    LEGACY_BACKUP="$("$ROOT/scripts/backup_app.sh" "$LEGACY_DEST")"
fi

echo "==> Staging $STAGE"
$SUDO rm -rf "$STAGE"
$SUDO ditto "$APP" "$STAGE"
if ! codesign --verify --strict "$STAGE" 2>/dev/null; then
    $SUDO rm -rf "$STAGE"
    echo "error: the staged copy is not correctly signed; nothing was installed" >&2
    exit 1
fi

# `-dvvv` is required (plain `-dv` omits the Authority lines). Capture the output instead
# of piping into `grep -q`: with `pipefail`, grep exiting on the first match can kill
# codesign with SIGPIPE and turn a good signature into a rejection.
SIGNATURE_DETAILS="$(codesign -dvvv "$STAGE" 2>&1 || true)"
case "$SIGNATURE_DETAILS" in
    *"Authority=Kaname Local"*|*"Authority=Developer ID Application"*) ;;
    *)
        $SUDO rm -rf "$STAGE"
        echo "error: the staged build is ad-hoc signed; refusing to install it." >&2
        echo "       A stable identity is required: run ./scripts/setup_signing.sh" >&2
        echo "       once, then rebuild. Ad-hoc packages are only for verification." >&2
        exit 1
        ;;
esac

BACKUP=""
if [ -d "$DEST" ]; then
    echo "==> Backing up the installed build"
    BACKUP="$("$ROOT/scripts/backup_app.sh" "$DEST")"
fi

echo "==> Installing to $DEST"
$SUDO rm -rf "$DEST"
if ! $SUDO mv "$STAGE" "$DEST"; then
    echo "error: could not move the new build into place; restoring the backup" >&2
    if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
        $SUDO rm -rf "$DEST"
        $SUDO ditto "$BACKUP" "$DEST"
    fi
    exit 1
fi

if [ -d "$LEGACY_DEST" ] && [ "$LEGACY_DEST" != "$DEST" ]; then
    echo "==> Removing the old KagiPeek.app (backed up first)"
    $SUDO rm -rf "$LEGACY_DEST"
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
fi

echo "==> Signed with a stable identity: the Accessibility grant survives rebuilds."

echo "==> Launching"
open "$DEST"

cat <<NOTICE

Kaname installed and signed with a stable identity.

If this is the first install signed with that identity, grant Accessibility once:
  System Settings → Privacy & Security → Accessibility → enable Kaname.
After that, rebuilds keep the grant: the designated requirement is
"identifier com.suliveevil.kaname and certificate root = H<cert>", which does
not change when the code changes. Input Monitoring is only needed if key events
do not arrive.

${BACKUP:+The replaced build is kept at:
  $BACKUP

}${LEGACY_BACKUP:+The old KagiPeek build is kept at:
  $LEGACY_BACKUP

}
Backups: ~/Library/Application Support/Kaname/backups (five most recent).
Roll back with:
  osascript -e 'tell application id "com.suliveevil.kaname" to quit'; sleep 2
  rm -rf "${DEST}.new" && ditto "<backup.app>" "${DEST}.new"
  rm -rf "$DEST" && mv "${DEST}.new" "$DEST" && open "$DEST"
  /usr/libexec/PlistBuddy -c "Print :KanameCommit" "$DEST/Contents/Info.plist"
NOTICE
