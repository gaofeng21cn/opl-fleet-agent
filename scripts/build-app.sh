#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="OPL Fleet Agent.app"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"
SIGNING_IDENTITY="${OPL_FLEET_AGENT_SIGNING_IDENTITY:--}"
EXPECTED_TEAM_ID="${OPL_FLEET_AGENT_EXPECTED_TEAM_ID:-}"
REQUIRE_DEVELOPER_ID="${OPL_FLEET_AGENT_REQUIRE_DEVELOPER_ID:-0}"

if [[ "$REQUIRE_DEVELOPER_ID" == "1" && "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Developer ID signing is required for this build." >&2
  exit 1
fi

cd "$ROOT_DIR"
BUILD_ARGS=(-c release --product OPLFleetAgent)
if [[ -n "${OPL_FLEET_AGENT_ARCHS:-}" ]]; then
  for ARCH in ${=OPL_FLEET_AGENT_ARCHS}; do
    BUILD_ARGS+=(--arch "$ARCH")
  done
fi

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
PROVIDER_BUILD_ARGS=(-c release --product OPLFleetAgentProvider)
if [[ -n "${OPL_FLEET_AGENT_ARCHS:-}" ]]; then
  for ARCH in ${=OPL_FLEET_AGENT_ARCHS}; do
    PROVIDER_BUILD_ARGS+=(--arch "$ARCH")
  done
fi
swift build "${PROVIDER_BUILD_ARGS[@]}"

ICON_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opl-fleet-agent-icon.XXXXXX")"
cleanup() {
  rm -rf "$ICON_TMP_DIR"
}
trap cleanup EXIT INT TERM

ICONSET_DIR="$ICON_TMP_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for ICON_SPEC in \
  "16:icon_16x16.png" \
  "32:icon_16x16@2x.png" \
  "32:icon_32x32.png" \
  "64:icon_32x32@2x.png" \
  "128:icon_128x128.png" \
  "256:icon_128x128@2x.png" \
  "256:icon_256x256.png" \
  "512:icon_256x256@2x.png" \
  "512:icon_512x512.png" \
  "1024:icon_512x512@2x.png"
do
  ICON_SIZE="${ICON_SPEC%%:*}"
  ICON_NAME="${ICON_SPEC#*:}"
  sips -z "$ICON_SIZE" "$ICON_SIZE" "$ROOT_DIR/Resources/AppIcon.png" --out "$ICONSET_DIR/$ICON_NAME" >/dev/null
done

SPARKLE_FRAMEWORK_SRC="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK_SRC" ]]; then
  SPARKLE_FRAMEWORK_SRC="$(find "$ROOT_DIR/.build/artifacts" -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' -type d -print -quit 2>/dev/null || true)"
fi
if [[ -z "$SPARKLE_FRAMEWORK_SRC" || ! -d "$SPARKLE_FRAMEWORK_SRC" ]]; then
  echo "Sparkle.framework not found in SwiftPM artifacts under $ROOT_DIR/.build/artifacts." >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"
ditto "$BIN_DIR/OPLFleetAgent" "$APP_DIR/Contents/MacOS/OPLFleetAgent"
ditto "$BIN_DIR/OPLFleetAgentProvider" "$APP_DIR/Contents/MacOS/OPLFleetAgentProvider"
ditto "$SPARKLE_FRAMEWORK_SRC" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
ditto "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

if [[ -n "${OPL_FLEET_AGENT_ARCHS:-}" ]]; then
  for ARCH in ${=OPL_FLEET_AGENT_ARCHS}; do
    lipo "$APP_DIR/Contents/MacOS/OPLFleetAgent" -verify_arch "$ARCH"
    lipo "$APP_DIR/Contents/MacOS/OPLFleetAgentProvider" -verify_arch "$ARCH"
    lipo "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" -verify_arch "$ARCH"
  done
fi

plutil -lint "$APP_DIR/Contents/Info.plist"
FEED_URL="$(plutil -extract SUFeedURL raw "$APP_DIR/Contents/Info.plist")"
PUBLIC_ED_KEY="$(plutil -extract SUPublicEDKey raw "$APP_DIR/Contents/Info.plist")"
if [[ -z "$FEED_URL" || -z "$PUBLIC_ED_KEY" ]]; then
  echo "Sparkle SUFeedURL and SUPublicEDKey must be configured in Info.plist." >&2
  exit 1
fi

SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

SPARKLE_DEST="$APP_DIR/Contents/Frameworks/Sparkle.framework"
SPARKLE_VER="$SPARKLE_DEST/Versions/B"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_VER/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE_VER/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_VER/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_VER/Updater.app"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_DEST"

codesign "${SIGN_ARGS[@]}" "$APP_DIR/Contents/MacOS/OPLFleetAgentProvider"
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
