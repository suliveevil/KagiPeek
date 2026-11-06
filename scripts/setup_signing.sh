#!/usr/bin/env bash
set -euo pipefail

IDENTITY="${KANAME_SIGNING_NAME:-Kaname Local}"
SIGN_DIR="$HOME/Library/Application Support/Kaname/signing"
KEYCHAIN="$HOME/Library/Keychains/kaname-signing.keychain-db"
PASS_FILE="$SIGN_DIR/keychain-pass"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -F -- "$IDENTITY" >/dev/null; then
    echo "Code-signing identity already available in $KEYCHAIN: $IDENTITY"
    echo "Rebuilds signed with it keep their Accessibility grant."
    exit 0
fi

# An identity outside the dedicated keychain must be moved, not replaced: a new certificate
# changes the TCC designated requirement and every permission would be asked again.
if security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$IDENTITY" >/dev/null; then
    echo "error: $IDENTITY exists outside $KEYCHAIN." >&2
    echo "       Move it with the steps in docs/RELEASING.md (Signing keychain);" >&2
    echo "       do not create a second certificate." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"
umask 077
if [ ! -f "$PASS_FILE" ]; then
    openssl rand -base64 32 > "$PASS_FILE"
fi
chmod 600 "$PASS_FILE"
PASS="$(cat "$PASS_FILE")"

if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$PASS" "$KEYCHAIN"
fi
# Twelve hours: an unattended build day never reaches the lock, while the keychain still
# locks itself at rest. The passphrase file (600) is what lets codesign unlock it silently.
security set-keychain-settings -t 43200 "$KEYCHAIN"
security unlock-keychain -p "$PASS" "$KEYCHAIN"

echo "==> Creating self-signed code-signing identity: $IDENTITY"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$IDENTITY/O=Kaname" -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

security import "$WORK/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null
security import "$WORK/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KEYCHAIN" >/dev/null
# Keep the previous keychain in the user search list: it is the rollback copy and must stay
# usable until the new identity has proven itself.
CURRENT_KEYCHAINS=()
while IFS= read -r kc; do
    kc="${kc#\"}"
    kc="${kc%\"}"
    kc="${kc#"${kc%%[![:space:]]*}"}"
    kc="${kc%"${kc##*[![:space:]]}"}"
    [ -n "$kc" ] && CURRENT_KEYCHAINS+=("$kc")
done < <(security list-keychains -d user)
LISTED=0
for kc in "${CURRENT_KEYCHAINS[@]}"; do
    [ "$kc" = "$KEYCHAIN" ] && LISTED=1
done
if [ "$LISTED" = "0" ]; then
    security list-keychains -d user -s "${CURRENT_KEYCHAINS[@]}" "$KEYCHAIN" >/dev/null
fi

if ! security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem" >/dev/null 2>&1; then
    echo "warning: could not mark the certificate as trusted automatically."
    echo "         Signing still works; Keychain Access can fix the trust setting."
fi

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -F -- "$IDENTITY" >/dev/null; then
    echo "Created code-signing identity: $IDENTITY"
    echo "Keychain: $KEYCHAIN"
    echo "Passphrase file: $PASS_FILE (600; never commit it)"
    echo "Rebuilds signed with it keep their Accessibility grant."
else
    echo "The identity was imported but is not listed as valid." >&2
    exit 1
fi
