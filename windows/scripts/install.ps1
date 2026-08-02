param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA "Programs/OPL Fleet Agent"),
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$resolvedArchive = (Resolve-Path $ArchivePath).Path
$checksumPath = "$resolvedArchive.sha256"
if (-not (Test-Path $checksumPath)) {
    throw "Required SHA-256 file is missing: $checksumPath."
}
$expected = ((Get-Content $checksumPath -Raw).Trim() -split "\s+")[0].ToLowerInvariant()
if ($expected -notmatch "^[a-f0-9]{64}$") {
    throw "Invalid SHA-256 file: $checksumPath."
}
$actual = (Get-FileHash -Algorithm SHA256 $resolvedArchive).Hash.ToLowerInvariant()
if ($expected -ne $actual) {
    throw "Archive SHA-256 does not match $checksumPath."
}
$running = Get-Process -Name "CodexTPS" -ErrorAction SilentlyContinue
if ($running) {
    throw "Exit OPL Fleet Agent from its tray menu before installing an update."
}

$stageParent = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-tps-install-" + [guid]::NewGuid())
$stage = Join-Path $stageParent "app"
$backup = "$InstallDirectory.backup-" + [guid]::NewGuid()
$defaultInstallDirectory = Join-Path $env:LOCALAPPDATA "Programs/OPL Fleet Agent"
$legacyInstallDirectory = Join-Path $env:LOCALAPPDATA "Programs/Codex TPS"
$migrateLegacy = [string]::Equals(
    [System.IO.Path]::GetFullPath($InstallDirectory),
    [System.IO.Path]::GetFullPath($defaultInstallDirectory),
    [System.StringComparison]::OrdinalIgnoreCase
)
$legacyBackup = "$legacyInstallDirectory.backup-" + [guid]::NewGuid()
New-Item -ItemType Directory -Force $stage | Out-Null
try {
    Expand-Archive -Path $resolvedArchive -DestinationPath $stage -Force
    $executable = Join-Path $stage "CodexTPS.exe"
    if (-not (Test-Path $executable)) {
        throw "CodexTPS.exe is missing from the archive."
    }

    $installParent = Split-Path -Parent $InstallDirectory
    New-Item -ItemType Directory -Force $installParent | Out-Null
    if (Test-Path $InstallDirectory) {
        Move-Item $InstallDirectory $backup
    }
    if ($migrateLegacy -and (Test-Path $legacyInstallDirectory)) {
        Move-Item $legacyInstallDirectory $legacyBackup
    }
    try {
        Move-Item $stage $InstallDirectory
    }
    catch {
        if (Test-Path $backup) {
            Move-Item $backup $InstallDirectory
        }
        if (Test-Path $legacyBackup) {
            Move-Item $legacyBackup $legacyInstallDirectory
        }
        throw
    }
    if (Test-Path $backup) {
        Remove-Item -Recurse -Force $backup
    }
    if (Test-Path $legacyBackup) {
        Remove-Item -Recurse -Force $legacyBackup
    }

    if (-not $NoLaunch) {
        Start-Process `
            (Join-Path $InstallDirectory "CodexTPS.exe") `
            -ArgumentList "--background"
    }
    Write-Output "Installed OPL Fleet Agent to $InstallDirectory"
}
finally {
    if (Test-Path $stageParent) {
        Remove-Item -Recurse -Force $stageParent
    }
}
