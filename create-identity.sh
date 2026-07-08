#!/bin/bash
# Creates a stable self-signed code-signing identity named "DemoTape Dev" in the
# login keychain. Signing with a fixed identity keeps macOS Screen Recording
# permission across rebuilds (ad-hoc signing loses it every rebuild).
set -euo pipefail

NAME="DemoTape Dev"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

CONF="${WORK}/req.cnf"
cat > "${CONF}" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = DemoTape Dev
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "==> Generating self-signed code-signing certificate..."
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
    -days 3650 -config "${CONF}"

echo "==> Bundling into PKCS#12..."
/usr/bin/openssl pkcs12 -export \
    -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -out "${WORK}/identity.p12" \
    -name "${NAME}" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout pass:demotape

echo "==> Importing into login keychain (allows codesign to use it)..."
security import "${WORK}/identity.p12" \
    -k "${HOME}/Library/Keychains/login.keychain-db" \
    -P demotape \
    -T /usr/bin/codesign

echo "==> Done. Available code-signing identities:"
security find-identity -v -p codesigning | grep "${NAME}" || true
