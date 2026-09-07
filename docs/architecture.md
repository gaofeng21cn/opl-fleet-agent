# Architecture

This document owns collection, telemetry, and integration boundaries. Use
[operations](operations.md) for configuration and [development](development.md)
for builds and release qualification.

## Collection and accounting

```text
CODEX_HOME/sessions/**/*.jsonl
        -> incremental byte reader
        -> structural token-event parser
        -> fork replay and cross-file duplicate filters
        -> rolling aggregate windows
        -> native UI, snapshot CLI, native provider, Direct, or Gateway push
```

The Swift [scanner](../Sources/OPLFleetAgentCore/SessionScanner.swift) and
[Windows scanner](../windows/src/OPLFleetAgent.Core/SessionScanner.cs) recursively
discover session files, admit recently modified files and previously tracked
files, then read appended bytes. They retain 65 minutes of accounting events.
Active sessions count files modified in the last two minutes, including activity
that has not yet produced a completed token event. Missing directories and read
failures produce collection status, not a successful empty observation.

The [Swift parser](../Sources/OPLFleetAgentCore/TokenEventParser.swift) and its
[Windows counterpart](../windows/src/OPLFleetAgent.Core/TokenEventParser.cs) own
these accounting rules:

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

Rates divide completed usage by the entire selected `1m`, `5m`, `30m`, or `1h`
window. UI refresh cadence is separate from the accounting window. On macOS the
selected window is persisted and shared by the panel and menu-bar readout.
Tokscale is not called on the refresh path. Local log observations are not
provider billing or API-key attribution authority.

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
Network use consists of GitHub release metadata/assets, the macOS Direct
service, and configured Gateway discovery, pairing, and pushes.

## Native updates

Both desktop updaters check after launch and every six hours, then require user
confirmation before installation. Session collection is independent and no log
content is attached to release requests.

The [macOS updater](../Sources/OPLFleetAgent/UpdateManager.swift) discovers the
latest release through the release-page redirect and delegates installation to
the bundled [release installer](../scripts/install-release.sh). The transaction
validates checksum, expected version, signature/team and Gatekeeper state before
staging, backup, replacement, and relaunch. Replacement failure restores the
previous app. Windows uses an exact-process handoff, re-verifies the installer,
reads back its installed version, and relaunches; its platform transaction is
documented in [Windows installation](../windows/README.md).

This repository owns release identity and assets. The Homebrew Tap is a
downstream Cask projection. Public release trust and workflow boundaries belong
to [development](development.md), not to historical build receipts.
