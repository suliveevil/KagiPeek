#!/usr/bin/env bash
set -euo pipefail

IDENTITY="${KAGIPEEK_SIGNING_NAME:-KagiPeek Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$IDENTITY" >/dev/null; then
    echo "Code-signing identity already available: $IDENTITY"
    echo "Rebuilds signed with it keep their Accessibility grant."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Creating self-signed code-signing identity: $IDENTITY"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$IDENTITY/O=KagiPeek" -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

security import "$WORK/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null
security import "$WORK/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null

if ! security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$WORK/cert.pem" >/dev/null 2>&1; then
    echo "warning: could not mark the certificate as trusted automatically."
    echo "         Signing still works; Keychain Access can fix the trust setting."
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$IDENTITY" >/dev/null; then
    echo "Created code-signing identity: $IDENTITY"
    echo "Rebuilds signed with it keep their Accessibility grant."
else
    echo "The identity was imported but is not listed as valid." >&2
    exit 1
fi
