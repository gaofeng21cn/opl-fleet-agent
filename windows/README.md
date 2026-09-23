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
runtime. It installs for the current user under
`%LOCALAPPDATA%\Programs\OPL Fleet Agent`, adds a Start-menu shortcut, supports
in-place upgrades, and registers a normal Windows uninstaller. The executable is
`OPLFleetAgent.exe`, settings live under `%LOCALAPPDATA%\OPL Fleet Agent`, and startup
uses the `OPL Fleet Agent` registry value.

After launch, the app checks the latest GitHub Release and repeats the check
every six hours. It never installs silently without user confirmation. After
**Update now** is selected, the app downloads the installer and published
checksum, verifies SHA-256, copies a temporary updater, and exits. The updater
waits for that exact old PID, verifies the package again, runs the current-user
installer, reads back the installed file version, and launches a distinct new
process. If the transaction fails, it writes a failure receipt and relaunches
the still-usable installed executable. This mirrors the macOS user flow while
keeping the platform-specific installation transaction native.

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
