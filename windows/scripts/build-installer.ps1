param(
    [ValidateSet("win-x64")]
    [string]$Runtime = "win-x64",
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$Version = "0.2.39",
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

$previousEnvironment = @{
    OPL_FLEET_AGENT_INSTALLER_VERSION = $env:OPL_FLEET_AGENT_INSTALLER_VERSION
    OPL_FLEET_AGENT_INSTALLER_VERSION_QUAD = $env:OPL_FLEET_AGENT_INSTALLER_VERSION_QUAD
    OPL_FLEET_AGENT_INSTALLER_SOURCE = $env:OPL_FLEET_AGENT_INSTALLER_SOURCE
    OPL_FLEET_AGENT_INSTALLER_OUTPUT = $env:OPL_FLEET_AGENT_INSTALLER_OUTPUT
}
try {
    $env:OPL_FLEET_AGENT_INSTALLER_VERSION = $Version
    $env:OPL_FLEET_AGENT_INSTALLER_VERSION_QUAD = "$Version.0"
    $env:OPL_FLEET_AGENT_INSTALLER_SOURCE = $publishRoot
    $env:OPL_FLEET_AGENT_INSTALLER_OUTPUT = $distRoot
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
Write-Output $installer
Write-Output $line
