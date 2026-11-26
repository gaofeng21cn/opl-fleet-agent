# Architecture

This document owns collection, telemetry, and integration boundaries. Use
[operations](operations.md) for configuration and [development](development.md)
for builds and release qualification.

## Collection and accounting

```text
Codex:       CODEX_HOME/sessions/**/*.jsonl
Antigravity: ~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl (macOS)
             ~/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl (macOS)
        -> per-source incremental byte readers
        -> structural token-event parsers
        -> fork replay and cross-file duplicate filters
        -> rolling aggregate windows (per-source and combined on macOS)
        -> native UI, snapshot CLI, native provider, Direct, or Gateway push
```

The Swift [scanner](../Sources/OPLFleetAgentCore/SessionScanner.swift) and
[Windows scanner](../windows/src/OPLFleetAgent.Core/SessionScanner.cs) recursively
discover Codex session files, admit recently modified files and previously tracked
files, then read appended bytes. On macOS,
[AntigravitySessionScanner](../Sources/OPLFleetAgentCore/AntigravitySessionScanner.swift)
also inspects top-level conversation folders under the desktop/IDE and CLI `brain`
roots and incrementally reads `.system_generated/logs/transcript.jsonl` (never
`transcript_full.jsonl`), resetting its byte cursor on truncation or inode
replacement. Windows remains Codex-only. Scanners retain 65 minutes of
accounting events. Active sessions count files modified in the last two minutes,
including activity that has not yet produced a completed token event. Missing
directories and read failures produce collection status, not a successful empty
observation; on macOS, [MultiSourceSessionScanner](../Sources/OPLFleetAgentCore/MultiSourceSessionScanner.swift)
combines enabled sources and stays `ready` when at least one enabled source root
exists.

The [Swift parser](../Sources/OPLFleetAgentCore/TokenEventParser.swift) and its
[Windows counterpart](../windows/src/OPLFleetAgent.Core/TokenEventParser.cs) own
Codex accounting rules:

- `last_token_usage` supplies the request increment. Cumulative
  `total_token_usage` supports fallback accounting and duplicate detection;
  it is not another increment when last usage is present.
- `total_tokens` is the throughput numerator. Cached input and reasoning
  output are subsets and must not be added to the total again.
- Inherited fork history can have rewritten timestamps. A verifiable child
  UUIDv7 turn establishes the replay boundary; replayed UUIDv4 turns do not.
  Stable event identity provides the subsequent cross-file duplicate guard.
- Only structural `session_meta`, `task_started`, `turn_context`, and
  `token_count` data is decoded. Conversation and tool-content lines are read
  as bytes but are not decoded, retained, rendered, or transmitted as bodies.

On macOS, [AntigravityTokenEventParser](../Sources/OPLFleetAgentCore/AntigravityTokenEventParser.swift)
owns Antigravity accounting rules:

- Completed `PLANNER_RESPONSE` turns and `CHECKPOINT` compaction calls supply
  per-step usage increments; non-`DONE` rows and legacy entries without token
  fields are ignored.
- In Antigravity transcripts, `input_tokens` represents uncached input only and
  excludes `cache_read_tokens`. The parser normalizes `inputTokens` to
  `input_tokens + cache_read_tokens`, `cachedInputTokens` to `cache_read_tokens`,
  `outputTokens` to `output_tokens`, `reasoningOutputTokens` to `0`, and
  `totalTokens` to `inputTokens + outputTokens`.
- Events use completion timestamps resolved from the subsequent `MODEL` step's
  `created_at` (for `PLANNER_RESPONSE` followed by `GENERIC`/model steps and
  `CHECKPOINT` followed by `PLANNER_RESPONSE`) or the transcript file `mtime`
  at EOF when within 15 minutes of `created_at`, falling back to `created_at`
  before `USER_INPUT` or `SYSTEM_MESSAGE` waits; deduplication remains keyed on
  the step's immutable `created_at` and structural event identity.
- Only `step_index`, `type`, `status`, `created_at`, `model`, and token counters
  are decoded; `content`, `thinking`, and `tool_calls` are never decoded,
  retained, rendered, or transmitted.

Windows remains Codex-only. Scanners retain 65 minutes of
accounting events.
Rates divide completed usage by the entire selected `1m`, `5m`, `30m`, or `1h`
window. UI refresh cadence is separate from the accounting window. On macOS the
selected window and per-source toggles (`Codex` / `Antigravity`) are persisted
and shared across refreshes, while the menu bar, Direct status, and Gateway push
project the combined enabled throughput. Local log observations are not provider billing or API-key attribution
authority.

## Native and Package ownership

The native app and command targets are defined by [Package.swift](../Package.swift)
and the [Windows solution](../windows/OPLFleetAgent.Windows.sln). Native code owns
local collection, sanitization, persistence, and platform installation.

The optional [Package descriptor](../plugins/opl-fleet-agent/opl-package.json)
exports read-only telemetry and doctor contributions through the Framework
broker. Its [adapter](../plugins/opl-fleet-agent/bin/opl-fleet-agent.mjs) invokes
the installed native provider; it must not collect Codex logs itself. The
Package is not required to install or run the native app. Missing native carrier
and stale last-known values remain explicit availability/freshness states.
The Package also exposes both results as conversational MCP App views for
Agent-led inspection. Those views are read-only and do not move the native menu
bar, tray, or dashboard into the conversation surface.
The native provider resolves the saved desktop node identity before deriving a
default hostname identity. On macOS, desktop settings bind the saved node ID to
an irreversible SHA-256 hardware fingerprint derived from `IOPlatformUUID`
(`ambientOpsMachineHardwareFingerprint`); when preferences are migrated or
cloned to different hardware, both the desktop app and the native provider
automatically resolve a fresh host-derived node ID (disambiguating identical
hostnames with a short hardware-fingerprint suffix) and the desktop app rotates
its per-device Keychain pairing key without touching shared bearer tokens. On
macOS it also reads the desktop's saved source toggles (`Codex` and
`Antigravity`); Windows reads the desktop's selected Codex home. Explicit
provider environment options take precedence. This keeps a paired or renamed
desktop from appearing as a different node in Agent reads while preventing
cross-machine preference migrations from impersonating the source machine. No
pairing token, device key, or raw hardware UUID is loaded or exposed by this
identity read.
`observed_at` is the provider response time, while
`freshness.last_observed_at` identifies the actual sample. Compare the latter
with `node.stable_node_id` and `node.agent_version` when correlating a view with
an Agent read; two independent refreshes need not have identical sample times.
Stale fallback retains its original sample time and is never relabeled as fresh.
The last-known cache is bound to a digest of the node identity and selected
source configuration. A changed node, changed source toggle/path, or an older
unbound cache cannot supply fallback metrics for the current read.
The [Skill](../plugins/opl-fleet-agent/skills/opl-fleet-agent/SKILL.md) owns broker
invocation instructions.

The `opl_fleet_agent_telemetry.v1` envelope is defined in
[FleetAgentProtocol.swift](../Sources/OPLFleetAgentCore/FleetAgentProtocol.swift)
and [AmbientOps.cs](../windows/src/OPLFleetAgent.Core/AmbientOps.cs). Its advertised
modes are `local`, `direct`, and `fleet`; these names do not prove each platform
publishes every transport. Current capabilities cover observation, doctor, local
Codex and macOS Antigravity telemetry, and the host dashboard. Neither the native Agent nor the
Package owns admission, registry, policy, leases, dispatch, execution constraints,
receipts, or task completion. Those decisions remain with their external owners.

## Direct and Gateway transports

On macOS, [AmbientOpsDirectServer](../Sources/OPLFleetAgent/AmbientOpsDirectServer.swift)
publishes `_opl-fleet-agent._tcp` and serves read-only aggregate status and pet
assets on the LAN, independently of Gateway push settings. When the macOS host
name or resolved node ID changes at runtime, the Direct server dynamically
republishes its Bonjour service name and TXT metadata (`id`, `name`). Windows has
Direct status models but does not publish a Direct server. The Direct projection
includes token rates, session count, available host CPU/network telemetry, and
the selected pet. It has no persistent network history or dispatch endpoint.

Desktop Gateway discovery is enabled by default and can be disabled in Settings.
Discovery uses `_ambient-ops._tcp`; desktop pairing
generates a per-device P-256 key, displays a six-digit code, and requires visible
approval. macOS stores the private key in Keychain; Windows uses current-user
DPAPI. Signed requests bind method, path, timestamp, nonce, and body hash.
On macOS, the desktop client also periodically cross-checks
`GET /api/v1/status?view=summary` against its last accepted `generatedAt`
timestamp to detect concurrent writers sharing the same `machineId`: a host whose
ID does not match its local hostname yields first to its clean local default ID
(or a disambiguated hardware-fingerprint suffix if already occupied), while a
matching-hostname host backs off after sustained collisions. The headless command
currently uses bearer authentication, which also remains implemented in desktop
settings. Configuration belongs in [operations](operations.md).

[AmbientOpsPush.swift](../Sources/OPLFleetAgentCore/AmbientOpsPush.swift) and its
Windows equivalent define the outbound fields: stable machine identity and
labels, time/status, one- and five-minute token/request aggregates, active
sessions, optional aggregate CPU/network observations, pet state/assets, and
the `oplFleet` envelope. Session identities, file paths, interface identities,
addresses, credentials, raw logs, prompts, responses, and tool bodies are excluded.
On collection failure, Gateway snapshots retain available last-successful
aggregates with error status. Transport retry does not block local collection.

OPL Fleet Cockpit owns display composition; its OPL Fleet Gateway receives and
projects telemetry. Neither is a scheduler by virtue of this integration.
Network use consists of the macOS Direct service, configured Gateway discovery,
pairing, and pushes, and GitHub release metadata/assets for in-app updates on
both macOS (Sparkle `appcast.xml` and DMG) and Windows (WinSparkle
`windows-appcast.xml` and Inno Setup installer).

## Native distribution and updates

First-class in-app automatic updating is a required product capability on both
macOS and Windows and must not be removed during refactoring or distribution
simplification. Package managers and standalone installers are parallel
distribution channels, not replacements for in-app updates.

macOS uses a dual-track update model:

- **In-app automatic updates (Sparkle 2)**: [AppUpdater](../Sources/OPLFleetAgent/AppUpdater.swift)
  embeds `Sparkle.framework` inside `OPL Fleet Agent.app/Contents/Frameworks`,
  checks the EdDSA-signed `appcast.xml` feed at
  `releases/latest/download/appcast.xml` every six hours (`SUEnableAutomaticChecks = true`,
  `SUAutomaticallyUpdate = false`), uses gentle menu-bar reminders for scheduled
  background checks, and exposes a native "Check for Updates" control in
  [MonitorPanel](../Sources/OPLFleetAgent/MonitorPanel.swift). Updates are
  verified against both the embedded Ed25519 public key (`SUPublicEDKey`) and
  Apple Developer ID signing/notarization before installation.
- **Distribution channels**: Releases ship signed, notarized universal DMGs
  alongside the signed `appcast.xml`, and are projected downstream into the
  unified OPL Homebrew Tap (`brew install --cask opl-fleet-agent`). The Cask
  must declare `auto_updates true` so routine `brew upgrade` runs do not clash
  with Sparkle in-app updates while users remain free to upgrade via Homebrew
  explicitly.

Windows uses a parallel in-app + standalone installer model:

- **In-app automatic updates (WinSparkle)**: [WindowsUpdateManager](../windows/src/OPLFleetAgent.Windows/WindowsUpdateManager.cs)
  loads pinned `WinSparkle.dll` alongside `OPLFleetAgent.exe`, checks the
  Ed25519-signed `windows-appcast.xml` feed at
  `releases/latest/download/windows-appcast.xml` every six hours (configurable
  via the Settings auto-check toggle), and exposes native "Check for Updates"
  controls in the tray menu, dashboard header, and Settings dialog. Before
  launching the Inno Setup installer, WinSparkle verifies the downloaded
  installer's `sparkle:edSignature` against the embedded Ed25519 public key
  (matching macOS `SUPublicEDKey`), requires user confirmation, and invokes
  clean shutdown callbacks before Inno Setup performs the silent in-place
  upgrade and background relaunch.
- **Distribution channels**: Standalone Inno Setup (`OPL-Fleet-Agent-Windows-win-x64-Setup.exe`)
  and portable ZIP archives ship alongside `windows-appcast.xml`. Session
  collection is independent and no log content is attached to update requests;
  desktop installation and upgrade behavior is documented in
  [Windows installation](../windows/README.md).

This repository owns release identity, macOS Sparkle `appcast.xml` and Windows
WinSparkle `windows-appcast.xml` Ed25519 signatures, and assets. The Homebrew
Tap is a downstream Cask projection. Public release trust and workflow
boundaries belong to [development](development.md), not to historical build
receipts.
