#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/opl-fleet-agent-notary-test.XXXXXX")"
TEST_ROOT="${TEST_ROOT:A}"
cleanup() {
  rm -rf "${TEST_ROOT:?}"
}
trap cleanup EXIT INT TERM

SANDBOX="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
CALL_LOG="$TEST_ROOT/calls.log"
mkdir -p "$SANDBOX/scripts" "$SANDBOX/dist/OPL Fleet Agent.app" "$FAKE_BIN"
cp "$ROOT_DIR/scripts/notarize-dmg.sh" "$SANDBOX/scripts/notarize-dmg.sh"

cat >"$FAKE_BIN/xcrun" <<'EOF'
#!/bin/zsh
set -euo pipefail
print -r -- "xcrun $*" >>"$NOTARY_TEST_LOG"
if [[ "$1 $2" == "notarytool submit" ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>id</key><string>00000000-0000-0000-0000-000000000001</string></dict></plist>
PLIST
elif [[ "$1 $2" == "notarytool wait" || "$1 $2" == "notarytool info" ]]; then
  cat <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>status</key><string>Accepted</string></dict></plist>
PLIST
fi
EOF

cat >"$FAKE_BIN/ditto" <<'EOF'
#!/bin/zsh
set -euo pipefail
print -r -- "ditto $*" >>"$NOTARY_TEST_LOG"
touch "${@[-1]}"
EOF

cat >"$TEST_ROOT/build-dmg" <<'EOF'
#!/bin/zsh
set -euo pipefail
print -r -- "build-dmg skip=${OPL_FLEET_AGENT_SKIP_APP_BUILD:-} name=${OPL_FLEET_AGENT_DMG_NAME:-}" >>"$NOTARY_TEST_LOG"
touch "$NOTARY_TEST_DMG"
EOF

chmod +x "$SANDBOX/scripts/notarize-dmg.sh" "$FAKE_BIN/xcrun" "$FAKE_BIN/ditto" "$TEST_ROOT/build-dmg"

NOTARY_TEST_LOG="$CALL_LOG" \
NOTARY_TEST_DMG="$SANDBOX/dist/OPL-Fleet-Agent.dmg" \
OPL_FLEET_AGENT_NOTARY_PROFILE="test-profile" \
OPL_FLEET_AGENT_BUILD_DMG_SCRIPT="$TEST_ROOT/build-dmg" \
TMPDIR="$TEST_ROOT" \
PATH="$FAKE_BIN:$PATH" \
  "$SANDBOX/scripts/notarize-dmg.sh" >/dev/null

line_for() {
  local pattern="$1"
  local line
  line="$(grep -n -m 1 -F "$pattern" "$CALL_LOG" | cut -d: -f1 || true)"
  if [[ -z "$line" ]]; then
    echo "Missing call matching: $pattern" >&2
    cat "$CALL_LOG" >&2
    exit 1
  fi
  echo "$line"
}

APP_SUBMIT="$(line_for "notarytool submit $TEST_ROOT/")"
APP_STAPLE="$(line_for "stapler staple $SANDBOX/dist/OPL Fleet Agent.app")"
APP_VALIDATE="$(line_for "stapler validate $SANDBOX/dist/OPL Fleet Agent.app")"
BUILD_DMG="$(line_for "build-dmg skip=1 name=OPL-Fleet-Agent.dmg")"
DMG_SUBMIT="$(line_for "notarytool submit $SANDBOX/dist/OPL-Fleet-Agent.dmg")"
DMG_STAPLE="$(line_for "stapler staple $SANDBOX/dist/OPL-Fleet-Agent.dmg")"
DMG_VALIDATE="$(line_for "stapler validate $SANDBOX/dist/OPL-Fleet-Agent.dmg")"

if ! (( APP_SUBMIT < APP_STAPLE && APP_STAPLE < APP_VALIDATE && APP_VALIDATE < BUILD_DMG \
  && BUILD_DMG < DMG_SUBMIT && DMG_SUBMIT < DMG_STAPLE && DMG_STAPLE < DMG_VALIDATE )); then
  echo "Notarization calls are out of order." >&2
  cat "$CALL_LOG" >&2
  exit 1
fi

[[ -s "$SANDBOX/dist/OPL-Fleet-Agent.dmg.sha256" ]]
echo "Verified OPL Fleet Agent app-first notarization and dual stapling sequence."

grep -Fq 'OPL_FLEET_AGENT_ARCHS="arm64 x86_64" ./scripts/build-app.sh' \
  "$ROOT_DIR/.github/workflows/release.yml"
echo "Verified the release workflow requests a universal macOS binary."
