param(
    [ValidateSet("win-x64")]
    [string]$Runtime = "win-x64",
    [string]$OutputDirectory,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

$winSparkleVersion = "0.9.4"
$archiveUrl = "https://github.com/vslavik/winsparkle/releases/download/v$winSparkleVersion/WinSparkle-$winSparkleVersion.zip"
$expectedArchiveSha256 = "6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976"
$expectedDllSha256 = "9b43b1c16ee39fb9a91b5bd75138767898779510e0836be2919250607cdbe8ab"
$expectedToolSha256 = "0c5412c481be6146313a2af46cce4a928913c94754763a75bb11ef15c9097cc3"
$dllEntryPath = "WinSparkle-$winSparkleVersion/x64/Release/WinSparkle.dll"
$toolEntryPath = "WinSparkle-$winSparkleVersion/bin/winsparkle-tool.exe"

$windowsRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $windowsRoot ".winsparkle/$winSparkleVersion/$Runtime"
}

function Test-FileSha256([string]$Path, [string]$ExpectedSha256) {
    if (-not (Test-Path $Path)) {
        return $false
    }
    $actual = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
    return $actual -eq $ExpectedSha256.ToLowerInvariant()
}

function Assert-FileSha256([string]$Path, [string]$ExpectedSha256, [string]$Label) {
    if (-not (Test-Path $Path)) {
        throw "Expected $Label is missing: $Path"
    }
    $actual = (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "$Label SHA-256 mismatch. Expected $ExpectedSha256, got $actual."
    }
}

$dllPath = Join-Path $OutputDirectory "WinSparkle.dll"
$toolPath = Join-Path $OutputDirectory "winsparkle-tool.exe"

if (-not (Test-FileSha256 $dllPath $expectedDllSha256) -or
    -not (Test-FileSha256 $toolPath $expectedToolSha256)) {
    New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("opl-winsparkle-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $stagingRoot | Out-Null
    try {
        $archivePath = Join-Path $stagingRoot "WinSparkle-$winSparkleVersion.zip"
        $downloaded = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -TimeoutSec 120
                $downloaded = $true
                break
            }
            catch {
                if ($attempt -eq 3) {
                    throw "Failed to download WinSparkle $winSparkleVersion after 3 attempts: $($_.Exception.Message)"
                }
                Start-Sleep -Seconds ($attempt * 2)
            }
        }
        if (-not $downloaded) {
            throw "Failed to download WinSparkle $winSparkleVersion."
        }

        Assert-FileSha256 $archivePath $expectedArchiveSha256 "WinSparkle-$winSparkleVersion.zip"

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $stagedDll = Join-Path $stagingRoot "WinSparkle.dll"
        $stagedTool = Join-Path $stagingRoot "winsparkle-tool.exe"
        $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $dllEntry = $zip.GetEntry($dllEntryPath)
            if ($null -eq $dllEntry) {
                throw "Entry '$dllEntryPath' was not found in WinSparkle-$winSparkleVersion.zip."
            }
            $toolEntry = $zip.GetEntry($toolEntryPath)
            if ($null -eq $toolEntry) {
                throw "Entry '$toolEntryPath' was not found in WinSparkle-$winSparkleVersion.zip."
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($dllEntry, $stagedDll, $true)
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($toolEntry, $stagedTool, $true)
        }
        finally {
            $zip.Dispose()
        }

        Assert-FileSha256 $stagedDll $expectedDllSha256 "WinSparkle.dll"
        Assert-FileSha256 $stagedTool $expectedToolSha256 "winsparkle-tool.exe"

        Copy-Item -Force $stagedDll $dllPath
        Copy-Item -Force $stagedTool $toolPath
    }
    finally {
        if (Test-Path $stagingRoot) {
            Remove-Item -Recurse -Force $stagingRoot
        }
    }
}

Assert-FileSha256 $dllPath $expectedDllSha256 "WinSparkle.dll"
Assert-FileSha256 $toolPath $expectedToolSha256 "winsparkle-tool.exe"

$result = [pscustomobject]@{
    Version = $winSparkleVersion
    Runtime = $Runtime
    DllPath = (Resolve-Path $dllPath).Path
    DllSha256 = $expectedDllSha256
    ToolPath = (Resolve-Path $toolPath).Path
    ToolSha256 = $expectedToolSha256
}

if ($PassThru) {
    return $result
}

Write-Output "Verified WinSparkle $($result.Version) ($Runtime): $($result.DllPath)"
