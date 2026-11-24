#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
EXPECTED_FEED_URL="https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest/download/appcast.xml"

# 1. Package.swift must keep Sparkle 2 wired into OPLFleetAgent with framework rpath.
grep -Fq 'https://github.com/sparkle-project/Sparkle' "$ROOT_DIR/Package.swift"
grep -Fq '.product(name: "Sparkle", package: "Sparkle")' "$ROOT_DIR/Package.swift"
grep -Fq '@executable_path/../Frameworks' "$ROOT_DIR/Package.swift"

# 2. Info.plist must declare valid Sparkle feed, 32-byte Ed25519 key, and automatic check defaults.
plutil -lint "$INFO_PLIST" >/dev/null
ACTUAL_FEED_URL="$(plutil -extract SUFeedURL raw "$INFO_PLIST")"
ACTUAL_PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw "$INFO_PLIST")"
ACTUAL_AUTO_CHECKS="$(plutil -extract SUEnableAutomaticChecks raw "$INFO_PLIST")"
ACTUAL_AUTO_UPDATE="$(plutil -extract SUAutomaticallyUpdate raw "$INFO_PLIST")"
ACTUAL_VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
ACTUAL_BUILD="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"

if [[ "$ACTUAL_FEED_URL" != "$EXPECTED_FEED_URL" ]]; then
  echo "Unexpected SUFeedURL in Info.plist: ${ACTUAL_FEED_URL:-none}" >&2
  exit 1
fi
if [[ "$ACTUAL_AUTO_CHECKS" != "true" ]]; then
  echo "Expected SUEnableAutomaticChecks=true, got ${ACTUAL_AUTO_CHECKS:-none}" >&2
  exit 1
fi
if [[ "$ACTUAL_AUTO_UPDATE" != "false" ]]; then
  echo "Expected SUAutomaticallyUpdate=false, got ${ACTUAL_AUTO_UPDATE:-none}" >&2
  exit 1
fi
python3 - "$ACTUAL_PUBLIC_KEY" <<'PY'
import base64
import sys

raw = base64.b64decode(sys.argv[1], validate=True)
if len(raw) != 32:
    raise SystemExit(f"Expected 32-byte Ed25519 public key, got {len(raw)} bytes")
PY

# 3. Menu-bar panel must provide native in-app updates rather than a Homebrew CLI upgrade command.
if grep -Fq 'brew upgrade --cask' "$ROOT_DIR/Sources/OPLFleetAgent/MonitorPanel.swift"; then
  echo "MonitorPanel.swift must not replace in-app updates with a Homebrew CLI upgrade hint." >&2
  exit 1
fi
grep -Fq 'updater.checkForUpdates' "$ROOT_DIR/Sources/OPLFleetAgent/MonitorPanel.swift"
grep -Fq 'SPUStandardUpdaterController' "$ROOT_DIR/Sources/OPLFleetAgent/AppUpdater.swift"

# 4. Packaging, verification, and release workflow must embed Sparkle and publish signed appcast.xml.
grep -Fq 'Sparkle.framework' "$ROOT_DIR/scripts/build-app.sh"
grep -Fq 'Installer.xpc' "$ROOT_DIR/scripts/build-app.sh"
grep -Fq 'Downloader.xpc' "$ROOT_DIR/scripts/build-app.sh"
grep -Fq 'Autoupdate' "$ROOT_DIR/scripts/build-app.sh"
grep -Fq 'Updater.app' "$ROOT_DIR/scripts/build-app.sh"
grep -Fq 'Sparkle.framework' "$ROOT_DIR/scripts/verify-release.sh"
grep -Fq 'reusable-macos-sparkle-release.yml' "$ROOT_DIR/.github/workflows/release.yml"
grep -Fq 'appcast.xml' "$ROOT_DIR/.github/workflows/release.yml"

# 5. End-to-end appcast generation and cryptographic verification with an ephemeral Ed25519 key.
SPARKLE_GENERATE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ ! -x "$SPARKLE_GENERATE" ]]; then
  echo "Sparkle CLI tools missing under .build/artifacts; run swift package resolve or swift test first." >&2
  exit 1
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/opl-fleet-sparkle-contract.XXXXXX")"
cleanup() {
  rm -rf "${TEMP_ROOT:?}"
}
trap cleanup EXIT INT TERM

EPHEMERAL_KEYS="$(swift -e 'import CryptoKit; import Foundation; let key = Curve25519.Signing.PrivateKey(); print(key.rawRepresentation.base64EncodedString()); print(key.publicKey.rawRepresentation.base64EncodedString())')"
EPHEMERAL_PRIV_KEY="$(printf '%s\n' "$EPHEMERAL_KEYS" | sed -n '1p')"
EPHEMERAL_PUB_KEY="$(printf '%s\n' "$EPHEMERAL_KEYS" | sed -n '2p')"

STAGING="$TEMP_ROOT/staging"
FAKE_APP="$STAGING/OPL Fleet Agent.app"
mkdir -p "$FAKE_APP/Contents/MacOS"
cp "$INFO_PLIST" "$FAKE_APP/Contents/Info.plist"
plutil -replace SUPublicEDKey -string "$EPHEMERAL_PUB_KEY" "$FAKE_APP/Contents/Info.plist"
cp /usr/bin/true "$FAKE_APP/Contents/MacOS/OPLFleetAgent"
chmod +x "$FAKE_APP/Contents/MacOS/OPLFleetAgent"
codesign --force --sign - "$FAKE_APP" >/dev/null 2>&1

FAKE_DMG="$TEMP_ROOT/OPL-Fleet-Agent.dmg"
hdiutil create \
  -volname "OPL Fleet Agent" \
  -srcfolder "$STAGING" \
  -format UDZO \
  -ov \
  "$FAKE_DMG" >/dev/null

OUT_APPCAST="$TEMP_ROOT/appcast.xml"

SPARKLE_ED25519_PRIVATE_KEY="$EPHEMERAL_PRIV_KEY" \
OPL_FLEET_AGENT_RELEASE_TAG="v$ACTUAL_VERSION" \
OPL_FLEET_AGENT_APP_PATH="$FAKE_APP" \
OPL_FLEET_AGENT_REQUIRE_SPARKLE_KEY_ENV=1 \
  "$ROOT_DIR/scripts/generate-appcast.sh" "$FAKE_DMG" "$OUT_APPCAST" >/dev/null

[[ -s "$OUT_APPCAST" ]]
grep -Fq "<sparkle:version>$ACTUAL_BUILD</sparkle:version>" "$OUT_APPCAST"
grep -Fq "<sparkle:shortVersionString>$ACTUAL_VERSION</sparkle:shortVersionString>" "$OUT_APPCAST"
grep -Fq 'sparkle:edSignature="' "$OUT_APPCAST"

# Negative check: mismatched private key must fail closed rather than emitting an unsigned appcast.
WRONG_PRIV_KEY="$(openssl rand -base64 32)"
if SPARKLE_ED25519_PRIVATE_KEY="$WRONG_PRIV_KEY" \
  OPL_FLEET_AGENT_RELEASE_TAG="v$ACTUAL_VERSION" \
  OPL_FLEET_AGENT_APP_PATH="$FAKE_APP" \
  OPL_FLEET_AGENT_REQUIRE_SPARKLE_KEY_ENV=1 \
  "$ROOT_DIR/scripts/generate-appcast.sh" "$FAKE_DMG" "$TEMP_ROOT/wrong-appcast.xml" >/dev/null 2>&1
then
  echo "generate-appcast.sh unexpectedly accepted a mismatched Ed25519 key." >&2
  exit 1
fi

echo "Verified macOS Sparkle in-app updater contract and signed appcast generation for v$ACTUAL_VERSION ($ACTUAL_BUILD)."
