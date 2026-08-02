#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
INSTALL_DIR="${CODEX_TPS_INSTALL_DIR:-/Applications}"
SOURCE_APP="$ROOT_DIR/dist/OPL Fleet Agent.app"
DEST_APP="$INSTALL_DIR/OPL Fleet Agent.app"
LEGACY_APP="$INSTALL_DIR/Codex TPS.app"

"$ROOT_DIR/scripts/build-app.sh"

mkdir -p "$INSTALL_DIR"
pkill -x CodexTPS 2>/dev/null || true
rm -rf "$DEST_APP"
rm -rf "$LEGACY_APP"
ditto "$SOURCE_APP" "$DEST_APP"
codesign --verify --deep --strict "$DEST_APP"

if [[ "${1:-}" != "--no-launch" ]]; then
  open "$DEST_APP"
fi

echo "$DEST_APP"
