#!/bin/bash
# One time: makes a "Tax Collector Local Signing" certificate in your login keychain, so build-app.sh signs every
# build the same way. Then macOS remembers the permissions you give Tax Collector (like reading the address in
# Chrome for the checkpoint) across updates, instead of asking again after each one.
#
# macOS asks for your password twice: once to trust the certificate for code signing, once (later, on the first
# build) to let codesign use its key. Nothing is sent anywhere; the certificate only exists on this Mac.
set -euo pipefail

NAME="Tax Collector Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is already set up."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# A random password only for moving the key into the keychain; it's thrown away afterwards.
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout "pass:$PASS"

security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Added the certificate to your login keychain. macOS will now ask for your password to trust it for code signing."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Done. The next build is signed with \"$NAME\"."
else
    echo "The certificate was added but isn't trusted for code signing yet. Run this script again." >&2
    exit 1
fi
