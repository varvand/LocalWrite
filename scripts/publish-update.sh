#!/bin/bash
set +x
set -euo pipefail
cd "$(dirname "$0")/.."
: "${LOCALWRITE_SECRET_DIR:?}"
: "${LOCALWRITE_BUILD_NUMBER:?}"
: "${GITHUB_SHA:?}"
python3 scripts/verify-update-archive.py dist/LocalWrite.zip --private-key-file "$LOCALWRITE_SECRET_DIR/update-key" --source
REPOSITORY="varvand/LocalWrite"
TAG="build-$LOCALWRITE_BUILD_NUMBER"
ARCHIVES="$RUNNER_TEMP/localwrite-updates"
FEED_CHECKOUT="$RUNNER_TEMP/localwrite-feed"
mkdir -p "$ARCHIVES"
# Reuse recent official archives to generate small signed delta updates.
if git ls-remote --exit-code --heads "https://github.com/$REPOSITORY.git" updates >/dev/null 2>&1; then
    git clone --quiet --depth 1 --branch updates "https://github.com/$REPOSITORY.git" "$FEED_CHECKOUT"
    cp "$FEED_CHECKOUT/appcast.xml" "$ARCHIVES/appcast.xml"
    gh release list --repo "$REPOSITORY" --limit 10 --json tagName,isDraft \
        --jq '.[] | select(.isDraft == false and (.tagName | startswith("build-"))) | .tagName' | head -n 3 > "$RUNNER_TEMP/localwrite-previous-tags"
    while IFS= read -r PREVIOUS_TAG; do
        if [[ "$PREVIOUS_TAG" != "$TAG" ]]; then
            gh release download "$PREVIOUS_TAG" --repo "$REPOSITORY" --pattern 'LocalWrite-*.zip' --dir "$ARCHIVES" --skip-existing
        fi
    done < "$RUNNER_TEMP/localwrite-previous-tags"
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
"$SPARKLE_BIN/sign_update" --verify --ed-key-file "$LOCALWRITE_SECRET_DIR/update-key" "$ARCHIVES/appcast.xml"
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
