# Codex TPS for Windows

Codex TPS for Windows is a native .NET 8 WinForms tray application. It reads
the token accounting events already written under the current Windows user's
Codex home and can send aggregate metrics to Ambient Ops on the local network.

## Runtime behavior

- Default input: `%USERPROFILE%\.codex\sessions`
- Override: set `CODEX_HOME`, or select a Codex home in Settings
- Taskbar readout renders large, waveform-prefixed TPS text without a background badge; clicking it opens the dashboard
- Five-second local refresh; Ambient Ops pushes are limited to once per ten seconds
- `_ambient-ops._tcp.local.` DNS-SD discovery with preferred-instance and fallback behavior
- Manual Ambient Ops HTTP(S) URL override
- Optional Ledger Owl state using the same Ambient Ops v2 payload as macOS
- Optional per-user startup through `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
- Automatic one-click pairing with Ambient Ops v0.1.4+ after LAN discovery
- Per-device P-256 private key encrypted for the current Windows user with DPAPI
- Legacy push token remains available as a DPAPI-protected compatibility path

The dashboard reports one-minute total, input, cached input, output, reasoning
and session activity as TPS values. Cached input remains a subset of input, and
reasoning remains a subset of output; neither is added twice.

Windows 11 may initially place a new tray icon under the `^` overflow menu.
Windows owns that preference, so pin Codex TPS once in Taskbar settings when the
live TPS icon should remain in the primary notification area.

## Privacy contract

The scanner filters JSONL bytes for `session_meta`, `turn_context`,
`task_started` and `token_count` markers before JSON decoding. Conversation-only
records are not decoded or retained. Ambient Ops receives only:

- stable machine ID in the request path;
- machine name, platform, generated time and collection status;
- aggregate one-minute and five-minute token counters;
- active-session count;
- optional pet identity and activity state.

Session IDs, file paths, prompts, responses and tool content are never included
in the network payload. The app contains no analytics or account login.

## Install the release

Download these two files from the
[latest GitHub Release](https://github.com/gaofeng21cn/codex-tps/releases/latest):

```text
Codex-TPS-Windows-win-x64-Setup.exe
Codex-TPS-Windows-win-x64-Setup.exe.sha256
```

Verify the installer in PowerShell, then open it:

```powershell
$installer = ".\Codex-TPS-Windows-win-x64-Setup.exe"
$expected = ((Get-Content "$installer.sha256" -Raw).Trim() -split "\s+")[0]
$actual = (Get-FileHash -Algorithm SHA256 $installer).Hash
if ($expected -ne $actual) { throw "Installer checksum mismatch" }
Start-Process $installer -Wait
```

The standard installer is self-contained and does not require a separate .NET
runtime. It installs for the current user under
`%LOCALAPPDATA%\Programs\Codex TPS`, adds a Start-menu shortcut, supports
in-place upgrades, and registers a normal Windows uninstaller. Uninstalling the
app preserves `%LOCALAPPDATA%\Codex TPS\settings.json`; it removes an enabled
Codex TPS login-startup registry value so Windows does not retain a dead path.

The Windows installer is not yet Authenticode-signed because this repository
does not have a Windows code-signing certificate. Windows can therefore show
an unknown-publisher or SmartScreen warning even when the published SHA-256
matches. The GitHub Release, checksum, and CI receipts prove repository
provenance but do not replace Authenticode trust or SmartScreen reputation.

## Build

Install the .NET 8 SDK and PowerShell 7, then run from the repository root:

```powershell
pwsh ./windows/scripts/build.ps1 -Runtime win-x64
```

The script runs Core tests, publishes a self-contained single-file app, and
creates:

```text
windows/dist/Codex-TPS-Windows-win-x64.zip
windows/dist/Codex-TPS-Windows-win-x64.zip.sha256
```

To build the standard installer, also install Inno Setup 6 and run:

```powershell
pwsh ./windows/scripts/build-installer.ps1 -Runtime win-x64 -Version 0.2.18
```

This additionally creates:

```text
windows/dist/Codex-TPS-Windows-win-x64-Setup.exe
windows/dist/Codex-TPS-Windows-win-x64-Setup.exe.sha256
```

The GitHub `CI` workflow builds `win-x64` on a real Windows runner and uploads
the same ZIP/checksum pair. CI artifacts are unsigned development builds; they
are not a Windows release or SmartScreen reputation proof.

The first productized target is `win-x64`. Windows on Arm can run it through
the operating system's x64 emulation; a native Arm64 artifact is not yet a
validated target.

## Install the portable archive

Exit an existing tray process, then install the built archive for the current
user:

```powershell
pwsh ./windows/scripts/install.ps1 `
  -ArchivePath ./windows/dist/Codex-TPS-Windows-win-x64.zip
```

The PowerShell installer stages and verifies the archive before replacing
`%LOCALAPPDATA%\Programs\Codex TPS`, restoring the previous directory if the
replacement fails. The sibling `.sha256` file is mandatory and checked before
extraction. Neither installation route enables startup automatically; use the
checkbox in Settings.

## Native Windows and WSL sessions

Native Windows Codex sessions use `%USERPROFILE%\.codex`. If Codex runs inside
WSL, select an accessible UNC Codex home such as
`\\wsl.localhost\Ubuntu\home\<user>\.codex`. Codex TPS does not launch Codex,
change its execution environment, or silently switch between native Windows
and WSL stores.

## Source layout

- `src/CodexTPS.Core`: parser, replay deduplication, rolling metrics and payload contract
- `src/CodexTPS.Windows`: WinForms tray, settings, DPAPI, startup and DNS-SD
- `tests/CodexTPS.Core.Tests`: deterministic accounting/privacy/discovery tests

Before calling a Windows build production-ready, verify on a clean Windows 11
machine: first launch, tray interaction, DPAPI persistence, startup after sign-in,
local-network firewall consent and discovery, sleep/network recovery, and an
actual Ambient Ops accepted push.

With Ambient Ops v0.1.4+, first discovery creates a device key locally, opens the
server approval page once, and shows the same six-digit code in Codex TPS. After
approval, signed pushes resume automatically across application restarts. The
settings file must contain `ProtectedDevicePrivateKey`, never a plaintext private
key. The **Compatible token** field is only for older Ambient Ops servers.
