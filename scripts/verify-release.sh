#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
DMG_PATH="${1:-$ROOT_DIR/dist/OPL-Fleet-Agent.dmg}"
CHECKSUM_PATH="${2:-$DMG_PATH.sha256}"
EXPECTED_TEAM_ID="${OPL_FLEET_AGENT_EXPECTED_TEAM_ID:-SVVC4TA784}"
EXPECTED_BUNDLE_ID="${OPL_FLEET_AGENT_EXPECTED_BUNDLE_ID:-io.github.gaofeng21cn.opl-fleet-agent}"
EXPECTED_VERSION="${OPL_FLEET_AGENT_EXPECTED_VERSION:-}"
MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/opl-fleet-agent-verify.XXXXXX")"
ATTACHED=0

cleanup() {
  if [[ "$ATTACHED" == "1" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$MOUNT_POINT"
}
trap cleanup EXIT INT TERM

if [[ ! -f "$DMG_PATH" || ! -f "$CHECKSUM_PATH" ]]; then
  echo "Release DMG or checksum is missing." >&2
  exit 1
fi

(
  cd "${DMG_PATH:h}"
  shasum -a 256 -c "${CHECKSUM_PATH:t}"
)
hdiutil verify "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
ATTACHED=1
APP_PATH="$MOUNT_POINT/OPL Fleet Agent.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "OPL Fleet Agent.app is missing from the DMG." >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
xcrun stapler validate "$APP_PATH"
SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1)"
ACTUAL_TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE_DETAILS")"
ACTUAL_BUNDLE_ID="$(sed -n 's/^Identifier=//p' <<<"$SIGNATURE_DETAILS")"
ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw "$APP_PATH/Contents/Info.plist")"
PROVIDER_PATH="$APP_PATH/Contents/MacOS/OPLFleetAgentProvider"

if [[ "$ACTUAL_TEAM_ID" != "$EXPECTED_TEAM_ID" ]]; then
  echo "Expected Team ID $EXPECTED_TEAM_ID, got ${ACTUAL_TEAM_ID:-none}." >&2
  exit 1
fi
if [[ "$ACTUAL_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Expected bundle ID $EXPECTED_BUNDLE_ID, got ${ACTUAL_BUNDLE_ID:-none}." >&2
  exit 1
fi
if [[ -n "$EXPECTED_VERSION" && "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Expected version $EXPECTED_VERSION, got $ACTUAL_VERSION." >&2
  exit 1
fi
if [[ "$DISPLAY_NAME" != "OPL Fleet Agent" ]]; then
  echo "Expected display name OPL Fleet Agent, got $DISPLAY_NAME." >&2
  exit 1
fi
if [[ ! -x "$PROVIDER_PATH" ]]; then
  echo "OPLFleetAgentProvider is missing from the app bundle." >&2
  exit 1
fi
grep -q '^Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS"
grep -q 'flags=.*runtime' <<<"$SIGNATURE_DETAILS"
grep -q '^Timestamp=' <<<"$SIGNATURE_DETAILS"
spctl --assess --type execute --verbose=4 "$APP_PATH"
lipo "$APP_PATH/Contents/MacOS/OPLFleetAgent" -verify_arch arm64 x86_64
lipo "$PROVIDER_PATH" -verify_arch arm64 x86_64

echo "Verified notarized OPL Fleet Agent $ACTUAL_VERSION for Team $ACTUAL_TEAM_ID."
