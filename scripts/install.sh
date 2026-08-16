#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
INSTALL_DIR="${OPL_FLEET_AGENT_INSTALL_DIR:-/Applications}"
SOURCE_APP="$ROOT_DIR/dist/OPL Fleet Agent.app"
DEST_APP="$INSTALL_DIR/OPL Fleet Agent.app"

"$ROOT_DIR/scripts/build-app.sh"

mkdir -p "$INSTALL_DIR"
pkill -x CodexTPS 2>/dev/null || true
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
codesign --verify --deep --strict "$DEST_APP"

if [[ "${1:-}" != "--no-launch" ]]; then
  open "$DEST_APP"
fi

echo "$DEST_APP"
