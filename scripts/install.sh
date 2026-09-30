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
ditto --norsrc --noextattr dist/LocalWrite.app "$INSTALL_DIR/LocalWrite.app"
xattr -cr "$INSTALL_DIR/LocalWrite.app"
codesign --verify --deep --strict --verbose=2 "$INSTALL_DIR/LocalWrite.app"
open "$INSTALL_DIR/LocalWrite.app" --args --settings
