# OPL Fleet Agent Repository Guide

This repository owns local-only macOS menu bar and Windows tray monitors for
Codex token throughput. They read Codex session JSONL files and never upload
conversation content.

## Runtime Contract

- Live input is `$CODEX_HOME/sessions` when `CODEX_HOME` is set. Defaults are
  `~/.codex/sessions` on macOS and `%USERPROFILE%\.codex\sessions` on Windows.
- Count only `event_msg` entries whose payload type is `token_count`.
- Treat `last_token_usage` as the request increment. Use
  `total_token_usage` only for replay and duplicate detection.
- `total_tokens` is authoritative for throughput. Cached input and reasoning
  output are subsets used for breakdowns and must not be added again.
- Forked and subagent logs can rewrite parent history timestamps during replay.
  Legacy replay can mix UUIDv4 turn IDs with current UUIDv7 IDs. Preserve the
  fork state machine and cross-file deduplication tests.
- Do not persist, log, transmit, or render prompt or response bodies.
- Network access is limited to GitHub release metadata/assets and opt-in
  aggregate Ambient Ops discovery/push. Conversation records never cross the
  network boundary.

## Development

- Build: `swift build`
- Test: `swift test`
- Snapshot: `swift run opl-fleet-agent-snapshot --json`
- Package: `./scripts/build-app.sh`
- Universal DMG: `./scripts/build-dmg.sh`
- Install: `./scripts/install.sh`
- Install latest release: `./scripts/install-release.sh`
- Windows test: `dotnet test windows/tests/OPLFleetAgent.Core.Tests -c Release`
- Windows package: `pwsh ./windows/scripts/build.ps1 -Runtime win-x64`

Runtime and packaging claims require a real installed-app readback in addition
to unit tests.

<!-- CODEGRAPH_START -->
## CodeGraph

- This repository uses the local `.codegraph/` index; it must remain Git ignored.
- Prefer CodeGraph for symbol, caller, impact, and flow queries. Use `rg` for
  literal text searches.
- Run `codegraph init .` or `codegraph sync .` when the index is missing or stale.
<!-- CODEGRAPH_END -->
