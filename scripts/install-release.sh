#!/bin/bash
set -euo pipefail

REPOSITORY="gaofeng21cn/opl-fleet-agent"
EXPECTED_TEAM_ID="SVVC4TA784"
EXPECTED_BUNDLE_ID="io.github.gaofeng21cn.opl-fleet-agent"
INSTALL_DIR="${OPL_FLEET_AGENT_INSTALL_DIR:-/Applications}"
RUNNING_PID="${OPL_FLEET_AGENT_RUNNING_PID:-}"
RUNNING_APP="${OPL_FLEET_AGENT_RUNNING_APP:-}"
OPEN_COMMAND="${OPL_FLEET_AGENT_OPEN_COMMAND:-/usr/bin/open}"
UPDATER_TEST_ROOT="${OPL_FLEET_AGENT_UPDATER_TEST_ROOT:-}"
DMG_URL="${OPL_FLEET_AGENT_DMG_URL:-https://github.com/$REPOSITORY/releases/latest/download/OPL-Fleet-Agent.dmg}"
CHECKSUM_URL="${OPL_FLEET_AGENT_CHECKSUM_URL:-https://github.com/$REPOSITORY/releases/latest/download/OPL-Fleet-Agent.dmg.sha256}"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opl-fleet-agent-install.XXXXXX")"
DMG_PATH="$TEMP_DIR/OPL-Fleet-Agent.dmg"
CHECKSUM_PATH="$TEMP_DIR/OPL-Fleet-Agent.dmg.sha256"
MOUNT_POINT=""
DEST_APP="$INSTALL_DIR/OPL Fleet Agent.app"
STAGED_APP="$INSTALL_DIR/.OPL Fleet Agent.app.update.$$"
BACKUP_APP="$INSTALL_DIR/.OPL Fleet Agent.app.backup.$$"
REPLACEMENT_STARTED=0
HAD_EXISTING_APP=0
NEW_PID=""
ROLLBACK_PID=""
ALLOW_AD_HOC_TEST=0

cleanup() {
  local exit_status=$?

  if [[ "$exit_status" -ne 0 && "$REPLACEMENT_STARTED" -eq 1 ]]; then
    rollback_replacement || true
  fi

  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGED_APP"
  if [[ "$exit_status" -eq 0 ]]; then
    rm -rf "$BACKUP_APP"
  fi
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

download() {
  curl --fail --location --silent --show-error --retry 3 "$1" --output "$2"
}

verify_app() {
  local app_path="$1"
  local signature_details actual_team_id actual_bundle_id

  codesign --verify --deep --strict "$app_path"
  signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
  actual_team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"$signature_details")"
  actual_bundle_id="$(sed -n 's/^Identifier=//p' <<<"$signature_details")"
  if [[ "$actual_bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "OPL Fleet Agent bundle ID verification failed." >&2
    return 1
  fi
  if [[ "$ALLOW_AD_HOC_TEST" -eq 1 ]]; then
    grep -q '^Signature=adhoc$' <<<"$signature_details"
    return
  fi
  if [[ "$actual_team_id" != "$EXPECTED_TEAM_ID" ]]; then
    echo "OPL Fleet Agent Team ID verification failed." >&2
    return 1
  fi
  grep -q '^Authority=Developer ID Application:' <<<"$signature_details"
  grep -q 'flags=.*runtime' <<<"$signature_details"
  grep -q '^Timestamp=' <<<"$signature_details"
  spctl --assess --type execute --verbose=2 "$app_path"
}

configure_updater_test_trust() {
  local resolved_test_root resolved_install_dir

  [[ -n "$UPDATER_TEST_ROOT" ]] || return 0
  if [[ ! -d "$UPDATER_TEST_ROOT" || ! -d "$INSTALL_DIR" ]]; then
    echo "OPL Fleet Agent updater test trust mode requires existing test directories." >&2
    return 1
  fi
  resolved_test_root="$(cd "$UPDATER_TEST_ROOT" && /bin/pwd -P)"
  resolved_install_dir="$(cd "$INSTALL_DIR" && /bin/pwd -P)"
  if [[ "$resolved_test_root" == "/" ]]; then
    echo "OPL Fleet Agent updater test trust mode received an unsafe test root." >&2
    return 1
  fi
  case "$resolved_install_dir/" in
    "$resolved_test_root"/*) ;;
    *)
      echo "OPL Fleet Agent updater test trust mode is restricted to its test root." >&2
      return 1
      ;;
  esac
  case "$RUNNING_APP/" in
    "$resolved_test_root"/*) ;;
    *)
      echo "OPL Fleet Agent updater test trust mode requires a test app path." >&2
      return 1
      ;;
  esac
  case "$OPEN_COMMAND" in
    "$resolved_test_root"/*) ;;
    *)
      echo "OPL Fleet Agent updater test trust mode requires a test launch command." >&2
      return 1
      ;;
  esac
  if [[ "$DMG_URL" != file://* || "$CHECKSUM_URL" != file://* ]]; then
    echo "OPL Fleet Agent updater test trust mode accepts only local artifacts." >&2
    return 1
  fi
  ALLOW_AD_HOC_TEST=1
}

process_matches_app() {
  local pid="$1"
  local app_path="$2"
  local command expected_executable

  command="$(ps -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  expected_executable="$app_path/Contents/MacOS/OPLFleetAgent"
  [[ "$command" == "$expected_executable" || "$command" == "$expected_executable "* ]]
}

wait_for_exit() {
  local pid="$1"

  for ((attempt = 0; attempt < 50; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

stop_process() {
  local pid="$1"
  local app_path="$2"

  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  if ! process_matches_app "$pid" "$app_path"; then
    echo "OPL Fleet Agent updater refused to stop an unexpected process." >&2
    return 1
  fi

  kill -TERM "$pid" 2>/dev/null || true
  if wait_for_exit "$pid"; then
    return 0
  fi

  if ! process_matches_app "$pid" "$app_path"; then
    echo "OPL Fleet Agent process identity changed while stopping it." >&2
    return 1
  fi
  kill -KILL "$pid" 2>/dev/null || true
  if wait_for_exit "$pid"; then
    return 0
  fi

  echo "OPL Fleet Agent process $pid could not be stopped for the update." >&2
  return 1
}

stop_processes_for_app() {
  local app_path="$1"
  local pid
  local result=0

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if process_matches_app "$pid" "$app_path"; then
      stop_process "$pid" "$app_path" || result=1
    fi
  done < <(pgrep -x OPLFleetAgent 2>/dev/null || true)

  return "$result"
}

validate_running_process_contract() {
  if [[ -z "$RUNNING_PID" && -z "$RUNNING_APP" ]]; then
    return 0
  fi
  if [[ -z "$RUNNING_PID" || -z "$RUNNING_APP" ]]; then
    echo "OPL Fleet Agent updater requires both the running process ID and app path." >&2
    return 1
  fi
  if [[ ! "$RUNNING_PID" =~ ^[0-9]+$ ]]; then
    echo "OPL Fleet Agent updater received an invalid process ID." >&2
    return 1
  fi
  if [[ "$RUNNING_APP" != "$DEST_APP" ]]; then
    echo "OPL Fleet Agent updater refused to replace a different app path." >&2
    return 1
  fi
  if ! kill -0 "$RUNNING_PID" 2>/dev/null; then
    echo "OPL Fleet Agent running process is no longer available." >&2
    return 1
  fi
  if ! process_matches_app "$RUNNING_PID" "$RUNNING_APP"; then
    echo "OPL Fleet Agent updater refused an unexpected running process." >&2
    return 1
  fi
}

stop_running_app() {
  if [[ -n "$RUNNING_PID" ]]; then
    validate_running_process_contract
    stop_process "$RUNNING_PID" "$RUNNING_APP"
    stop_processes_for_app "$RUNNING_APP"
    return
  fi

  stop_processes_for_app "$DEST_APP"
}

running_process_for_app() {
  local app_path="$1"
  local excluded_pid="${2:-}"
  local pid

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    [[ -z "$excluded_pid" || "$pid" != "$excluded_pid" ]] || continue
    if process_matches_app "$pid" "$app_path"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <(pgrep -x OPLFleetAgent 2>/dev/null || true)
  return 1
}

wait_for_launch() {
  local app_path="$1"
  local excluded_pid="${2:-}"
  local pid

  for ((attempt = 0; attempt < 100; attempt++)); do
    pid="$(running_process_for_app "$app_path" "$excluded_pid")" || {
      sleep 0.1
      continue
    }
    sleep 2
    if kill -0 "$pid" 2>/dev/null && process_matches_app "$pid" "$app_path"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

launch_app_and_wait() {
  local app_path="$1"
  local excluded_pid="${2:-}"

  "$OPEN_COMMAND" "$app_path" >/dev/null 2>&1 || return 1
  wait_for_launch "$app_path" "$excluded_pid"
}

rollback_replacement() {
  if ! stop_processes_for_app "$DEST_APP"; then
    echo "OPL Fleet Agent could not safely stop the replacement; backup remains at $BACKUP_APP." >&2
    return 1
  fi

  if ! rm -rf "$DEST_APP"; then
    echo "OPL Fleet Agent could not remove the failed replacement; backup remains at $BACKUP_APP." >&2
    return 1
  fi
  if [[ -d "$BACKUP_APP" ]]; then
    if ! mv "$BACKUP_APP" "$DEST_APP"; then
      echo "OPL Fleet Agent could not restore the backup at $BACKUP_APP." >&2
      return 1
    fi
  elif [[ "$HAD_EXISTING_APP" -eq 1 ]]; then
    echo "OPL Fleet Agent backup is missing; automatic rollback is unavailable." >&2
    return 1
  fi
  REPLACEMENT_STARTED=0

  if [[ "$HAD_EXISTING_APP" -eq 1 ]] \
    && [[ "${OPL_FLEET_AGENT_NO_LAUNCH:-0}" != "1" ]]
  then
    if ! ROLLBACK_PID="$(launch_app_and_wait "$DEST_APP" "$RUNNING_PID")"; then
      echo "OPL Fleet Agent was restored but could not be relaunched." >&2
      return 1
    fi
    echo "Restored the previous OPL Fleet Agent as process $ROLLBACK_PID." >&2
  fi
}

configure_updater_test_trust
validate_running_process_contract
if [[ "${OPL_FLEET_AGENT_NO_LAUNCH:-0}" != "1" && ! -x "$OPEN_COMMAND" ]]; then
  echo "OPL Fleet Agent launch command is unavailable." >&2
  exit 1
fi

echo "Downloading the latest OPL Fleet Agent release..."
download "$DMG_URL" "$DMG_PATH"
download "$CHECKSUM_URL" "$CHECKSUM_PATH"

EXPECTED_HASH="$(awk 'NR == 1 { print $1 }' "$CHECKSUM_PATH" | tr '[:upper:]' '[:lower:]')"
ACTUAL_HASH="$(shasum -a 256 "$DMG_PATH" | awk '{ print $1 }')"
if [[ ! "$EXPECTED_HASH" =~ ^[0-9a-f]{64}$ ]] || [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
  echo "OPL Fleet Agent DMG checksum verification failed." >&2
  exit 1
fi

ATTACH_OUTPUT="$(hdiutil attach "$DMG_PATH" -readonly -nobrowse)"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk -F '\t' '$NF ~ /^\/Volumes\// { print $NF; exit }')"
SOURCE_APP="$MOUNT_POINT/OPL Fleet Agent.app"

if [[ -z "$MOUNT_POINT" ]] || [[ ! -d "$SOURCE_APP" ]]; then
  echo "OPL Fleet Agent.app was not found in the mounted DMG." >&2
  exit 1
fi

verify_app "$SOURCE_APP"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$SOURCE_APP/Contents/Info.plist")"
if [[ -n "${OPL_FLEET_AGENT_EXPECTED_VERSION:-}" && "$VERSION" != "$OPL_FLEET_AGENT_EXPECTED_VERSION" ]]; then
  echo "Expected OPL Fleet Agent $OPL_FLEET_AGENT_EXPECTED_VERSION, but the DMG contains $VERSION." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
if [[ ! -w "$INSTALL_DIR" ]]; then
  echo "No write permission for $INSTALL_DIR." >&2
  echo "Use OPL_FLEET_AGENT_INSTALL_DIR=\"$HOME/Applications\" to install for this user." >&2
  exit 1
fi

rm -rf "$STAGED_APP" "$BACKUP_APP"
ditto "$SOURCE_APP" "$STAGED_APP"
verify_app "$STAGED_APP"

stop_running_app

if [[ -d "$DEST_APP" ]]; then
  HAD_EXISTING_APP=1
fi
REPLACEMENT_STARTED=1
if [[ "$HAD_EXISTING_APP" -eq 1 ]]; then
  mv "$DEST_APP" "$BACKUP_APP"
fi
mv "$STAGED_APP" "$DEST_APP"
verify_app "$DEST_APP"

if [[ "${OPL_FLEET_AGENT_NO_LAUNCH:-0}" != "1" ]]; then
  if ! NEW_PID="$(launch_app_and_wait "$DEST_APP" "$RUNNING_PID")"; then
    echo "OPL Fleet Agent was installed but did not relaunch." >&2
    exit 1
  fi
fi

REPLACEMENT_STARTED=0
rm -rf "$BACKUP_APP"
if [[ -n "${OPL_FLEET_AGENT_UPDATE_LOG:-}" ]]; then
  rm -f "$OPL_FLEET_AGENT_UPDATE_LOG" || true
fi

echo "Installed OPL Fleet Agent $VERSION at $DEST_APP"
if [[ -n "$NEW_PID" ]]; then
  echo "Launched OPL Fleet Agent as process $NEW_PID."
fi
if [[ "$ALLOW_AD_HOC_TEST" -eq 1 ]]; then
  echo "The app passed isolated ad-hoc updater verification."
else
  echo "The app is Developer ID signed and notarized by Apple."
fi
