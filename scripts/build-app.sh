#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="OPL Fleet Agent.app"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"
SIGNING_IDENTITY="${CODEX_TPS_SIGNING_IDENTITY:--}"
EXPECTED_TEAM_ID="${CODEX_TPS_EXPECTED_TEAM_ID:-}"
REQUIRE_DEVELOPER_ID="${CODEX_TPS_REQUIRE_DEVELOPER_ID:-0}"

if [[ "$REQUIRE_DEVELOPER_ID" == "1" && "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Developer ID signing is required for this build." >&2
  exit 1
fi

cd "$ROOT_DIR"
BUILD_ARGS=(-c release --product CodexTPS)
if [[ -n "${CODEX_TPS_ARCHS:-}" ]]; then
  for ARCH in ${=CODEX_TPS_ARCHS}; do
    BUILD_ARGS+=(--arch "$ARCH")
  done
fi

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
ditto "$BIN_DIR/CodexTPS" "$APP_DIR/Contents/MacOS/CodexTPS"
ditto "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
ditto "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
ditto "$ROOT_DIR/scripts/install-release.sh" "$APP_DIR/Contents/Resources/install-release.sh"
chmod 755 "$APP_DIR/Contents/Resources/install-release.sh"

if [[ -n "${CODEX_TPS_ARCHS:-}" ]]; then
  for ARCH in ${=CODEX_TPS_ARCHS}; do
    lipo "$APP_DIR/Contents/MacOS/CodexTPS" -verify_arch "$ARCH"
  done
fi

plutil -lint "$APP_DIR/Contents/Info.plist"
SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
  ACTUAL_TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE_DETAILS")"
  grep -q '^Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS"
  grep -q 'flags=.*runtime' <<<"$SIGNATURE_DETAILS"
  grep -q '^Timestamp=' <<<"$SIGNATURE_DETAILS"
  if [[ -n "$EXPECTED_TEAM_ID" && "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
    echo "Expected Team ID $EXPECTED_TEAM_ID, got ${ACTUAL_TEAM_ID:-none}." >&2
    exit 1
  fi
fi

echo "$APP_DIR"
