#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
IDENTITY_CS="$ROOT_DIR/windows/src/OPLFleetAgent.Windows/WindowsProductIdentity.cs"
MANAGER_CS="$ROOT_DIR/windows/src/OPLFleetAgent.Windows/WindowsUpdateManager.cs"
SETTINGS_CS="$ROOT_DIR/windows/src/OPLFleetAgent.Windows/SettingsForm.cs"
PROGRAM_CS="$ROOT_DIR/windows/src/OPLFleetAgent.Windows/Program.cs"
ISS_FILE="$ROOT_DIR/windows/installer/OPLFleetAgent.iss"
FETCH_PS1="$ROOT_DIR/windows/scripts/fetch-winsparkle.ps1"
APPCAST_PS1="$ROOT_DIR/windows/scripts/generate-windows-appcast.ps1"
RELEASE_YML="$ROOT_DIR/.github/workflows/release.yml"

EXPECTED_FEED_URL="https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest/download/windows-appcast.xml"

# 1. Legacy hand-rolled Windows updater files and self-copy worker argument must stay removed.
if [[ -e "$ROOT_DIR/windows/src/OPLFleetAgent.Windows/WindowsUpdateWorker.cs" ]]; then
  echo "Retired hand-rolled WindowsUpdateWorker.cs must not exist." >&2
  exit 1
fi
if [[ -e "$ROOT_DIR/windows/src/OPLFleetAgent.Windows/UpdateModels.cs" ]]; then
  echo "Retired hand-rolled UpdateModels.cs must not exist." >&2
  exit 1
fi
if grep -Fq -- "--apply-update" "$PROGRAM_CS"; then
  echo "Program.cs must not retain retired --apply-update handoff." >&2
  exit 1
fi

# 2. Windows Ed25519 public key must match macOS Sparkle SUPublicEDKey and decode to 32 bytes.
MACOS_PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw "$INFO_PLIST")"
python3 - "$MACOS_PUBLIC_KEY" "$IDENTITY_CS" "$EXPECTED_FEED_URL" <<'PY'
import base64
import re
import sys

macos_pub, identity_path, expected_feed = sys.argv[1:4]
text = open(identity_path, encoding="utf-8").read()

pub_match = re.search(r'WinSparkleEd25519PublicKey\s*=\s*"([^"]+)"', text)
if not pub_match:
    raise SystemExit("WindowsProductIdentity.cs missing WinSparkleEd25519PublicKey")
win_pub = pub_match.group(1)
if win_pub != macos_pub:
    raise SystemExit(f"Windows Ed25519 public key ({win_pub}) != macOS SUPublicEDKey ({macos_pub})")

raw = base64.b64decode(win_pub, validate=True)
if len(raw) != 32:
    raise SystemExit(f"Expected 32-byte Ed25519 public key, got {len(raw)} bytes")

feed_match = re.search(r'WindowsAppcastFeedUrl\s*=\s*"([^"]+)"', text)
if not feed_match or feed_match.group(1) != expected_feed:
    raise SystemExit(f"Unexpected WindowsAppcastFeedUrl: {feed_match.group(1) if feed_match else None}")
PY

# 3. WinSparkle P/Invoke wrapper must wire Ed25519 key, appcast URL, callbacks, and cleanup.
for symbol in \
  'win_sparkle_set_appcast_url' \
  'win_sparkle_set_eddsa_public_key' \
  'win_sparkle_set_app_details' \
  'win_sparkle_set_app_build_version' \
  'win_sparkle_set_registry_path' \
  'win_sparkle_set_automatic_check_for_updates' \
  'win_sparkle_set_update_check_interval' \
  'win_sparkle_set_can_shutdown_callback' \
  'win_sparkle_set_shutdown_request_callback' \
  'win_sparkle_check_update_with_ui' \
  'win_sparkle_init' \
  'win_sparkle_cleanup'
do
  grep -Fq "$symbol" "$MANAGER_CS"
done

# 4. Settings UI must keep native auto-check toggle and manual update trigger.
grep -Fq '自动检查更新' "$SETTINGS_CS"
grep -Fq 'CheckForUpdatesRequested' "$SETTINGS_CS"

# 5. Inno Setup and pinned WinSparkle fetch/signing scripts must enforce SHA-256 and Ed25519 signing.
grep -Fq 'Source: "{#SourceDir}\WinSparkle.dll"; DestDir: "{app}"; Flags: ignoreversion' "$ISS_FILE"
grep -Fq 'LaunchAfterSilentUpdate' "$ISS_FILE"
grep -Fq 'LAUNCHAFTERUPDATE' "$ISS_FILE"
grep -Fq '$winSparkleVersion = "0.9.4"' "$FETCH_PS1"
grep -Fq '6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976' "$FETCH_PS1"
grep -Fq '9b43b1c16ee39fb9a91b5bd75138767898779510e0836be2919250607cdbe8ab' "$FETCH_PS1"
grep -Fq '0c5412c481be6146313a2af46cce4a928913c94754763a75bb11ef15c9097cc3' "$FETCH_PS1"
grep -Fq "$MACOS_PUBLIC_KEY" "$APPCAST_PS1"
grep -Fq 'sparkle:edSignature' "$RELEASE_YML"
grep -Fq 'windows-appcast.xml' "$RELEASE_YML"
grep -Fq 'generate-windows-appcast.ps1' "$RELEASE_YML"

echo "Verified Windows WinSparkle in-app updater contract and Ed25519 key parity."
