#!/usr/bin/env bash
set -euo pipefail

IDENTITY="${1:-ProofPad Local Release}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "A certificate named '$IDENTITY' already exists in the login keychain."
  echo "If codesign cannot use it, remove it in Keychain Access and run this script again."
  exit 0
fi

cat > "$TMP_DIR/openssl.cnf" <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_codesign

[ dn ]
CN = ${IDENTITY}

[ v3_codesign ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
  -keyout "$TMP_DIR/proofpad.key" \
  -out "$TMP_DIR/proofpad.crt" \
  -config "$TMP_DIR/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "$TMP_DIR/proofpad.key" \
  -in "$TMP_DIR/proofpad.crt" \
  -out "$TMP_DIR/proofpad.p12" \
  -name "$IDENTITY" \
  -keysig \
  -passout pass:proofpad >/dev/null 2>&1

security import "$TMP_DIR/proofpad.p12" \
  -k "$KEYCHAIN" \
  -P "proofpad" \
  -A \
  -T /usr/bin/codesign >/dev/null

echo "Imported local code signing identity: $IDENTITY"
echo "Release builds will use it automatically when present."
