#!/usr/bin/env bash
#
# Copies an installed Kaname.app into the shared backup folder before it is replaced.
#
# One backup per install, named for when it was taken and what it was:
#
#   Kaname-<YYYY-MM-DD-HHMMSS>-<shortcommit>-<local|adhoc|devid>.app
#
# Backups live under `~/Library/Application Support/Kaname/backups/`, never next to
# `/Applications/Kaname.app`: a second `.app` in /Applications is picked up by
# LaunchServices as another copy of the same bundle id, and an ad-hoc copy gets its own
# TCC identity (the stale "Kaname-2026-11-04-…-adhoc.app" row in System Settings).
#
# The oldest backups are pruned so the folder cannot grow without bound.
#
# Usage: scripts/backup_app.sh /Applications/Kaname.app
#        KANAME_DRY_RUN=1 scripts/backup_app.sh /Applications/Kaname.app
#
# stdout: the path of the backup (one line, safe to capture).
# stderr: progress and the prune plan.

set -euo pipefail

APP="${1:-}"
case "$APP" in
    *.app) ;;
    *) echo "usage: backup_app.sh </path/to/Some.app>" >&2; exit 2 ;;
esac
if [ ! -d "$APP" ]; then
    echo "error: no bundle at '$APP'" >&2
    exit 2
fi

BACKUP_ROOT="${KANAME_BACKUP_DIR:-$HOME/Library/Application Support/Kaname/backups}"
KEEP="${KANAME_BACKUP_KEEP:-5}"
DRY_RUN="${KANAME_DRY_RUN:-0}"

case "$KEEP" in
    ''|*[!0-9]*) echo "error: KANAME_BACKUP_KEEP must be a number (got '$KEEP')" >&2; exit 2 ;;
esac
if [ "$KEEP" -lt 1 ]; then
    echo "error: KANAME_BACKUP_KEEP must be at least 1 (got '$KEEP')" >&2
    exit 2
fi

# The signing identity decides TCC behaviour, so it belongs in the name. Record a kind,
# not the certificate itself: "Kaname Local" would put a space in the file name.
identity_kind() {
    local details
    # `-dvvv` is required: plain `-dv` omits the Authority lines entirely.
    details="$(codesign -dvvv "$1" 2>&1 || true)"
    case "$details" in
        *"Authority=Developer ID Application"*) echo "devid" ;;
        *"Authority=Kaname Local"*)             echo "local" ;;
        *"Authority=KagiPeek Local"*)           echo "local" ;;
        *)                                      echo "adhoc" ;;
    esac
}

commit_of() {
    local commit
    commit="$(/usr/libexec/PlistBuddy -c "Print :KanameCommit" "$1/Contents/Info.plist" 2>/dev/null || true)"
    commit="${commit//[[:space:]]/}"
    printf '%s' "${commit:-unknown}"
}

STAMP="$(date +%Y-%m-%d-%H%M%S)"
COMMIT="$(commit_of "$APP")"
IDENTITY="$(identity_kind "$APP")"
DEST="$BACKUP_ROOT/Kaname-$STAMP-$COMMIT-$IDENTITY.app"

# One install per second is the normal case; keep a same-second retry distinct rather
# than overwrite the backup that is about to be needed.
if [ -e "$DEST" ] && [ "$DRY_RUN" != "1" ]; then
    DEST="$BACKUP_ROOT/Kaname-$STAMP-$COMMIT-$IDENTITY-2.app"
fi

# Oldest first: the timestamp prefix sorts chronologically as plain text.
backups() {
    local entry
    for entry in "$BACKUP_ROOT"/Kaname-*.app; do
        [ -d "$entry" ] || continue
        printf '%s\n' "$entry"
    done | sort
}

prune_plan() {
    local all count age
    all="$(backups)"
    [ -n "$all" ] || return 0
    count="$(printf '%s\n' "$all" | wc -l | tr -d ' ')"
    age=$((count - KEEP + 1))
    if [ "$age" -lt 1 ]; then
        age=1
    fi
    printf '%s\n' "$all" | head -n "$age"
}

if [ "$DRY_RUN" = "1" ]; then
    echo "backup would be: $DEST" >&2
    echo "keep=$KEEP root=$BACKUP_ROOT" >&2
    plan="$(prune_plan)"
    if [ -n "$plan" ]; then
        printf 'would prune:\n%s\n' "$plan" >&2
    else
        echo "would prune: nothing" >&2
    fi
    printf '%s\n' "$DEST"
    exit 0
fi

mkdir -p "$BACKUP_ROOT"
PARTIAL="$DEST.partial"
rm -rf "$PARTIAL"
ditto "$APP" "$PARTIAL"
if ! codesign --verify --strict "$PARTIAL" 2>/dev/null; then
    rm -rf "$PARTIAL"
    echo "error: the copied backup does not verify; nothing was kept" >&2
    exit 1
fi
mv "$PARTIAL" "$DEST"

# Count the new backup as one of the kept copies.
ALL="$(backups)"
COUNT="$(printf '%s\n' "$ALL" | wc -l | tr -d ' ')"
if [ "$COUNT" -gt "$KEEP" ]; then
    printf '%s\n' "$ALL" | head -n "$((COUNT - KEEP))" | while IFS= read -r old; do
        echo "pruning $old" >&2
        rm -rf "$old"
    done
fi

echo "kept $DEST" >&2
printf '%s\n' "$DEST"
