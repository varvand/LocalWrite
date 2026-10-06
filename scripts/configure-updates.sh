#!/bin/bash
# Upload private material through stdin directly to encrypted GitHub secrets.
# Exported files are temporary, outside the checkout, and removed on exit.
set +x
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
REPOSITORY="varvand/LocalWrite"
gh auth status >/dev/null 2>&1 || { printf 'Sign in with gh auth login first.\n' >&2; exit 1; }
SPARKLE_BIN="$PWD/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/generate_keys" ]] || swift package resolve --cache-path "$PWD/.build/cache"
PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" --account com.localwrite.mac.updates -p)
EXPECTED_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)
if [[ "$PUBLIC_KEY" != "$EXPECTED_KEY" ]]; then
    printf 'The local update-signing key does not match this app. No secrets were uploaded.\n' >&2
    exit 1
fi
SECRET_TEMP=$(mktemp -d /private/tmp/LocalWrite-secrets.XXXXXX)
trap 'rm -rf "$SECRET_TEMP"' EXIT
SIGNING_DIR="$HOME/Library/Application Support/LocalWrite/Signing"
KEYCHAIN="$SIGNING_DIR/LocalWrite.keychain-db"
security unlock-keychain -p "$(cat "$SIGNING_DIR/keychain-password")" "$KEYCHAIN"
/usr/bin/openssl rand -base64 32 > "$SECRET_TEMP/export-password"
security export -k "$KEYCHAIN" -t identities -f pkcs12 \
    -P "$(cat "$SECRET_TEMP/export-password")" -o "$SECRET_TEMP/certificate.p12" >/dev/null
"$SPARKLE_BIN/generate_keys" --account com.localwrite.mac.updates -x "$SECRET_TEMP/update-key"
# The updates environment allows signing only from the main branch.
gh api --method PUT "repos/$REPOSITORY/environments/updates" --silent --input - <<'JSON'
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
if ! gh api "repos/$REPOSITORY/environments/updates/deployment-branch-policies" --jq '.branch_policies[].name' | /usr/bin/grep -qx main; then
    gh api --method POST "repos/$REPOSITORY/environments/updates/deployment-branch-policies" \
        -f name=main -f type=branch --silent
fi
/usr/bin/base64 < "$SECRET_TEMP/certificate.p12" | gh secret set LOCALWRITE_CERTIFICATE_P12 --repo "$REPOSITORY" --env updates
gh secret set LOCALWRITE_CERTIFICATE_PASSWORD --repo "$REPOSITORY" --env updates < "$SECRET_TEMP/export-password"
gh secret set LOCALWRITE_UPDATE_PRIVATE_KEY --repo "$REPOSITORY" --env updates < "$SECRET_TEMP/update-key"
printf 'Signing secrets are encrypted in the main-only updates environment. Temporary exports have been removed.\n'
