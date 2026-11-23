#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
DMG_PATH="${1:-$ROOT_DIR/dist/OPL-Fleet-Agent.dmg}"
CHECKSUM_PATH="${2:-$DMG_PATH.sha256}"
APPCAST_PATH="${3:-${DMG_PATH:h}/appcast.xml}"
EXPECTED_TEAM_ID="${OPL_FLEET_AGENT_EXPECTED_TEAM_ID:-SVVC4TA784}"
EXPECTED_BUNDLE_ID="${OPL_FLEET_AGENT_EXPECTED_BUNDLE_ID:-io.github.gaofeng21cn.opl-fleet-agent}"
EXPECTED_VERSION="${OPL_FLEET_AGENT_EXPECTED_VERSION:-}"
EXPECTED_FEED_URL="${OPL_FLEET_AGENT_EXPECTED_FEED_URL:-https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest/download/appcast.xml}"
REQUIRE_APPCAST="${OPL_FLEET_AGENT_REQUIRE_APPCAST:-0}"
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
ACTUAL_BUILD="$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw "$APP_PATH/Contents/Info.plist")"
ACTUAL_FEED_URL="$(plutil -extract SUFeedURL raw "$APP_PATH/Contents/Info.plist")"
ACTUAL_PUBLIC_ED_KEY="$(plutil -extract SUPublicEDKey raw "$APP_PATH/Contents/Info.plist")"
ACTUAL_AUTO_CHECKS="$(plutil -extract SUEnableAutomaticChecks raw "$APP_PATH/Contents/Info.plist")"
PROVIDER_PATH="$APP_PATH/Contents/MacOS/OPLFleetAgentProvider"
SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
SPARKLE_BIN="$SPARKLE_FRAMEWORK/Versions/B/Sparkle"

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
if [[ "$ACTUAL_FEED_URL" != "$EXPECTED_FEED_URL" ]]; then
  echo "Expected SUFeedURL $EXPECTED_FEED_URL, got ${ACTUAL_FEED_URL:-none}." >&2
  exit 1
fi
if [[ -z "$ACTUAL_PUBLIC_ED_KEY" ]]; then
  echo "SUPublicEDKey is missing from Info.plist." >&2
  exit 1
fi
if [[ "$ACTUAL_AUTO_CHECKS" != "true" ]]; then
  echo "Expected SUEnableAutomaticChecks=true, got ${ACTUAL_AUTO_CHECKS:-none}." >&2
  exit 1
fi
if [[ ! -x "$PROVIDER_PATH" ]]; then
  echo "OPLFleetAgentProvider is missing from the app bundle." >&2
  exit 1
fi
if [[ ! -d "$SPARKLE_FRAMEWORK" || ! -f "$SPARKLE_BIN" ]]; then
  echo "Sparkle.framework is missing from the app bundle." >&2
  exit 1
fi
for SPARKLE_COMPONENT in \
  "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
  "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
  "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate" \
  "$SPARKLE_FRAMEWORK/Versions/B/Updater.app" \
  "$SPARKLE_FRAMEWORK"
do
  codesign --verify --strict --verbose=2 "$SPARKLE_COMPONENT"
done
grep -q '^Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS"
grep -q 'flags=.*runtime' <<<"$SIGNATURE_DETAILS"
grep -q '^Timestamp=' <<<"$SIGNATURE_DETAILS"
spctl --assess --type execute --verbose=4 "$APP_PATH"
lipo "$APP_PATH/Contents/MacOS/OPLFleetAgent" -verify_arch arm64 x86_64
lipo "$PROVIDER_PATH" -verify_arch arm64 x86_64
lipo "$SPARKLE_BIN" -verify_arch arm64 x86_64

if [[ "$REQUIRE_APPCAST" == "1" || -f "$APPCAST_PATH" ]]; then
  if [[ ! -f "$APPCAST_PATH" ]]; then
    echo "Release appcast is missing: $APPCAST_PATH" >&2
    exit 1
  fi
  DMG_LENGTH="$(stat -f%z "$DMG_PATH")"
  python3 - "$APPCAST_PATH" "$ACTUAL_VERSION" "$ACTUAL_BUILD" "$DMG_LENGTH" "${DMG_PATH:t}" <<'PY'
import sys
import xml.etree.ElementTree as ET

appcast_path, version, build, dmg_length, dmg_name = sys.argv[1:6]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ns = {"sparkle": sparkle_ns}

root = ET.parse(appcast_path).getroot()
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit(f"Expected 1 appcast item, got {len(items)}")

item = items[0]
if item.findtext("sparkle:shortVersionString", namespaces=ns) != version:
    raise SystemExit("appcast shortVersionString does not match app bundle")
if item.findtext("sparkle:version", namespaces=ns) != build:
    raise SystemExit("appcast version does not match CFBundleVersion")
if item.findtext("sparkle:hardwareRequirements", namespaces=ns):
    raise SystemExit("Universal release appcast must not set hardwareRequirements")

enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("appcast item is missing enclosure")
expected_suffix = f"/releases/download/v{version}/{dmg_name}"
url = enclosure.attrib.get("url", "")
if not url.startswith("https://github.com/") or not url.endswith(expected_suffix):
    raise SystemExit(f"Unexpected appcast enclosure URL: {url}")
if enclosure.attrib.get("length") != dmg_length:
    raise SystemExit("appcast enclosure length does not match DMG size")
if not enclosure.attrib.get(f"{{{sparkle_ns}}}edSignature"):
    raise SystemExit("appcast enclosure is missing sparkle:edSignature")
PY
fi

echo "Verified notarized OPL Fleet Agent $ACTUAL_VERSION (build $ACTUAL_BUILD) with Sparkle for Team $ACTUAL_TEAM_ID."
