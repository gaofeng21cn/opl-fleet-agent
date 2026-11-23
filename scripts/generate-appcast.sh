#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
DMG_PATH="${1:-$ROOT_DIR/dist/OPL-Fleet-Agent.dmg}"
OUTPUT_PATH="${2:-${DMG_PATH:h}/appcast.xml}"
RELEASE_TAG="${OPL_FLEET_AGENT_RELEASE_TAG:-}"
REPOSITORY="${OPL_FLEET_AGENT_REPOSITORY:-gaofeng21cn/opl-fleet-agent}"
SPARKLE_ACCOUNT="${OPL_FLEET_AGENT_SPARKLE_ACCOUNT:-opl-fleet-agent}"
SPARKLE_KEY_FILE="${OPL_FLEET_AGENT_SPARKLE_KEY_FILE:-}"
REQUIRE_KEY_ENV="${OPL_FLEET_AGENT_REQUIRE_SPARKLE_KEY_ENV:-0}"
EXPECT_UNIVERSAL="${OPL_FLEET_AGENT_EXPECT_UNIVERSAL:-0}"
RELEASE_NOTES_FILE="${OPL_FLEET_AGENT_RELEASE_NOTES_FILE:-}"
APP_PATH="${OPL_FLEET_AGENT_APP_PATH:-$ROOT_DIR/dist/OPL Fleet Agent.app}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

if [[ -z "$RELEASE_TAG" ]]; then
  if [[ -f "$APP_PATH/Contents/Info.plist" ]]; then
    VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")"
    RELEASE_TAG="v$VERSION"
  else
    echo "OPL_FLEET_AGENT_RELEASE_TAG is required when app bundle is unavailable." >&2
    exit 1
  fi
fi

EXPECTED_VERSION="${RELEASE_TAG#v}"
if [[ -z "$EXPECTED_VERSION" || "$RELEASE_TAG" != "v$EXPECTED_VERSION" ]]; then
  echo "Release tag must look like v<version>, got: $RELEASE_TAG" >&2
  exit 1
fi

SPARKLE_BIN_DIR="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$SPARKLE_BIN_DIR/generate_appcast" ]]; then
  FOUND_TOOL="$(find "$ROOT_DIR/.build/artifacts" -path '*/Sparkle/bin/generate_appcast' -type f -perm -u+x -print -quit 2>/dev/null || true)"
  if [[ -n "$FOUND_TOOL" ]]; then
    SPARKLE_BIN_DIR="${FOUND_TOOL:h}"
  fi
fi

GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
SIGN_UPDATE="$SPARKLE_BIN_DIR/sign_update"
if [[ ! -x "$GENERATE_APPCAST" || ! -x "$SIGN_UPDATE" ]]; then
  echo "Sparkle CLI tools not found under $ROOT_DIR/.build/artifacts. Run swift package resolve first." >&2
  exit 1
fi

if [[ "$REQUIRE_KEY_ENV" == "1" && -z "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_ED25519_PRIVATE_KEY is required for release appcast generation." >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opl-fleet-agent-appcast.XXXXXX")"
cleanup() {
  rm -rf "${TEMP_DIR:?}"
}
trap cleanup EXIT INT TERM

DMG_NAME="${DMG_PATH:t}"
cp "$DMG_PATH" "$TEMP_DIR/$DMG_NAME"

DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/"
RELEASE_PAGE_URL="https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"

APPCAST_ARGS=(
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --link "$RELEASE_PAGE_URL"
  --full-release-notes-url "$RELEASE_PAGE_URL"
)

if [[ -n "$RELEASE_NOTES_FILE" && -f "$RELEASE_NOTES_FILE" ]]; then
  cp "$RELEASE_NOTES_FILE" "$TEMP_DIR/${DMG_NAME:r}.md"
  APPCAST_ARGS+=(--embed-release-notes)
fi

if [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" | \
    "$GENERATE_APPCAST" "${APPCAST_ARGS[@]}" --ed-key-file - "$TEMP_DIR"
elif [[ -n "$SPARKLE_KEY_FILE" ]]; then
  "$GENERATE_APPCAST" "${APPCAST_ARGS[@]}" --ed-key-file "$SPARKLE_KEY_FILE" "$TEMP_DIR"
else
  "$GENERATE_APPCAST" "${APPCAST_ARGS[@]}" --account "$SPARKLE_ACCOUNT" "$TEMP_DIR"
fi

GENERATED_APPCAST="$TEMP_DIR/appcast.xml"
if [[ ! -s "$GENERATED_APPCAST" ]]; then
  echo "Sparkle generate_appcast did not produce $GENERATED_APPCAST." >&2
  exit 1
fi

EXPECTED_BUILD=""
if [[ -f "$APP_PATH/Contents/Info.plist" ]]; then
  EXPECTED_BUILD="$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")"
fi
EXPECTED_LENGTH="$(stat -f%z "$DMG_PATH")"
EXPECTED_URL="${DOWNLOAD_PREFIX}${DMG_NAME}"

ED_SIGNATURE="$(
  python3 - "$GENERATED_APPCAST" "$EXPECTED_VERSION" "$EXPECTED_BUILD" "$EXPECTED_URL" "$EXPECTED_LENGTH" "$EXPECT_UNIVERSAL" <<'PY'
import sys
import xml.etree.ElementTree as ET

appcast_path, expected_version, expected_build, expected_url, expected_length, expect_universal = sys.argv[1:7]
sparkle_ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ns = {"sparkle": sparkle_ns}

tree = ET.parse(appcast_path)
root = tree.getroot()
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit(f"Expected exactly 1 item in appcast.xml, found {len(items)}")

item = items[0]
short_ver = item.findtext("sparkle:shortVersionString", namespaces=ns)
build_ver = item.findtext("sparkle:version", namespaces=ns)
min_sys = item.findtext("sparkle:minimumSystemVersion", namespaces=ns)
hw_req = item.findtext("sparkle:hardwareRequirements", namespaces=ns)
enclosure = item.find("enclosure")

if short_ver != expected_version:
    raise SystemExit(f"Expected sparkle:shortVersionString={expected_version}, got {short_ver!r}")
if expected_build and build_ver != expected_build:
    raise SystemExit(f"Expected sparkle:version={expected_build}, got {build_ver!r}")
if not build_ver:
    raise SystemExit("Missing sparkle:version in appcast item")
if not min_sys:
    raise SystemExit("Missing sparkle:minimumSystemVersion in appcast item")
if expect_universal == "1" and hw_req:
    raise SystemExit(f"Universal release appcast must not restrict hardwareRequirements, got {hw_req!r}")
if enclosure is None:
    raise SystemExit("Missing enclosure element in appcast item")

url = enclosure.attrib.get("url")
length = enclosure.attrib.get("length")
sig = enclosure.attrib.get(f"{{{sparkle_ns}}}edSignature")

if url != expected_url:
    raise SystemExit(f"Expected enclosure url={expected_url}, got {url!r}")
if length != expected_length:
    raise SystemExit(f"Expected enclosure length={expected_length}, got {length!r}")
if not sig:
    raise SystemExit("Missing sparkle:edSignature on enclosure")

print(sig)
PY
)"

if [[ -n "${SPARKLE_ED25519_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_ED25519_PRIVATE_KEY" | \
    "$SIGN_UPDATE" --ed-key-file - --verify "$DMG_PATH" "$ED_SIGNATURE"
elif [[ -n "$SPARKLE_KEY_FILE" ]]; then
  "$SIGN_UPDATE" --ed-key-file "$SPARKLE_KEY_FILE" --verify "$DMG_PATH" "$ED_SIGNATURE"
else
  "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$DMG_PATH" "$ED_SIGNATURE"
fi

mkdir -p "${OUTPUT_PATH:h}"
cp "$GENERATED_APPCAST" "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
