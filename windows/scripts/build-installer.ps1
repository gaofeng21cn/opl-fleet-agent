param(
    [ValidateSet("win-x64")]
    [string]$Runtime = "win-x64",
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$Version = "0.2.35",
    [switch]$SkipTests,
    [switch]$SkipAppBuild
)

$ErrorActionPreference = "Stop"
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must use MAJOR.MINOR.PATCH format."
}

$windowsRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $windowsRoot
$publishRoot = Join-Path $windowsRoot "dist/$Runtime"
$distRoot = Join-Path $windowsRoot "dist"
$definition = Join-Path $windowsRoot "installer/CodexTPS.iss"
$installer = Join-Path $distRoot "OPL-Fleet-Agent-Windows-$Runtime-Setup.exe"
$checksum = "$installer.sha256"
$legacyInstaller = Join-Path $distRoot "Codex-TPS-Windows-$Runtime-Setup.exe"
$legacyChecksum = "$legacyInstaller.sha256"

if (-not $SkipAppBuild) {
    & (Join-Path $PSScriptRoot "build.ps1") `
        -Runtime $Runtime `
        -Configuration $Configuration `
        -Version $Version `
        -SkipTests:$SkipTests
    if ($LASTEXITCODE -ne 0) { throw "Windows app build failed." }
}

$executable = Join-Path $publishRoot "OPLFleetAgent.exe"
if (-not (Test-Path $executable)) {
    throw "Published OPLFleetAgent.exe is missing."
}
$legacyExecutable = Join-Path $publishRoot "CodexTPS.exe"
if (Test-Path $legacyExecutable) {
    throw "Published payload must not include CodexTPS.exe."
}

$compilerCandidates = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source),
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6/ISCC.exe"),
    (Join-Path $env:ProgramFiles "Inno Setup 6/ISCC.exe")
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
$compiler = $compilerCandidates | Select-Object -First 1
if (-not $compiler) {
    throw "Inno Setup 6 is required. Install it from https://jrsoftware.org/isdl.php."
}

if (Test-Path $installer) { Remove-Item -Force $installer }
if (Test-Path $checksum) { Remove-Item -Force $checksum }
if (Test-Path $legacyInstaller) { Remove-Item -Force $legacyInstaller }
if (Test-Path $legacyChecksum) { Remove-Item -Force $legacyChecksum }

$previousEnvironment = @{
    CODEX_TPS_INSTALLER_VERSION = $env:CODEX_TPS_INSTALLER_VERSION
    CODEX_TPS_INSTALLER_VERSION_QUAD = $env:CODEX_TPS_INSTALLER_VERSION_QUAD
    CODEX_TPS_INSTALLER_SOURCE = $env:CODEX_TPS_INSTALLER_SOURCE
    CODEX_TPS_INSTALLER_OUTPUT = $env:CODEX_TPS_INSTALLER_OUTPUT
}
try {
    $env:CODEX_TPS_INSTALLER_VERSION = $Version
    $env:CODEX_TPS_INSTALLER_VERSION_QUAD = "$Version.0"
    $env:CODEX_TPS_INSTALLER_SOURCE = $publishRoot
    $env:CODEX_TPS_INSTALLER_OUTPUT = $distRoot
    & $compiler /Qp $definition
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed." }
}
finally {
    foreach ($entry in $previousEnvironment.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            Remove-Item -Path "Env:$($entry.Key)" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
        }
    }
}

if (-not (Test-Path $installer)) {
    throw "Windows installer was not created."
}
$hash = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
$line = "$hash  $(Split-Path -Leaf $installer)"
[System.IO.File]::WriteAllText($checksum, "$line`n", [System.Text.Encoding]::ASCII)
Copy-Item $installer $legacyInstaller
$legacyHash = (Get-FileHash -Algorithm SHA256 $legacyInstaller).Hash.ToLowerInvariant()
$legacyLine = "$legacyHash  $(Split-Path -Leaf $legacyInstaller)"
[System.IO.File]::WriteAllText($legacyChecksum, "$legacyLine`n", [System.Text.Encoding]::ASCII)
Write-Output $installer
Write-Output $line
Write-Output $legacyInstaller
Write-Output $legacyLine
