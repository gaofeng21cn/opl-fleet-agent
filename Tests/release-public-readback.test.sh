#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/release-public-readback.yml"

test -f "$WORKFLOW"
grep -Fq 'workflow_run:' "$WORKFLOW"
grep -Fq 'workflows:' "$WORKFLOW"
grep -Fq -- '- Release' "$WORKFLOW"
grep -Fq 'workflow_dispatch:' "$WORKFLOW"
grep -Fq 'source_run_id:' "$WORKFLOW"
grep -Fq 'actions: read' "$WORKFLOW"
grep -Fq 'contents: read' "$WORKFLOW"
grep -Fq 'and .path == ".github/workflows/release.yml"' "$WORKFLOW"
grep -Fq 'and .conclusion == "success"' "$WORKFLOW"
grep -Fq 'and (.head_sha | test("^[0-9a-f]{40}$"))' "$WORKFLOW"
grep -Fq 'curl -fsSL --retry 3 --retry-all-errors' "$WORKFLOW"
grep -Fq 'sha256sum --check --strict' "$WORKFLOW"
grep -Fq 'anonymous_downloads: true' "$WORKFLOW"

for asset in \
  'OPL-Fleet-Agent.dmg' \
  'OPL-Fleet-Agent.dmg.sha256' \
  'OPL-Fleet-Agent-Windows-win-x64.zip' \
  'OPL-Fleet-Agent-Windows-win-x64.zip.sha256' \
  'OPL-Fleet-Agent-Windows-win-x64-Setup.exe' \
  'OPL-Fleet-Agent-Windows-win-x64-Setup.exe.sha256'
do
  grep -Fq "$asset" "$WORKFLOW"
done

if grep -Eq '(^|[[:space:]])(contents|actions):[[:space:]]*write([[:space:]]|$)|gh[[:space:]]+release[[:space:]]+(create|upload|delete)' "$WORKFLOW"; then
  echo "Public readback must not own publication mutations or write permissions." >&2
  exit 1
fi

echo "Verified Fleet Agent public readback is an independent read-only follower."
