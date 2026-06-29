#!/bin/bash
# One-time: create a stable self-signed code-signing identity so TCC permissions
# (Accessibility, etc.) survive rebuilds. Ad-hoc signing changes the cdhash on
# every compile, which makes macOS forget the grant and re-prompt. A fixed
# identity keeps the codesign designated requirement stable across rebuilds.
set -euo pipefail

CERT_NAME="TaskBeacon Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "✅ Signing identity '$CERT_NAME' already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
EOF

# 10-year self-signed cert + key, no passphrase on the PEMs.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.cnf" >/dev/null 2>&1

# Bundle into a PKCS#12 for import. -legacy uses 3DES/SHA1 algorithms that the
# macOS Security framework can read (OpenSSL 3.x defaults are too new for it).
openssl pkcs12 -export -legacy -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$CERT_NAME" -passout pass:taskbeacon >/dev/null 2>&1

# Import key + cert into the login keychain; pre-authorize codesign to use the
# private key so signing doesn't pop a keychain dialog.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P taskbeacon \
  -T /usr/bin/codesign -T /usr/bin/security

# Trust the cert for code signing so `find-identity -v` lists it.
# (User trust domain — macOS may show a one-time auth dialog.)
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" || \
  echo "⚠️  Trust step skipped/failed — run it manually if signing can't find the identity."

echo "✅ Installed signing identity '$CERT_NAME'"
