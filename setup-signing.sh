#!/bin/bash
set -euo pipefail

# Creates a stable self-signed code-signing certificate in the login keychain so
# TCC grants (Accessibility / Input Monitoring) survive rebuilds. The designated
# requirement stays pinned to this cert instead of a per-build ad-hoc cdhash.

IDENTITY="KVM Switch Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "signing identity already present: $IDENTITY"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = KVM Switch Signing
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.cnf"

# -legacy + SHA1 MAC: Security.framework can't import OpenSSL 3.x default PKCS12.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -passout pass:kvm -name "$IDENTITY" \
  -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P kvm -A

echo "created signing identity: $IDENTITY"
security find-certificate -c "$IDENTITY" -Z "$KEYCHAIN" | grep "SHA-1"
