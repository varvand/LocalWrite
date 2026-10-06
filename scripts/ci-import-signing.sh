#!/bin/bash
# Run only in the protected main-branch release job. Never enable shell tracing.
set +x
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
: "${RUNNER_TEMP:?}"
: "${GITHUB_ENV:?}"
: "${LOCALWRITE_CERTIFICATE_P12:?Missing encrypted certificate secret}"
: "${LOCALWRITE_CERTIFICATE_PASSWORD:?Missing certificate password secret}"
: "${LOCALWRITE_UPDATE_PRIVATE_KEY:?Missing update-signing secret}"
SECRET_DIR=$(mktemp -d "$RUNNER_TEMP/localwrite-signing.XXXXXX")
export LOCALWRITE_SECRET_DIR="$SECRET_DIR"
python3 - <<'PY'
import base64, os, pathlib, secrets
root = pathlib.Path(os.environ['LOCALWRITE_SECRET_DIR'])
try:
    certificate = base64.b64decode(os.environ['LOCALWRITE_CERTIFICATE_P12'].strip(), validate=True)
    seed = base64.b64decode(os.environ['LOCALWRITE_UPDATE_PRIVATE_KEY'].strip(), validate=True)
    if not certificate.startswith(b'\x30') or len(seed) != 32:
        raise ValueError()
except Exception:
    raise SystemExit('Signing secrets have an invalid format; their values were not logged.')
(root / 'certificate.p12').write_bytes(certificate)
(root / 'update-key').write_text(base64.b64encode(seed).decode())
(root / 'keychain-password').write_text(secrets.token_urlsafe(32))
PY
KEYCHAIN="$SECRET_DIR/LocalWrite.keychain-db"
KEYCHAIN_PASSWORD=$(cat "$SECRET_DIR/keychain-password")
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# codesign's identity lookup also consults the user keychain search list.
# This changes only the disposable GitHub runner, not the signing Mac.
security list-keychains -d user -s "$KEYCHAIN"
security import "$SECRET_DIR/certificate.p12" -k "$KEYCHAIN" \
    -P "$LOCALWRITE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
SIGNING_HASH=$(security find-certificate -c 'LocalWrite Local Development' -p "$KEYCHAIN" | /usr/bin/openssl x509 -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
if [[ ! "$SIGNING_HASH" =~ ^[A-Fa-f0-9]{40}$ ]]; then
    printf 'Could not find the expected LocalWrite signing certificate.\n' >&2
    exit 1
fi
# Only file paths and a public certificate fingerprint enter subsequent steps.
printf 'LOCALWRITE_SECRET_DIR=%s\nLOCALWRITE_SIGNING_KEYCHAIN=%s\nLOCALWRITE_SIGNING_HASH=%s\n' \
    "$SECRET_DIR" "$KEYCHAIN" "$SIGNING_HASH" >> "$GITHUB_ENV"
rm -f "$SECRET_DIR/certificate.p12" "$SECRET_DIR/keychain-password"
