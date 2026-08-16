#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

targets=(
  README.md
  README.zh-CN.md
  docs/architecture.md
  windows/README.md
  Sources
  windows/src
)

target_files() {
  local target
  for target in "${targets[@]}"; do
    if [[ -d "$target" ]]; then
      /usr/bin/find "$target" -type f \( \
        -name '*.swift' -o \
        -name '*.cs' -o \
        -name '*.csproj' -o \
        -name '*.manifest' -o \
        -name '*.ps1' -o \
        -name '*.md' \
      \)
    else
      printf '%s\n' "$target"
    fi
  done
}

found_ambient_ops=0
while IFS= read -r file; do
  if /usr/bin/awk '
    { text = text " " $0 }
    END { exit(text ~ /Ambient[[:space:]]+Ops/ ? 0 : 1) }
  ' "$file"; then
    printf '%s\n' "$file"
    found_ambient_ops=1
  fi
done < <(target_files)
if [[ "$found_ambient_ops" -ne 0 ]]; then
  echo "User-visible branding must use OPL Fleet Gateway or Fleet Gateway." >&2
  exit 1
fi

found_legacy_hostname=0
while IFS= read -r file; do
  if /usr/bin/grep --line-number --extended-regexp 'ambient-ops\.local' "$file"; then
    found_legacy_hostname=1
  fi
done < <(target_files)
if [[ "$found_legacy_hostname" -ne 0 ]]; then
  echo "User-visible endpoint examples must use the OPL Fleet Gateway hostname." >&2
  exit 1
fi

found_other_product_name=0
while IFS= read -r file; do
  if /usr/bin/grep --line-number --fixed-strings 'OPL Gateway' "$file"; then
    found_other_product_name=1
  fi
done < <(target_files)
if [[ "$found_other_product_name" -ne 0 ]]; then
  echo "OPL Gateway is a different product and must not name Fleet Gateway surfaces." >&2
  exit 1
fi

/usr/bin/grep --quiet --fixed-strings 'gatewayProductName = "OPL Fleet Gateway"' Sources/CodexTPSCore/FleetAgentProtocol.swift
/usr/bin/grep --quiet --fixed-strings 'gatewayShortName = "Fleet Gateway"' Sources/CodexTPSCore/FleetAgentProtocol.swift
/usr/bin/grep --quiet --fixed-strings 'GatewayProductName = "OPL Fleet Gateway"' windows/src/CodexTPS.Core/AmbientOps.cs
/usr/bin/grep --quiet --fixed-strings 'GatewayShortName = "Fleet Gateway"' windows/src/CodexTPS.Core/AmbientOps.cs

retired_distribution_surfaces=(
  README.md
  README.zh-CN.md
  docs/architecture.md
  windows/README.md
  .github/workflows/ci.yml
  .github/workflows/release.yml
  scripts/build-dmg.sh
  scripts/install-release.sh
  scripts/notarize-dmg.sh
  scripts/verify-release.sh
  windows/scripts/build.ps1
  windows/scripts/build-installer.ps1
  windows/installer/CodexTPS.iss
  Sources/CodexTPS/UpdateManager.swift
  plugins/opl-fleet-agent/bin/opl-fleet-agent.mjs
)

if /usr/bin/grep --line-number --extended-regexp \
  'Codex-TPS\.dmg|Codex-TPS-Windows|Codex TPS\.app|gaofeng21cn/codex-tps/releases|brew install --cask gaofeng21cn/codex-tps' \
  "${retired_distribution_surfaces[@]}"; then
  echo "Retired Codex TPS install and release names must not remain distribution surfaces." >&2
  exit 1
fi

/usr/bin/grep --quiet --fixed-strings 'OPL-Fleet-Agent.dmg' scripts/build-dmg.sh
/usr/bin/grep --quiet --fixed-strings 'OPL-Fleet-Agent.dmg' Sources/CodexTPS/UpdateManager.swift
