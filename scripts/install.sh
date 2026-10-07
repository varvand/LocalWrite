#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -d dist/LocalWrite.app ]]; then bash scripts/build.sh; fi
if pgrep -x LocalWrite >/dev/null; then
    printf 'Quit LocalWrite from the menu bar before installing a new build.\n' >&2
    exit 1
fi
INSTALL_DIR="${LOCALWRITE_INSTALL_DIR:-/Applications}"
mkdir -p "$INSTALL_DIR"
INSTALL_STAGE=$(mktemp -d "$INSTALL_DIR/.LocalWrite-install.XXXXXX")
trap 'rm -rf "$INSTALL_STAGE"' EXIT
ditto --norsrc --noextattr dist/LocalWrite.app "$INSTALL_STAGE/LocalWrite.app"
xattr -cr "$INSTALL_STAGE/LocalWrite.app"
codesign --verify --deep --strict --verbose=2 "$INSTALL_STAGE/LocalWrite.app"
swift -module-cache-path "$PWD/.build/clang-cache" scripts/replace-app.swift \
    "$INSTALL_STAGE/LocalWrite.app" "$INSTALL_DIR/LocalWrite.app"
xattr -cr "$INSTALL_DIR/LocalWrite.app"
codesign --verify --deep --strict --verbose=2 "$INSTALL_DIR/LocalWrite.app"
open "$INSTALL_DIR/LocalWrite.app" --args --settings
