#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Codex TPS.app"
DMG_NAME="${CODEX_TPS_DMG_NAME:-Codex-TPS.dmg}"
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
SIGNING_IDENTITY="${CODEX_TPS_SIGNING_IDENTITY:--}"
SKIP_APP_BUILD="${CODEX_TPS_SKIP_APP_BUILD:-0}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-tps-dmg.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT INT TERM

if [[ "$SKIP_APP_BUILD" == "1" ]]; then
  if [[ ! -d "$DIST_DIR/$APP_NAME" ]]; then
    echo "Prebuilt app not found: $DIST_DIR/$APP_NAME" >&2
    exit 1
  fi
else
  CODEX_TPS_ARCHS="${CODEX_TPS_ARCHS:-arm64 x86_64}" \
    "$ROOT_DIR/scripts/build-app.sh"
fi

ditto "$DIST_DIR/$APP_NAME" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH" "$CHECKSUM_PATH"
hdiutil create \
  -volname "Codex TPS" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$DMG_PATH"
hdiutil verify "$DMG_PATH"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

(
  cd "$DIST_DIR"
  shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256"
)

echo "$DMG_PATH"
echo "$CHECKSUM_PATH"
