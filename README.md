<p align="center">
  <strong>English</strong> | <a href="./README.zh-CN.md">中文</a>
</p>

<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="OPL Fleet Agent app icon">
</p>

<h1 align="center">OPL Fleet Agent</h1>

<p align="center"><strong>A quiet menu-bar and system-tray view of local Codex token throughput</strong></p>
<p align="center">macOS menu bar · Windows system tray · OPL Fleet Gateway integration</p>

<p align="center">
  <a href="https://github.com/gaofeng21cn/opl-fleet-agent/actions/workflows/ci.yml"><img src="https://github.com/gaofeng21cn/opl-fleet-agent/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest"><img src="https://img.shields.io/github/v/release/gaofeng21cn/opl-fleet-agent" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" alt="Apache-2.0 License"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black.svg" alt="macOS 13 or later">
</p>

![OPL Fleet Agent panel](docs/assets/codex-tps-panel.png)

<table>
  <tr>
    <td width="33%" valign="top">
      <strong>Primary Use</strong><br/>
      See token throughput, request rate, and active sessions from recently completed Codex requests
    </td>
    <td width="33%" valign="top">
      <strong>Desktop Surfaces</strong><br/>
      A macOS menu bar app and a native Windows 11 system-tray app
    </td>
    <td width="33%" valign="top">
      <strong>Privacy Boundary</strong><br/>
      Reads local usage events, requires no API key, and does not upload conversation bodies
    </td>
  </tr>
</table>

> OPL Fleet Agent is operational telemetry, not billing data. It reports usage visible in local Codex logs and cannot prove which API key was charged or replace the server-side bill.

## For Users

### What it is

OPL Fleet Agent is a local-first desktop utility. It incrementally reads token-usage events
already written under the Codex `sessions` directory and turns them into a compact
macOS menu bar or Windows system-tray readout.

It does not launch, proxy, or modify Codex requests. It only makes the statistics
already present in local session logs easier to see.

### What it shows

- Rolling token rates for `1m`, `5m`, `30m`, and `1h`
- Input, cached-input, output, and reasoning breakdowns
- Requests per minute, active sessions, and cache ratio
- `5s`, `15s`, `30s`, or `1min` refresh cadence
- Remembered menu-bar window, manual refresh, session-folder access, and launch at login
- User-confirmed, checksum-verified GitHub Release updates
- A JSON snapshot command for scripts and integrations
- OPL Fleet Gateway Direct discovery on macOS, plus optional aggregate-only Gateway pushes

Codex normally records usage after a model request completes, so the readout represents
completion-time throughput rather than per-streaming-chunk speed.

### Install on macOS

Requirements: macOS 13 Ventura or later. OPL Fleet Agent needs no API key of its own.

Install the latest release:

```bash
curl -fsSL https://raw.githubusercontent.com/gaofeng21cn/opl-fleet-agent/main/scripts/install-release.sh | bash
```

You can also download `OPL-Fleet-Agent.dmg` from the
[latest release](https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest), open it,
and drag the app into Applications.

Release builds are universal for Apple Silicon and Intel, signed with Apple Developer
ID, and notarized. The installer verifies the published SHA-256, stages and validates
the new app, then replaces the existing installation. A failed replacement restores
the previous app.

Install for the current user without launching:

```bash
curl -fsSL https://raw.githubusercontent.com/gaofeng21cn/opl-fleet-agent/main/scripts/install-release.sh | \
  OPL_FLEET_AGENT_INSTALL_DIR="$HOME/Applications" OPL_FLEET_AGENT_NO_LAUNCH=1 bash
```

### Install on Windows

The Windows edition is a native .NET 8 WinForms tray app for Windows 11. Its standard
installer is self-contained and does not require a separate .NET runtime.

Download both files from the
[latest release](https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest):

- `OPL-Fleet-Agent-Windows-win-x64-Setup.exe`
- `OPL-Fleet-Agent-Windows-win-x64-Setup.exe.sha256`

Installs target `%LOCALAPPDATA%\Programs\OPL Fleet Agent` and use `OPLFleetAgent.exe`.
Retired install names and release aliases are not emitted or migrated. The installer is
not yet Authenticode-signed, so Windows
may show an unknown-publisher or SmartScreen warning. GitHub Release provenance,
SHA-256, and CI receipts do not replace Windows code-signing trust.

See [`windows/README.md`](windows/README.md) for checksum verification, portable
installation, WSL paths, and current qualification boundaries.

### Where the data comes from

Default roots:

- macOS: `~/.codex/sessions`
- Windows: `%USERPROFILE%\.codex\sessions`

Set `CODEX_HOME` when Codex uses a different home. The Windows app also supports an
accessible WSL UNC path such as `\\wsl.localhost\Ubuntu\home\<user>\.codex`.

### Accounting model

| Metric | Meaning |
| --- | --- |
| `token/s` | `total_tokens` completed inside the selected window, divided by the full window duration |
| Input | Input tokens, including the cached-input subset |
| Cached | Cached input shown separately and never added twice |
| Output | Output tokens, including the reasoning subset |
| Reasoning | Reasoning output shown separately and never added twice |
| Requests/min | Completion rate inside the selected window |
| Active sessions | Sessions with recent usage events |

### OPL Fleet Gateway integration

[OPL Fleet Gateway](https://github.com/gaofeng21cn/opl-fleet-cockpit) combines aggregate Codex
state from multiple computers with trusted-LAN network telemetry for browser and
Android ambient displays.

On macOS, OPL Fleet Agent publishes the established protocol service name
`_codex-tps._tcp.local` and a read-only local status endpoint so OPL Fleet Cockpit can
display this Mac without enabling Gateway pushes. The Direct provider exposes only
aggregate TPS, active sessions, host CPU and network throughput, and the selected pet
asset. Windows does not publish the Direct provider yet.

For fleet mode, the Agent discovers `_ambient-ops._tcp.local` automatically. On first
connection, the desktop app creates a local per-device key and opens the approval page.
After the user verifies the six-digit code, signed pushes begin without copying a
shared token.

The private key stays in macOS Keychain or as current-user DPAPI ciphertext on Windows.
OPL Fleet Gateway stores only the corresponding public key. The payload is limited to:

- stable machine identity, machine name, and platform;
- collection time and status;
- aggregate `1m` and `5m` token counters;
- active-session count; and
- optional pet definition and activity state.

The optional `oplFleet` extension uses schema `opl_fleet_agent_telemetry.v1` and
advertises Local, Direct, and Fleet modes plus node-local observation, doctor,
execution-constraint, and sanitized-receipt capabilities. The Agent does not own
registry, policy, admission, lease, or dispatch; OPL Flow, the private Fleet
Controller, and the approved Instance remain authoritative. The Gateway only
aggregates and projects telemetry and is never a second scheduler.

Session identifiers, local paths, interface names, addresses, prompts, responses,
credentials, raw logs, and tool content are never sent.
The integration is opt-in and can be disabled, rediscovered, or pointed at a manual
HTTP(S) endpoint from settings.

### Privacy boundary

- Parses only structural events required for accounting and deduplication.
- Does not read or render conversation bodies.
- Uses the network for GitHub Release checks and, on macOS, the aggregate-only local
  Direct provider advertised on the LAN.
- Sends only allowlisted aggregates when OPL Fleet Gateway is enabled.
- Includes no analytics SDK, account system, or cloud session synchronization.
- Treats the Codex log format as an implementation dependency that may evolve.

## For Agents

### Installation and configuration rules

Prefer a published, verified release for user installation. A successful local build
is not the same terminal state as an installed release.

Install the macOS release:

```bash
curl -fsSL https://raw.githubusercontent.com/gaofeng21cn/opl-fleet-agent/main/scripts/install-release.sh | bash
```

Build and install from source on macOS:

```bash
git clone https://github.com/gaofeng21cn/opl-fleet-agent.git
cd opl-fleet-agent
./scripts/install.sh
```

The source path builds for the current Mac, ad-hoc signs, installs, and launches the
app. It does not create a Developer ID signed, notarized release. Use
`OPL_FLEET_AGENT_INSTALL_DIR` for another destination or `--no-launch` to skip launch.

On Windows, prefer the standard installer from the latest release and verify its
sibling `.sha256` file before opening it. Do not describe the unsigned installer as
Authenticode-trusted.

### Configure a non-default Codex home

Verify that the selected root contains `sessions` before setting `CODEX_HOME`. Do not
silently guess, merge, or switch between multiple roots.

```bash
CODEX_HOME=/path/to/codex-home swift run codex-tps-snapshot --json
```

Native Windows and WSL UNC roots are separate sources and require an explicit user
choice.

### Configure OPL Fleet Gateway

For desktop apps, prefer automatic discovery and the visible one-time approval flow.
An agent may open settings, trigger rediscovery, and guide the user through code
verification. It must not approve an unknown device or extract the private key.

The headless agent also discovers OPL Fleet Gateway when `CODEX_TPS_AMBIENT_URL` is absent.
Set `CODEX_TPS_AMBIENT_INSTANCE_ID` to prefer one advertised instance. An explicit
URL always overrides discovery.

Legacy or headless bearer-token path:

```bash
CODEX_TPS_AMBIENT_URL=http://opl-fleet-gateway.local:8787 \
CODEX_TPS_AMBIENT_TOKEN='<agent-token>' \
CODEX_TPS_MACHINE_ID=primary-mac \
CODEX_TPS_MACHINE_NAME='Primary Mac' \
swift run codex-tps-agent --once
```

Do not put a real token in a task prompt, repository, log, or persistent shell history.
On macOS, `CODEX_TPS_AMBIENT_TOKEN_KEYCHAIN_SERVICE` and optional
`CODEX_TPS_KEYCHAIN_ACCOUNT` can read a generic-password Keychain item.

### Agent acceptance

```bash
swift test
swift run codex-tps-snapshot --json
```

Windows core tests:

```powershell
dotnet test windows/tests/CodexTPS.Core.Tests -c Release
```

An installation is complete only after reading back:

- the actual installed path and app version;
- macOS signing, notarization, and Gatekeeper state, or the Windows installed file version;
- successful access to the intended `CODEX_HOME/sessions` root;
- real metrics after a panel refresh; and
- when OPL Fleet Gateway is enabled, matching approval and accepted machine identity.

Tests, a local build, or discovery of a release are not installed-runtime acceptance.

### Invariants to preserve

- Never persist, log, transmit, or render prompt and response bodies.
- `total_tokens` is the throughput total; cached input and reasoning output are subsets.
- Preserve cross-file deduplication and fork/replay handling.
- Keep OPL Fleet Gateway payloads limited to the allowlisted aggregate contract.
- Keep release claims behind signing, notarization, checksum, and installed-app readback.

## Documentation and Development

- [Architecture and accounting](docs/architecture.md)
- [Native Windows app](windows/README.md)
- [OPL Fleet Gateway](https://github.com/gaofeng21cn/opl-fleet-cockpit)
- [Repository Agent contract](AGENTS.md)

```bash
xcrun swift-format lint --recursive Sources Tests Package.swift
swift test
swift run codex-tps-snapshot --json
./scripts/build-app.sh
./scripts/build-dmg.sh
```

OPL Fleet Agent is available under the [Apache License 2.0](LICENSE). Its accounting semantics were
informed by the public [Tokscale](https://github.com/junhoyeo/tokscale) project, but
OPL Fleet Agent is an independent implementation and does not embed Tokscale.

OPL Fleet Agent is an unofficial community project and is not affiliated with, endorsed by,
or sponsored by OpenAI.
