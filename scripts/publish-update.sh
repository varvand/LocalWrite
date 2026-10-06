#!/bin/bash
set +x
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
: "${LOCALWRITE_SECRET_DIR:?}"
: "${LOCALWRITE_BUILD_NUMBER:?}"
: "${GITHUB_SHA:?}"
: "${RUNNER_TEMP:?}"
python3 scripts/verify-update-archive.py dist/LocalWrite.zip --private-key-file "$LOCALWRITE_SECRET_DIR/update-key" --source
REPOSITORY="varvand/LocalWrite"
TAG="build-$LOCALWRITE_BUILD_NUMBER"
PUBLICATION_TEMP=$(mktemp -d "$RUNNER_TEMP/localwrite-publication.XXXXXX")
trap 'rm -rf "$PUBLICATION_TEMP"' EXIT
ARCHIVES="$PUBLICATION_TEMP/archives"
FEED_CHECKOUT="$PUBLICATION_TEMP/feed"
VERIFIER="$PUBLICATION_TEMP/verify-update-signature"
swiftc scripts/verify-update-signature.swift -o "$VERIFIER"
mkdir -p "$ARCHIVES"
# Authenticate the original feed and archives before any extraction or signing.
HISTORY_OPTIONS=()
if git ls-remote --exit-code --heads "https://github.com/$REPOSITORY.git" updates >/dev/null 2>&1; then
    git clone --quiet --depth 1 --branch updates "https://github.com/$REPOSITORY.git" "$FEED_CHECKOUT"
    python3 scripts/update-history.py prepare --feed "$FEED_CHECKOUT/appcast.xml" \
        --info-plist Resources/Info.plist --build "$LOCALWRITE_BUILD_NUMBER" \
        --archives "$ARCHIVES" --verifier "$VERIFIER"
    HISTORY_OPTIONS=(--history-feed "$FEED_CHECKOUT/appcast.xml")
else
    mkdir -p "$FEED_CHECKOUT"
    git -C "$FEED_CHECKOUT" init --quiet --initial-branch=updates
    git -C "$FEED_CHECKOUT" remote add origin "https://github.com/$REPOSITORY.git"
fi
cp dist/LocalWrite.zip "$ARCHIVES/LocalWrite-$LOCALWRITE_BUILD_NUMBER.zip"
SPARKLE_BIN="$PWD/.build/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$LOCALWRITE_SECRET_DIR/update-key" \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
    --link "https://github.com/$REPOSITORY" --maximum-versions 3 --maximum-deltas 3 "$ARCHIVES"
# Retain authenticated historical URLs/signatures and reject unauthorized entries.
python3 scripts/update-history.py finalize --feed "$ARCHIVES/appcast.xml" \
    --info-plist Resources/Info.plist --build "$LOCALWRITE_BUILD_NUMBER" \
    --archives "$ARCHIVES" --verifier "$VERIFIER" "${HISTORY_OPTIONS[@]}"
"$SPARKLE_BIN/sign_update" --ed-key-file "$LOCALWRITE_SECRET_DIR/update-key" "$ARCHIVES/appcast.xml" >/dev/null
python3 scripts/update-history.py verify --feed "$ARCHIVES/appcast.xml" \
    --info-plist Resources/Info.plist --build "$LOCALWRITE_BUILD_NUMBER" --verifier "$VERIFIER"
if ! gh release view "$TAG" --repo "$REPOSITORY" >/dev/null 2>&1; then
    gh release create "$TAG" --repo "$REPOSITORY" --target "$GITHUB_SHA" \
        --title "LocalWrite $LOCALWRITE_BUILD_NUMBER" --notes "Automatic build from main. Commit: $GITHUB_SHA" --draft
fi
# Upload only explicitly allowed public artifacts. Never upload the build folder
# or signing directory; old archives retain their original release URLs.
gh release upload "$TAG" --repo "$REPOSITORY" --clobber "$ARCHIVES/LocalWrite-$LOCALWRITE_BUILD_NUMBER.zip"
for DELTA in "$ARCHIVES"/*.delta; do
    [[ -f "$DELTA" ]] || continue
    gh release upload "$TAG" --repo "$REPOSITORY" --clobber "$DELTA"
done
gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest
cp "$ARCHIVES/appcast.xml" "$FEED_CHECKOUT/appcast.xml"
git -C "$FEED_CHECKOUT" config user.name 'github-actions[bot]'
git -C "$FEED_CHECKOUT" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -C "$FEED_CHECKOUT" config credential.https://github.com.helper '!gh auth git-credential'
git -C "$FEED_CHECKOUT" add appcast.xml
if ! git -C "$FEED_CHECKOUT" diff --cached --quiet; then
    git -C "$FEED_CHECKOUT" commit --quiet -m "Publish signed update $LOCALWRITE_BUILD_NUMBER"
    git -C "$FEED_CHECKOUT" push origin HEAD:updates
fi
