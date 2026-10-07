#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache"
BUILD_TEMP=$(mktemp -d /private/tmp/LocalWrite-build.XXXXXX)
DIST_STAGE=""
cleanup() {
    rm -rf "$BUILD_TEMP"
    if [[ -n "$DIST_STAGE" ]]; then rm -rf "$DIST_STAGE"; fi
}
trap cleanup EXIT
APP="$BUILD_TEMP/LocalWrite.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/LocalWrite "$APP/Contents/MacOS/LocalWrite"
cp Resources/Info.plist "$APP/Contents/Info.plist"
install -m 644 .build/checkouts/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"
if [[ -n "${LOCALWRITE_VERSION:-}" ]]; then
    if [[ ! "$LOCALWRITE_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        printf 'Invalid app version.\n' >&2
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LOCALWRITE_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${LOCALWRITE_BUILD_NUMBER:-}" ]]; then
    if [[ ! "$LOCALWRITE_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        printf 'Invalid build number.\n' >&2
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LOCALWRITE_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
SPARKLE_FRAMEWORK="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto --norsrc --noextattr "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# This app is not sandboxed and does not use Sparkle's optional XPC services.
rm -rf "$FRAMEWORK/Versions/B/XPCServices" "$FRAMEWORK/XPCServices"
swift -module-cache-path "$PWD/.build/clang-cache" scripts/make-icon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns "$PWD/.build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
# Finder/file-provider metadata on generated bundles is rejected by codesign.
xattr -cr "$APP"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    SIGNING_OPTIONS=(--sign "$SIGN_IDENTITY")
else
    if [[ -n "${LOCALWRITE_SIGNING_KEYCHAIN:-}" && -n "${LOCALWRITE_SIGNING_HASH:-}" ]]; then
        KEYCHAIN="$LOCALWRITE_SIGNING_KEYCHAIN"
        SIGNING_HASH="$LOCALWRITE_SIGNING_HASH"
    else
        bash scripts/setup-signing.sh
        SIGNING_DIR="$HOME/Library/Application Support/LocalWrite/Signing"
        KEYCHAIN="$SIGNING_DIR/LocalWrite.keychain-db"
        security unlock-keychain -p "$(cat "$SIGNING_DIR/keychain-password")" "$KEYCHAIN"
        SIGNING_HASH=$(cat "$SIGNING_DIR/certificate.sha1")
    fi
    SIGNING_OPTIONS=(--sign "$SIGNING_HASH" --keychain "$KEYCHAIN")
fi
# Sign inside-out; --deep signing can assign the wrong entitlements to helpers.
for SIGNED_COMPONENT in "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK"; do
    codesign --force "${SIGNING_OPTIONS[@]}" --options runtime --timestamp=none \
        --entitlements Resources/LocalDevelopment.entitlements "$SIGNED_COMPONENT"
done
REQUIREMENT_OPTIONS=()
if [[ -n "${SIGNING_HASH:-}" ]]; then
    # Preserve the existing local app identity across local and CI builds.
    REQUIREMENT_OPTIONS=(--requirements "=designated => identifier \"com.localwrite.mac\" and certificate leaf = H\"$SIGNING_HASH\"")
fi
codesign --force "${SIGNING_OPTIONS[@]}" "${REQUIREMENT_OPTIONS[@]}" \
    --options runtime --timestamp=none --entitlements Resources/LocalDevelopment.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
mkdir -p "$PWD/dist"
DIST_STAGE=$(mktemp -d "$PWD/dist/.LocalWrite-build.XXXXXX")
ditto --norsrc --noextattr "$APP" "$DIST_STAGE/LocalWrite.app"
xattr -cr "$DIST_STAGE/LocalWrite.app"
swift -module-cache-path "$PWD/.build/clang-cache" scripts/replace-app.swift \
    "$DIST_STAGE/LocalWrite.app" "$PWD/dist/LocalWrite.app"
xattr -cr "$PWD/dist/LocalWrite.app"
# A cloud file provider can immediately reattach Finder metadata here. The ZIP
# below uses the verified temporary source; installation verifies a clean copy
# staged on the destination volume rather than relying on this generated copy.
# Also keep the signed bundle in a ZIP so cloud folder metadata cannot taint it.
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$PWD/dist/LocalWrite.zip"
printf '\nBuilt and signed: %s/dist/LocalWrite.app\n' "$PWD"
