#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/release-tag-eligibility.py"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opl-fleet-agent-release-tag.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>0.2.46</string>
</dict></plist>
EOF
cat > "$TMP_DIR/OPLFleetAgent.Windows.csproj" <<'EOF'
<Project><PropertyGroup><Version>0.2.46</Version></PropertyGroup></Project>
EOF
cat > "$TMP_DIR/opl-package.json" <<'EOF'
{"version":"0.2.47"}
EOF

[[ "$(python3 "$SCRIPT" v0.2.46 "$TMP_DIR/Info.plist" "$TMP_DIR/OPLFleetAgent.Windows.csproj" "$TMP_DIR/opl-package.json")" == native ]]
[[ "$(python3 "$SCRIPT" v0.2.47 "$TMP_DIR/Info.plist" "$TMP_DIR/OPLFleetAgent.Windows.csproj" "$TMP_DIR/opl-package.json")" == package-only ]]

sed -i '' 's/0.2.46/0.2.47/' "$TMP_DIR/OPLFleetAgent.Windows.csproj" 2>/dev/null || sed -i 's/0.2.46/0.2.47/' "$TMP_DIR/OPLFleetAgent.Windows.csproj"
if python3 "$SCRIPT" v0.2.46 "$TMP_DIR/Info.plist" "$TMP_DIR/OPLFleetAgent.Windows.csproj" "$TMP_DIR/opl-package.json" >/dev/null 2>&1; then
  echo "Expected mismatched native versions to fail." >&2
  exit 1
fi

cat > "$TMP_DIR/OPLFleetAgent.Windows.csproj" <<'EOF'
<Project><PropertyGroup><Version>0.2.46</Version></PropertyGroup></Project>
EOF

if python3 "$SCRIPT" v0.2.48 "$TMP_DIR/Info.plist" "$TMP_DIR/OPLFleetAgent.Windows.csproj" "$TMP_DIR/opl-package.json" >/dev/null 2>&1; then
  echo "Expected unknown tag to fail." >&2
  exit 1
fi

echo "Verified native and Package-only tag classification."
