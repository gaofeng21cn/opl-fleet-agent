# Windows Installation and Operation

OPL Fleet Agent for Windows is a native .NET 8 WinForms tray application. It reads
the token accounting events already written under the current Windows user's
Codex home and can send aggregate metrics to OPL Fleet Gateway on the local network.

## Runtime behavior

The default source is `%USERPROFILE%\.codex\sessions`. Set `CODEX_HOME` or choose
a Codex home in Settings for another source. Local refresh is configurable;
Gateway pushes are limited to once per ten seconds.

Click the taskbar TPS badge or the numeric notification icon to open the dashboard.
The badge follows the taskbar's light or dark theme. The dashboard returns to the
notification area when it loses focus and provides an explicit minimize-to-tray
button. The tray menu provides the Codex sessions shortcut. Settings also
controls per-user startup through
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run` and optional pet display.

The dashboard reports one-minute total, input, cached input, output, and reasoning
as TPS values, alongside active sessions. Cached input remains a subset of input,
and reasoning remains a subset of output; neither is added twice.

Windows 11 may initially place a new tray icon under the `^` overflow menu.
Windows owns that preference, so pin OPL Fleet Agent once in Taskbar settings when the
live TPS icon should remain in the primary notification area.

The scanner and outbound privacy contract are owned by
[architecture](../docs/architecture.md). Windows supports local collection and
Gateway push but does not publish a Direct server. Gateway connection procedures
and credential handling are in [Agent operations](../docs/operations.md).

The optional Package invokes the installed `OPLFleetAgentProvider` executable.
It reads the same saved machine ID, display name, and Codex home as the native
app from `%LOCALAPPDATA%\OPL Fleet Agent\settings.json`. Explicit process values
for `OPL_FLEET_AGENT_MACHINE_ID`, `OPL_FLEET_AGENT_MACHINE_NAME`,
`OPL_FLEET_AGENT_PLATFORM`, or `CODEX_HOME` override those observation fields.
The provider does not decrypt the app's token or pairing key, change settings,
or configure Gateway push. An unreadable settings document or invalid saved ID
makes the provider unavailable instead of silently identifying a different node.
Last-known observations are bound to the node identity and resolved Codex home
by a digest. A missing source can retain the same node's stale sample; switching
node or collection source cannot reuse it. Older unbound cache records are
discarded and a fresh native observation repopulates the cache.

## Install the release

Download these two files from the
[latest GitHub Release](https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest):

```text
OPL-Fleet-Agent-Windows-win-x64-Setup.exe
OPL-Fleet-Agent-Windows-win-x64-Setup.exe.sha256
```

Verify the installer in PowerShell, then open it:

```powershell
$installer = ".\OPL-Fleet-Agent-Windows-win-x64-Setup.exe"
$expected = ((Get-Content "$installer.sha256" -Raw).Trim() -split "\s+")[0]
$actual = (Get-FileHash -Algorithm SHA256 $installer).Hash
if ($expected -ne $actual) { throw "Installer checksum mismatch" }
Start-Process $installer -Wait
```

The standard installer is self-contained and does not require a separate .NET
runtime. It installs `OPLFleetAgent.exe`, `OPLFleetAgentProvider.exe`, and
`WinSparkle.dll` for the current user under
`%LOCALAPPDATA%\Programs\OPL Fleet Agent`, adds a Start-menu shortcut, supports
in-place upgrades, and registers a normal Windows uninstaller. Settings live
under `%LOCALAPPDATA%\OPL Fleet Agent`, WinSparkle state lives under
`HKCU\Software\OPL Fleet Agent\WinSparkle`, and startup uses the
`OPL Fleet Agent` registry value.

In-app automatic updates are powered by **WinSparkle** using the Ed25519-signed
`windows-appcast.xml` feed at
`https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest/download/windows-appcast.xml`.
Automatic checks run every six hours by default and can be toggled in Settings
(**自动检查更新**); manual **Check for Updates** (**检查更新**) controls are
available in the tray menu, dashboard header, and Settings. WinSparkle never
installs without user confirmation: once you confirm an update, it downloads
`OPL-Fleet-Agent-Windows-win-x64-Setup.exe`, cryptographically verifies its
`sparkle:edSignature` against the embedded Ed25519 public key (matching macOS
Sparkle 2), asks OPL Fleet Agent to shut down cleanly, and runs Inno Setup
with `/SILENT /SP- /NOICONS /LAUNCHAFTERUPDATE=1` to upgrade in place and
relaunch in the background.

The Windows installer is not yet Authenticode-signed in the current packaging
workflow. Windows can therefore show an unknown-publisher or SmartScreen warning
even when the published SHA-256
matches. The GitHub Release, checksum, and CI receipts prove repository
provenance but do not replace Authenticode trust or SmartScreen reputation.

## Build a package

See [development](../docs/development.md) for toolchains, build commands,
current targets, and the separate CI, Qualification, and Release workflows.

## Install the portable archive

Exit an existing tray process, then install the built archive for the current
user:

```powershell
pwsh ./windows/scripts/install.ps1 `
  -ArchivePath ./windows/dist/OPL-Fleet-Agent-Windows-win-x64.zip
```

The PowerShell installer stages and verifies the archive before replacing
`%LOCALAPPDATA%\Programs\OPL Fleet Agent`. The sibling `.sha256` file is mandatory and checked before
extraction. Neither installation route enables startup automatically; use the
checkbox in Settings.

## Native Windows and WSL sessions

Native Windows Codex sessions use `%USERPROFILE%\.codex`. If Codex runs inside
WSL, select an accessible UNC Codex home such as
`\\wsl.localhost\Ubuntu\home\<user>\.codex`. OPL Fleet Agent does not launch Codex,
change its execution environment, or silently switch between native Windows
and WSL stores.
