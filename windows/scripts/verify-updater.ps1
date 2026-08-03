param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [string]$PreviousVersion = "0.2.32",
    [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or
    $PreviousVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "Versions must use MAJOR.MINOR.PATCH format."
}

$windowsRoot = Split-Path -Parent $PSScriptRoot
$installer = (Resolve-Path (
    Join-Path $windowsRoot "dist/Codex-TPS-Windows-$Runtime-Setup.exe"
)).Path
$publishedExecutable = (Resolve-Path (
    Join-Path $windowsRoot "dist/$Runtime/OPLFleetAgent.exe"
)).Path
$expectedSha256 = (
    (Get-Content "$installer.sha256" -Raw).Trim() -split "\s+"
)[0].ToLowerInvariant()

$testRoot = Join-Path $env:RUNNER_TEMP "opl-fleet-agent-updater-$([Guid]::NewGuid().ToString('N'))"
$previousInstaller = Join-Path $testRoot "previous-setup.exe"
$previousChecksum = "$previousInstaller.sha256"
$installDirectory = Join-Path $testRoot "Codex TPS"
$canonicalInstallDirectory = Join-Path $testRoot "OPL Fleet Agent"
$stagingDirectory = Join-Path $testRoot "staging"
$helper = Join-Path $stagingDirectory "OPLFleetAgent.Updater.exe"
$requestPath = Join-Path $stagingDirectory "update-request.json"
$resultPath = Join-Path $testRoot "update-result.json"
$oldProcess = $null
$newProcess = $null
$uninstaller = Join-Path $installDirectory "unins000.exe"

New-Item -ItemType Directory -Force $stagingDirectory | Out-Null
try {
    $releaseRepository = if (
        [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)
    ) {
        "gaofeng21cn/opl-fleet-agent"
    } else {
        $env:GITHUB_REPOSITORY
    }
    if ($releaseRepository -notin @(
        "gaofeng21cn/opl-fleet-agent",
        "gaofeng21cn/codex-tps"
    )) {
        throw "Unsupported previous-release repository: $releaseRepository"
    }
    $releaseRoot = "https://github.com/$releaseRepository/releases/download/v$PreviousVersion"
    Invoke-WebRequest `
        "$releaseRoot/Codex-TPS-Windows-win-x64-Setup.exe" `
        -OutFile $previousInstaller
    Invoke-WebRequest `
        "$releaseRoot/Codex-TPS-Windows-win-x64-Setup.exe.sha256" `
        -OutFile $previousChecksum
    $previousExpected = (
        (Get-Content $previousChecksum -Raw).Trim() -split "\s+"
    )[0].ToLowerInvariant()
    $previousActual = (
        Get-FileHash -Algorithm SHA256 $previousInstaller
    ).Hash.ToLowerInvariant()
    if ($previousExpected -ne $previousActual) {
        throw "Previous release checksum mismatch."
    }

    $installArguments = @(
        "/VERYSILENT",
        "/SUPPRESSMSGBOXES",
        "/NORESTART",
        "/NOICONS",
        "/DIR=`"$installDirectory`""
    )
    $installResult = Start-Process `
        $previousInstaller `
        -ArgumentList $installArguments `
        -Wait `
        -PassThru
    if ($installResult.ExitCode -ne 0) {
        throw "Previous installer exited with $($installResult.ExitCode)."
    }

    $targetExecutable = Join-Path $installDirectory "CodexTPS.exe"
    $oldVersion = (Get-Item $targetExecutable).VersionInfo.ProductVersion
    if (-not $oldVersion.StartsWith($PreviousVersion)) {
        throw "Expected previous version $PreviousVersion, got $oldVersion."
    }

    $oldProcess = Start-Process `
        $targetExecutable `
        -ArgumentList "--background" `
        -PassThru
    Start-Sleep -Seconds 2
    if ($oldProcess.HasExited) {
        throw "Previous release exited before the updater handoff."
    }

    Copy-Item $publishedExecutable $helper
    $request = [ordered]@{
        ParentProcessId = $oldProcess.Id
        CurrentExecutablePath = $targetExecutable
        InstallDirectory = $installDirectory
        InstallerPath = $installer
        ExpectedSha256 = $expectedSha256
        ExpectedVersion = $Version
        ResultPath = $resultPath
        StagingDirectory = $stagingDirectory
    }
    $request | ConvertTo-Json | Set-Content -Encoding utf8 $requestPath

    $helperProcess = Start-Process `
        $helper `
        -ArgumentList @("--apply-update", "`"$requestPath`"") `
        -PassThru
    Start-Sleep -Seconds 1
    Stop-Process -Id $oldProcess.Id -Force
    $oldProcess.WaitForExit()
    if (-not $helperProcess.WaitForExit(120000)) {
        Stop-Process -Id $helperProcess.Id -Force
        throw "Updater helper timed out."
    }
    if ($helperProcess.ExitCode -ne 0) {
        throw "Updater helper exited with $($helperProcess.ExitCode)."
    }

    $canonicalExecutable = Join-Path $canonicalInstallDirectory "OPLFleetAgent.exe"
    $installedVersion = (Get-Item $canonicalExecutable).VersionInfo.ProductVersion
    $installedProductName = (Get-Item $canonicalExecutable).VersionInfo.ProductName
    if (-not $installedVersion.StartsWith($Version)) {
        throw "Expected updated version $Version, got $installedVersion."
    }
    if ($installedProductName -ne "OPL Fleet Agent") {
        throw "Expected product name OPL Fleet Agent, got $installedProductName."
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $newProcess = Get-Process -Name "OPLFleetAgent" -ErrorAction SilentlyContinue |
            Where-Object {
                try {
                    $_.Path -eq $canonicalExecutable
                }
                catch {
                    $false
                }
            } |
            Select-Object -First 1
        if (-not $newProcess) {
            Start-Sleep -Milliseconds 250
        }
    } while (-not $newProcess -and (Get-Date) -lt $deadline)
    if (-not $newProcess -or $newProcess.HasExited) {
        throw "Updated OPL Fleet Agent process was not running after handoff."
    }

    $cleanupDeadline = (Get-Date).AddSeconds(15)
    while ((Test-Path $targetExecutable) -and (Get-Date) -lt $cleanupDeadline) {
        Start-Sleep -Milliseconds 250
    }
    if (Test-Path $targetExecutable) {
        throw "Legacy CodexTPS.exe bridge was not removed after migration."
    }

    Write-Output (
        "Verified in-app updater handoff: " +
        "$PreviousVersion PID $($oldProcess.Id) -> $Version PID $($newProcess.Id)."
    )
}
finally {
    if ($oldProcess -and -not $oldProcess.HasExited) {
        Stop-Process -Id $oldProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($newProcess -and -not $newProcess.HasExited) {
        Stop-Process -Id $newProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name @("OPLFleetAgent", "CodexTPS") -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if (Test-Path $uninstaller) {
        $uninstallResult = Start-Process `
            $uninstaller `
            -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") `
            -Wait `
            -PassThru
        if ($uninstallResult.ExitCode -ne 0) {
            Write-Warning "Updater test uninstaller exited with $($uninstallResult.ExitCode)."
        }
    }
    if (Test-Path $testRoot) {
        Remove-Item -Recurse -Force $testRoot
    }
}
