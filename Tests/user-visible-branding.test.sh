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

if rg --line-number --multiline 'Ambient[[:space:]]+Ops' "${targets[@]}"; then
  echo "User-visible branding must use OPL Fleet Gateway or Fleet Gateway." >&2
  exit 1
fi

if rg --line-number 'ambient-ops\.local' "${targets[@]}"; then
  echo "User-visible endpoint examples must use the OPL Fleet Gateway hostname." >&2
  exit 1
fi

if rg --line-number 'OPL Gateway' "${targets[@]}"; then
  echo "OPL Gateway is a different product and must not name Fleet Gateway surfaces." >&2
  exit 1
fi

rg --quiet 'gatewayProductName = "OPL Fleet Gateway"' Sources/CodexTPSCore/FleetAgentProtocol.swift
rg --quiet 'gatewayShortName = "Fleet Gateway"' Sources/CodexTPSCore/FleetAgentProtocol.swift
rg --quiet 'GatewayProductName = "OPL Fleet Gateway"' windows/src/CodexTPS.Core/AmbientOps.cs
rg --quiet 'GatewayShortName = "Fleet Gateway"' windows/src/CodexTPS.Core/AmbientOps.cs
