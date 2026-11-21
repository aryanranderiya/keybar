#!/bin/sh
# Create a self-signed code-signing certificate in your login keychain.
#
# macOS remembers privacy permissions (like Input Monitoring) per signing identity.
# An ad-hoc signed app gets a new identity on every build, so the permission is lost
# each time you rebuild. Signing with this certificate keeps it stable.
set -eu

NAME="KeyBar Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
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

# The Security framework only imports PKCS#12 with legacy encryption; LibreSSL uses it by default.
LEGACY=""
openssl version | grep -q '^OpenSSL 3' && LEGACY="-legacy"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/cert.p12" -passout pass:keybar
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P keybar -T /usr/bin/codesign >/dev/null
echo "created \"$NAME\""
