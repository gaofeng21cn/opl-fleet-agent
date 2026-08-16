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
$running = Get-Process -Name "OPLFleetAgent" -ErrorAction SilentlyContinue
if ($running) {
    throw "Exit OPL Fleet Agent from its tray menu before installing an update."
}

$stageParent = Join-Path ([System.IO.Path]::GetTempPath()) ("opl-fleet-agent-install-" + [guid]::NewGuid())
$stage = Join-Path $stageParent "app"
$backup = "$InstallDirectory.backup-" + [guid]::NewGuid()
New-Item -ItemType Directory -Force $stage | Out-Null
try {
    Expand-Archive -Path $resolvedArchive -DestinationPath $stage -Force
    $executable = Join-Path $stage "OPLFleetAgent.exe"
    if (-not (Test-Path $executable)) {
        throw "OPLFleetAgent.exe is missing from the archive."
    }
    if (Test-Path (Join-Path $stage "CodexTPS.exe")) {
        throw "The archive must not include CodexTPS.exe."
    }

    $installParent = Split-Path -Parent $InstallDirectory
    New-Item -ItemType Directory -Force $installParent | Out-Null
    if (Test-Path $InstallDirectory) {
        Move-Item $InstallDirectory $backup
    }
    try {
        Move-Item $stage $InstallDirectory
    }
    catch {
        if (Test-Path $backup) {
            Move-Item $backup $InstallDirectory
        }
        throw
    }
    if (Test-Path $backup) {
        Remove-Item -Recurse -Force $backup
    }
    if (-not $NoLaunch) {
        Start-Process `
            (Join-Path $InstallDirectory "OPLFleetAgent.exe") `
            -ArgumentList "--background"
    }
    Write-Output "Installed OPL Fleet Agent to $InstallDirectory"
}
finally {
    if (Test-Path $stageParent) {
        Remove-Item -Recurse -Force $stageParent
    }
}
