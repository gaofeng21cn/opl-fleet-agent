#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT_DIR/scripts/install-release.sh"
PREFERENCES_DOMAIN="io.github.gaofeng21cn.opl-fleet-agent"
VERIFY_MODE="${OPL_FLEET_AGENT_UPDATER_VERIFY_MODE:-strict}"
DMG_PATH="${1:-$ROOT_DIR/dist/OPL-Fleet-Agent.dmg}"
CHECKSUM_PATH="${2:-$DMG_PATH.sha256}"
EXPECTED_VERSION="${OPL_FLEET_AGENT_EXPECTED_VERSION:-$(
  plutil -extract CFBundleShortVersionString raw "$ROOT_DIR/Resources/Info.plist"
)}"
TEST_ROOT="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/opl-fleet-agent-updater.XXXXXX")"
TEST_ROOT="$(
  cd "$TEST_ROOT"
  /bin/pwd -P
)"
TEST_BIN="$TEST_ROOT/bin"
TARGET_ROOT="$TEST_ROOT/target"
TARGET_APP="$TARGET_ROOT/OPL Fleet Agent.app"
OTHER_APP="$TEST_ROOT/other/OPL Fleet Agent.app"
DIRECT_OPEN="$TEST_ROOT/direct-open"
FAKE_OPEN="$TEST_ROOT/fake-open"
FAIL_ROLLBACK_OPEN="$TEST_ROOT/fail-rollback-open"
OPEN_STATE="$TEST_ROOT/open-state"
OPEN_LOG="$TEST_ROOT/open-log"
STUB_SOURCE="$TEST_ROOT/stub.c"
STUB_EXECUTABLE="$TEST_ROOT/OPLFleetAgent"
ISOLATED_HOME="$TEST_ROOT/home"
ISOLATED_CODEX_HOME="$TEST_ROOT/codex"
OLD_PID=""
SECOND_OLD_PID=""
OTHER_PID=""
NEW_PID=""
ROLLBACK_OLD_PID=""
ROLLBACK_PID=""
ROLLBACK_SUCCESS_OLD_PID=""
STARTED_PID=""
PREFERENCES_BEFORE=""

case "$VERIFY_MODE" in
  strict | adhoc) ;;
  *)
    echo "Updater verification mode must be strict or adhoc." >&2
    exit 1
    ;;
esac

preferences_digest() {
  local exported

  if ! exported="$(defaults export "$PREFERENCES_DOMAIN" - 2>/dev/null)"; then
    printf '%s\n' "missing"
    return
  fi
  printf '%s' "$exported" | shasum -a 256 | awk '{ print $1 }'
}

process_matches_app() {
  local pid="$1"
  local app_path="$2"
  local command expected_executable

  command="$(ps -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  expected_executable="$app_path/Contents/MacOS/OPLFleetAgent"
  [[ "$command" == "$expected_executable" || "$command" == "$expected_executable "* ]]
}

process_for_app() {
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

wait_for_exit() {
  local pid="$1"

  for ((attempt = 0; attempt < 100; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_app() {
  local app_path="$1"
  local excluded_pid="${2:-}"
  local pid

  for ((attempt = 0; attempt < 100; attempt++)); do
    pid="$(process_for_app "$app_path" "$excluded_pid")" || {
      sleep 0.1
      continue
    }
    printf '%s\n' "$pid"
    return 0
  done
  return 1
}

stop_app_processes() {
  local app_path="$1"
  local pid

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    if process_matches_app "$pid" "$app_path"; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done < <(pgrep -x OPLFleetAgent 2>/dev/null || true)
}

cleanup() {
  local exit_status=$?

  stop_app_processes "$TARGET_APP" || true
  stop_app_processes "$OTHER_APP" || true
  /usr/bin/chflags -R nouchg "$TEST_ROOT" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
  return "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

make_stub_app() {
  local app_path="$1"
  local marker="$2"

  mkdir -p "$app_path/Contents/MacOS"
  cp "$STUB_EXECUTABLE" "$app_path/Contents/MacOS/OPLFleetAgent"
  printf '%s\n' "$marker" >"$app_path/Contents/test-marker"
}

start_stub_app() {
  local app_path="$1"

  "$app_path/Contents/MacOS/OPLFleetAgent" >/dev/null 2>&1 &
  STARTED_PID="$!"
}

run_installer() {
  local hidden_pid="${4:-}"
  local installer_environment=(
    "OPL_FLEET_AGENT_DMG_URL=file://$DMG_PATH"
    "OPL_FLEET_AGENT_CHECKSUM_URL=file://$CHECKSUM_PATH"
    "OPL_FLEET_AGENT_EXPECTED_VERSION=$EXPECTED_VERSION"
    "OPL_FLEET_AGENT_INSTALL_DIR=$TARGET_ROOT"
    "OPL_FLEET_AGENT_RUNNING_PID=$1"
    "OPL_FLEET_AGENT_RUNNING_APP=$2"
    "OPL_FLEET_AGENT_OPEN_COMMAND=${3:-/usr/bin/open}"
  )

  if [[ -n "$hidden_pid" ]]; then
    installer_environment+=(
      "PATH=$TEST_BIN:$PATH"
      "OPL_FLEET_AGENT_TEST_HIDDEN_PID=$hidden_pid"
    )
  fi
  if [[ "$VERIFY_MODE" == "adhoc" ]]; then
    installer_environment+=("OPL_FLEET_AGENT_UPDATER_TEST_ROOT=$TEST_ROOT")
  fi
  /usr/bin/env "${installer_environment[@]}" "$INSTALLER"
}

if [[ ! -f "$DMG_PATH" || ! -f "$CHECKSUM_PATH" ]]; then
  echo "Updater verification requires a DMG and checksum." >&2
  exit 1
fi
echo "Updater verification trust mode: $VERIFY_MODE."
PREFERENCES_BEFORE="$(preferences_digest)"

cat >"$STUB_SOURCE" <<'EOF'
#include <unistd.h>

int main(void) {
  for (;;) {
    pause();
  }
}
EOF
xcrun clang -Os "$STUB_SOURCE" -o "$STUB_EXECUTABLE"

mkdir -p "$ISOLATED_HOME/Library/Preferences" "$ISOLATED_CODEX_HOME/sessions"
export OPL_FLEET_AGENT_TEST_HOME="$ISOLATED_HOME"
export OPL_FLEET_AGENT_TEST_CODEX_HOME="$ISOLATED_CODEX_HOME"

# Launch directly without network or preference writes so the test stays isolated.
cat >"$DIRECT_OPEN" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Updater launch must pass exactly one app path." >&2
  exit 64
fi
app_path="$1"
export CFFIXED_USER_HOME="$OPL_FLEET_AGENT_TEST_HOME"
export HOME="$OPL_FLEET_AGENT_TEST_HOME"
export CODEX_HOME="$OPL_FLEET_AGENT_TEST_CODEX_HOME"
nohup /usr/bin/sandbox-exec \
  -p '(version 1)(allow default)(deny network*)(deny file-write*)(deny mach-lookup (global-name "com.apple.cfprefsd.agent"))(deny mach-lookup (global-name "com.apple.cfprefsd.xpc.agent"))(deny mach-lookup (global-name "com.apple.cfprefsd.daemon"))' \
  "$app_path/Contents/MacOS/OPLFleetAgent" --preview-window >/dev/null 2>&1 &
EOF
chmod 755 "$DIRECT_OPEN"

mkdir -p "$TEST_BIN"
cat >"$TEST_BIN/pgrep" <<'EOF'
#!/bin/bash
set -euo pipefail

while IFS= read -r pid; do
  if [[ "$pid" != "${OPL_FLEET_AGENT_TEST_HIDDEN_PID:-}" ]]; then
    printf '%s\n' "$pid"
  fi
done < <(/usr/bin/pgrep "$@" 2>/dev/null || true)
EOF
chmod 755 "$TEST_BIN/pgrep"

mkdir -p "$TARGET_ROOT"
make_stub_app "$TARGET_APP" "original"
make_stub_app "$OTHER_APP" "unrelated"
start_stub_app "$TARGET_APP"
OLD_PID="$STARTED_PID"
start_stub_app "$TARGET_APP"
SECOND_OLD_PID="$STARTED_PID"
start_stub_app "$OTHER_APP"
OTHER_PID="$STARTED_PID"

if [[ "$VERIFY_MODE" == "adhoc" ]]; then
  if OPL_FLEET_AGENT_UPDATER_TEST_ROOT="$TEST_ROOT" \
    OPL_FLEET_AGENT_DMG_URL="file://$DMG_PATH" \
    OPL_FLEET_AGENT_CHECKSUM_URL="file://$CHECKSUM_PATH" \
    OPL_FLEET_AGENT_INSTALL_DIR="/Applications" \
    OPL_FLEET_AGENT_RUNNING_PID="$OLD_PID" \
    OPL_FLEET_AGENT_RUNNING_APP="$TARGET_APP" \
    OPL_FLEET_AGENT_OPEN_COMMAND="$DIRECT_OPEN" \
    "$INSTALLER" >"$TEST_ROOT/unsafe-test-root.log" 2>&1
  then
    echo "Updater verification allowed test trust outside its test root." >&2
    exit 1
  fi
  if ! grep -q "restricted to its test root" "$TEST_ROOT/unsafe-test-root.log"; then
    echo "Updater verification failed for the wrong test-root reason." >&2
    exit 1
  fi
fi

if OPL_FLEET_AGENT_RUNNING_PID="not-a-pid" \
  OPL_FLEET_AGENT_RUNNING_APP="$TARGET_APP" \
  OPL_FLEET_AGENT_INSTALL_DIR="$TARGET_ROOT" \
  OPL_FLEET_AGENT_DMG_URL="file:///does-not-exist" \
  OPL_FLEET_AGENT_CHECKSUM_URL="file:///does-not-exist" \
  "$INSTALLER" >"$TEST_ROOT/invalid-pid.log" 2>&1; then
  echo "Updater verification accepted an invalid process ID." >&2
  exit 1
fi
if ! grep -q "invalid process ID" "$TEST_ROOT/invalid-pid.log"; then
  echo "Updater verification failed for the wrong invalid-PID reason." >&2
  exit 1
fi
if ! kill -0 "$OLD_PID" 2>/dev/null || ! kill -0 "$SECOND_OLD_PID" 2>/dev/null; then
  echo "Invalid PID verification stopped the target process." >&2
  exit 1
fi

if run_installer "$OTHER_PID" "$TARGET_APP" "$DIRECT_OPEN" >"$TEST_ROOT/wrong-process.log" 2>&1; then
  echo "Updater verification accepted a process from another app." >&2
  exit 1
fi
if ! grep -q "unexpected running process" "$TEST_ROOT/wrong-process.log"; then
  echo "Updater verification failed for the wrong process-identity reason." >&2
  exit 1
fi
if ! kill -0 "$OLD_PID" 2>/dev/null || ! kill -0 "$SECOND_OLD_PID" 2>/dev/null \
  || ! kill -0 "$OTHER_PID" 2>/dev/null
then
  echo "Process identity verification stopped a valid process." >&2
  exit 1
fi

run_installer "$OLD_PID" "$TARGET_APP" "$DIRECT_OPEN" "$OLD_PID"
if ! wait_for_exit "$OLD_PID" || ! wait_for_exit "$SECOND_OLD_PID"; then
  echo "Updater verification left an old target process running." >&2
  exit 1
fi
if ! kill -0 "$OTHER_PID" 2>/dev/null; then
  echo "Updater verification stopped an unrelated OPL Fleet Agent process." >&2
  exit 1
fi

NEW_PID="$(wait_for_app "$TARGET_APP" "$OLD_PID")"
if [[ -z "$NEW_PID" || "$NEW_PID" == "$OLD_PID" ]]; then
  echo "Updater verification did not observe a replacement process." >&2
  exit 1
fi
INSTALLED_VERSION="$(
  plutil -extract CFBundleShortVersionString raw "$TARGET_APP/Contents/Info.plist"
)"
if [[ "$INSTALLED_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Expected OPL Fleet Agent $EXPECTED_VERSION, got $INSTALLED_VERSION." >&2
  exit 1
fi

kill -TERM "$NEW_PID"
wait_for_exit "$NEW_PID"
rm -rf "$TARGET_APP"
make_stub_app "$TARGET_APP" "rollback"
start_stub_app "$TARGET_APP"
ROLLBACK_OLD_PID="$STARTED_PID"

cat >"$FAKE_OPEN" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Updater launch must pass exactly one app path." >&2
  exit 64
fi
count=0
if [[ -f "$OPL_FLEET_AGENT_TEST_OPEN_STATE" ]]; then
  read -r count <"$OPL_FLEET_AGENT_TEST_OPEN_STATE"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$OPL_FLEET_AGENT_TEST_OPEN_STATE"
printf '%s\n' "$*" >>"$OPL_FLEET_AGENT_TEST_OPEN_LOG"

if [[ "$count" -eq 1 ]]; then
  exit 1
fi

app_path="$1"
nohup "$app_path/Contents/MacOS/OPLFleetAgent" >/dev/null 2>&1 &
EOF
chmod 755 "$FAKE_OPEN"

if OPL_FLEET_AGENT_TEST_OPEN_STATE="$OPEN_STATE" \
  OPL_FLEET_AGENT_TEST_OPEN_LOG="$OPEN_LOG" \
  run_installer "$ROLLBACK_OLD_PID" "$TARGET_APP" "$FAKE_OPEN" \
  >"$TEST_ROOT/rollback.log" 2>&1; then
  echo "Updater verification expected the injected launch failure." >&2
  exit 1
fi
if ! wait_for_exit "$ROLLBACK_OLD_PID"; then
  echo "Rollback verification left the original process running." >&2
  exit 1
fi
if [[ "$(cat "$TARGET_APP/Contents/test-marker")" != "rollback" ]]; then
  echo "Updater verification did not restore the previous app bytes." >&2
  exit 1
fi
if [[ "$(cat "$OPEN_STATE")" != "2" ]]; then
  echo "Updater verification did not attempt the rollback relaunch." >&2
  exit 1
fi
ROLLBACK_PID="$(wait_for_app "$TARGET_APP" "$ROLLBACK_OLD_PID")"
if [[ -z "$ROLLBACK_PID" || "$ROLLBACK_PID" == "$ROLLBACK_OLD_PID" ]]; then
  echo "Updater verification did not observe the restored app process." >&2
  exit 1
fi
if ! kill -0 "$OTHER_PID" 2>/dev/null; then
  echo "Rollback verification stopped an unrelated OPL Fleet Agent process." >&2
  exit 1
fi
ROLLBACK_SUCCESS_OLD_PID="$ROLLBACK_OLD_PID"

kill -TERM "$ROLLBACK_PID"
wait_for_exit "$ROLLBACK_PID"
rm -rf "$TARGET_APP"
make_stub_app "$TARGET_APP" "preserved-backup"
start_stub_app "$TARGET_APP"
ROLLBACK_OLD_PID="$STARTED_PID"

cat >"$FAIL_ROLLBACK_OPEN" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Updater launch must pass exactly one app path." >&2
  exit 64
fi
app_path="$1"
/usr/bin/chflags -R uchg "$app_path"
exit 1
EOF
chmod 755 "$FAIL_ROLLBACK_OPEN"

if run_installer "$ROLLBACK_OLD_PID" "$TARGET_APP" "$FAIL_ROLLBACK_OPEN" \
  >"$TEST_ROOT/rollback-file-failure.log" 2>&1
then
  echo "Updater verification accepted a failed rollback file operation." >&2
  exit 1
fi
if ! wait_for_exit "$ROLLBACK_OLD_PID"; then
  echo "Failed-file rollback verification left the old process running." >&2
  exit 1
fi
if ! grep -Eq "backups? remain" "$TEST_ROOT/rollback-file-failure.log"; then
  cat "$TEST_ROOT/rollback-file-failure.log" >&2
  echo "Updater verification failed for the wrong rollback-file reason." >&2
  exit 1
fi
BACKUP_APP="$(
  find "$TARGET_ROOT" -maxdepth 1 -type d -name '.OPL Fleet Agent.app.backup.*' -print -quit
)"
if [[ -z "$BACKUP_APP" || ! -f "$BACKUP_APP/Contents/test-marker" ]]; then
  echo "Updater verification did not preserve the backup after rollback failure." >&2
  exit 1
fi
if [[ "$(cat "$BACKUP_APP/Contents/test-marker")" != "preserved-backup" ]]; then
  echo "Updater verification preserved the wrong rollback backup." >&2
  exit 1
fi
/usr/bin/chflags -R nouchg "$TARGET_APP"
rm -rf "$TARGET_APP"
mv "$BACKUP_APP" "$TARGET_APP"

if [[ "$(preferences_digest)" != "$PREFERENCES_BEFORE" ]]; then
  echo "Updater verification changed the real OPL Fleet Agent preferences." >&2
  exit 1
fi

echo "Verified updater handoff $OLD_PID,$SECOND_OLD_PID -> $NEW_PID for OPL Fleet Agent $INSTALLED_VERSION."
echo "Verified failed-launch rollback $ROLLBACK_SUCCESS_OLD_PID -> $ROLLBACK_PID."
echo "Verified failed rollback file operation preserved the previous app backup."
