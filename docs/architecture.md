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

Rates divide completed usage by the entire selected `1m`, `5m`, `30m`, or `1h`
window. UI refresh cadence is separate from the accounting window. On macOS the
selected window and per-source toggles (`Codex` / `Antigravity`) are persisted
and shared across refreshes, while the menu bar, Direct status, and Gateway push
project the combined enabled throughput. Tokscale is not called on the refresh
path. Local log observations are not provider billing or API-key attribution
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
default hostname identity. On macOS it also reads the desktop's saved source
toggles (`Codex` and `Antigravity`); Windows reads the desktop's selected Codex
home. Explicit provider environment options take precedence. This keeps a paired
or renamed desktop from appearing as a different node in Agent reads. No pairing
token or device key is loaded by this identity read.
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
Codex telemetry, and the host dashboard. Neither the native Agent nor the
Package owns admission, registry, policy, leases, dispatch, execution constraints,
receipts, or task completion. Those decisions remain with their external owners.

## Direct and Gateway transports

On macOS, [AmbientOpsDirectServer](../Sources/OPLFleetAgent/AmbientOpsDirectServer.swift)
publishes `_opl-fleet-agent._tcp` and serves read-only aggregate status and pet
assets on the LAN, independently of Gateway push settings. Windows has Direct
status models but does not publish a Direct server. The Direct projection
includes token rates, session count, available host CPU/network telemetry, and
the selected pet. It has no persistent network history or dispatch endpoint.

Desktop Gateway discovery is enabled by default and can be disabled in Settings.
Discovery uses `_ambient-ops._tcp`; desktop pairing
generates a per-device P-256 key, displays a six-digit code, and requires visible
approval. macOS stores the private key in Keychain; Windows uses current-user
DPAPI. Signed requests bind method, path, timestamp, nonce, and body hash.
The headless command currently uses bearer authentication, which also remains
implemented in desktop settings. Configuration belongs in [operations](operations.md).

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
pairing, and pushes, and GitHub release metadata/assets on Windows.

## Native distribution and updates

macOS releases are distributed as signed, notarized universal DMGs and through the
unified OPL Homebrew Tap (`brew upgrade --cask opl-fleet-agent`), without an
in-app self-updater.

The Windows desktop updater checks after launch and every six hours, then requires
user confirmation before installation. Session collection is independent and no log
content is attached to release requests. Windows uses an exact-process handoff,
re-verifies the installer, reads back its installed version, and relaunches; its
platform transaction is documented in [Windows installation](../windows/README.md).

This repository owns release identity and assets. The Homebrew Tap is a
downstream Cask projection. Public release trust and workflow boundaries belong
to [development](development.md), not to historical build receipts.
