#!/bin/bash
# A persistent self-signed identity, scoped to a dedicated local keychain.
# Does not add a root certificate to the system/login trust stores.
set -euo pipefail
SIGNING_DIR="$HOME/Library/Application Support/LocalWrite/Signing"
KEYCHAIN="$SIGNING_DIR/LocalWrite.keychain-db"
mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"
if [[ -f "$KEYCHAIN" && -f "$SIGNING_DIR/certificate.sha1" ]]; then
    printf 'Persistent LocalWrite signing identity already exists.\n'
    exit 0
fi
if [[ -f "$KEYCHAIN" ]]; then
    printf 'An incomplete signing keychain exists at %s. Inspect it before retrying.\n' "$KEYCHAIN" >&2
    exit 1
fi
umask 077
SIGNING_TEMP=$(mktemp -d)
trap 'rm -rf "$SIGNING_TEMP"' EXIT
/usr/bin/openssl rand -base64 32 > "$SIGNING_DIR/keychain-password"
SIGNING_PASSWORD=$(cat "$SIGNING_DIR/keychain-password")
cat > "$SIGNING_TEMP/certificate.cnf" <<'CONFIG'
[req]
distinguished_name = dn
x509_extensions = extensions
prompt = no
[dn]
CN = LocalWrite Local Development
[extensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
/usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$SIGNING_TEMP/certificate.cnf" \
    -keyout "$SIGNING_TEMP/private-key.pem" -out "$SIGNING_DIR/certificate.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -name 'LocalWrite Local Development' \
    -inkey "$SIGNING_TEMP/private-key.pem" -in "$SIGNING_DIR/certificate.pem" \
    -out "$SIGNING_TEMP/identity.p12" -passout "file:$SIGNING_DIR/keychain-password"
security create-keychain -p "$SIGNING_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$SIGNING_PASSWORD" "$KEYCHAIN"
security import "$SIGNING_TEMP/identity.p12" -k "$KEYCHAIN" -P "$SIGNING_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$SIGNING_PASSWORD" "$KEYCHAIN" >/dev/null
/usr/bin/openssl x509 -in "$SIGNING_DIR/certificate.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':' > "$SIGNING_DIR/certificate.sha1"
printf 'Created persistent local signing identity in %s\n' "$SIGNING_DIR"
