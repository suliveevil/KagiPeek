#!/usr/bin/env bash
#
# Writes the short git commit into the bundle's Info.plist as `KanameCommit`, so the
# About page can read "v2.2.0 (dbafe89)" instead of the build number.
#
# Must run *before* `codesign`: editing Info.plist after signing invalidates the signature
# and the app will fail to launch on the next strict verification.
#
# Usage: scripts/stamp_commit.sh /path/to/Kaname.app
set -euo pipefail

APP="${1:?usage: stamp_commit.sh <app bundle>}"
PLIST="$APP/Contents/Info.plist"
if [ ! -f "$PLIST" ]; then
    echo "error: no Info.plist at $PLIST" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

# A build from a working tree that differs from HEAD is not that commit; say so rather
# than let the About page claim otherwise.
if ! git -C "$ROOT" diff --quiet 2>/dev/null || ! git -C "$ROOT" diff --cached --quiet 2>/dev/null; then
    COMMIT="${COMMIT}-dirty"
fi

/usr/libexec/PlistBuddy -c "Delete :KanameCommit" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :KanameCommit string $COMMIT" "$PLIST"
echo "==> Commit: $COMMIT"
