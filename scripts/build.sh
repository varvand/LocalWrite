#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache"
BUILD_TEMP=$(mktemp -d /private/tmp/LocalWrite-build.XXXXXX)
trap 'rm -rf "$BUILD_TEMP"' EXIT
APP="$BUILD_TEMP/LocalWrite.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LocalWrite "$APP/Contents/MacOS/LocalWrite"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift -module-cache-path "$PWD/.build/clang-cache" scripts/make-icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Finder/file-provider metadata on generated bundles is rejected by codesign.
xattr -cr "$APP"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$APP"
else
    bash scripts/setup-signing.sh
    SIGNING_DIR="$HOME/Library/Application Support/LocalWrite/Signing"
    KEYCHAIN="$SIGNING_DIR/LocalWrite.keychain-db"
    security unlock-keychain -p "$(cat "$SIGNING_DIR/keychain-password")" "$KEYCHAIN"
    SIGNING_HASH=$(cat "$SIGNING_DIR/certificate.sha1")
    # Pin the persistent certificate, not the binary's changing code hash.
    codesign --force --sign "$SIGNING_HASH" --keychain "$KEYCHAIN" \
        --requirements "=designated => identifier \"com.localwrite.mac\" and certificate leaf = H\"$SIGNING_HASH\"" \
        --options runtime --timestamp=none "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
mkdir -p "$PWD/dist"
ditto --norsrc --noextattr "$APP" "$PWD/dist/LocalWrite.app"
xattr -cr "$PWD/dist/LocalWrite.app"
# Also keep the signed bundle in a ZIP so cloud folder metadata cannot taint it.
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$PWD/dist/LocalWrite.zip"
printf '\nBuilt and signed: %s/dist/LocalWrite.app\n' "$PWD"
