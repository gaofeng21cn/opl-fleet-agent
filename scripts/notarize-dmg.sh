#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
DMG_PATH="${1:-$ROOT_DIR/dist/OPL-Fleet-Agent.dmg}"
CHECKSUM_PATH="${2:-$DMG_PATH.sha256}"
APP_PATH="${OPL_FLEET_AGENT_APP_PATH:-$ROOT_DIR/dist/OPL Fleet Agent.app}"
BUILD_DMG_SCRIPT="${OPL_FLEET_AGENT_BUILD_DMG_SCRIPT:-$ROOT_DIR/scripts/build-dmg.sh}"
NOTARY_PROFILE="${OPL_FLEET_AGENT_NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${OPL_FLEET_AGENT_NOTARY_KEYCHAIN:-}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Signed app not found: $APP_PATH" >&2
  exit 1
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "OPL_FLEET_AGENT_NOTARY_PROFILE is required." >&2
  exit 1
fi
if [[ "${DMG_PATH:h}" != "$ROOT_DIR/dist" ]]; then
  echo "DMG must be created in $ROOT_DIR/dist: $DMG_PATH" >&2
  exit 1
fi
if [[ ! -x "$BUILD_DMG_SCRIPT" ]]; then
  echo "DMG builder is not executable: $BUILD_DMG_SCRIPT" >&2
  exit 1
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/opl-fleet-agent-notary.XXXXXX")"
APP_ZIP="$TEMP_ROOT/OPL-Fleet-Agent-app.zip"
cleanup() {
  rm -rf "${TEMP_ROOT:?}"
}
trap cleanup EXIT INT TERM

NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
  NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
fi

submit_and_wait() {
  local artifact="$1"
  local label="$2"
  local submit_plist="$TEMP_ROOT/$label-submit.plist"
  local result_plist="$TEMP_ROOT/$label-result.plist"
  local submission_id
  local wait_status

  xcrun notarytool submit "$artifact" \
    "${NOTARY_ARGS[@]}" \
    --output-format plist >"$submit_plist"
  submission_id="$(plutil -extract id raw -o - "$submit_plist")"
  echo "$label notarization submitted: $submission_id" >&2

  set +e
  xcrun notarytool wait "$submission_id" \
    "${NOTARY_ARGS[@]}" \
    --timeout 30m \
    --output-format plist >"$result_plist"
  wait_status=$?
  set -e

  if [[ "$wait_status" -ne 0 ]]; then
    xcrun notarytool info "$submission_id" \
      "${NOTARY_ARGS[@]}" \
      --output-format plist >"$result_plist" || true
  fi

  local notary_status
  notary_status="$(plutil -extract status raw -o - "$result_plist")"
  if [[ "$notary_status" != "Accepted" ]]; then
    echo "$label notarization $submission_id is not accepted; current status: $notary_status." >&2
    plutil -p "$result_plist" >&2
    exit 1
  fi
  echo "$submission_id"
}

ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
APP_SUBMISSION_ID="$(submit_and_wait "$APP_ZIP" app)"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

OPL_FLEET_AGENT_SKIP_APP_BUILD=1 \
OPL_FLEET_AGENT_DMG_NAME="${DMG_PATH:t}" \
  "$BUILD_DMG_SCRIPT"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG was not created: $DMG_PATH" >&2
  exit 1
fi

DMG_SUBMISSION_ID="$(submit_and_wait "$DMG_PATH" dmg)"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

(
  cd "${DMG_PATH:h}"
  shasum -a 256 "${DMG_PATH:t}" >"${CHECKSUM_PATH:t}"
)

echo "App notarization accepted: $APP_SUBMISSION_ID"
echo "DMG notarization accepted: $DMG_SUBMISSION_ID"
echo "$DMG_PATH"
echo "$CHECKSUM_PATH"
