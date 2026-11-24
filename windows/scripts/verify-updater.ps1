param(
    [string]$Version,
    [string]$Runtime = "win-x64"
)

$ErrorActionPreference = "Stop"

function Wait-BoundedProcess($Process, [string]$Stage, [int]$TimeoutMs = 120000) {
    Write-Output "stage=$Stage pid=$($Process.Id)"
    if (-not $Process.WaitForExit($TimeoutMs)) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        throw "$Stage timed out after $TimeoutMs ms."
    }
    $Process.Refresh()
}

$windowsRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Version)) {
    [xml]$project = Get-Content (Join-Path $windowsRoot "src/OPLFleetAgent.Windows/OPLFleetAgent.Windows.csproj")
    $Version = $project.Project.PropertyGroup.Version.Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must use MAJOR.MINOR.PATCH format, got '$Version'."
}

$installer = (Resolve-Path (
    Join-Path $windowsRoot "dist/OPL-Fleet-Agent-Windows-$Runtime-Setup.exe"
)).Path
$publishedWinSparkle = (Resolve-Path (
    Join-Path $windowsRoot "dist/$Runtime/WinSparkle.dll"
)).Path

$winSparkle = & (Join-Path $PSScriptRoot "fetch-winsparkle.ps1") -Runtime $Runtime -PassThru
$actualPublishedDllHash = (Get-FileHash -Algorithm SHA256 $publishedWinSparkle).Hash.ToLowerInvariant()
if ($actualPublishedDllHash -ne $winSparkle.DllSha256) {
    throw "Published WinSparkle.dll SHA-256 mismatch. Expected $($winSparkle.DllSha256), got $actualPublishedDllHash."
}

$tempBase = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetTempPath()
} else {
    $env:RUNNER_TEMP
}
$testRoot = Join-Path $tempBase ("opl-fleet-agent-winsparkle-" + [Guid]::NewGuid().ToString("N"))
$installDirectory = Join-Path $testRoot "OPL Fleet Agent"
$uninstaller = Join-Path $installDirectory "unins000.exe"
$launchedProcess = $null

New-Item -ItemType Directory -Force $testRoot | Out-Null
try {
    # 1. Verify end-to-end Ed25519 signing, appcast generation, and verification using an ephemeral key pair.
    $ephemeralKey = Join-Path $testRoot "ephemeral.key"
    $keyGenOutput = & $winSparkle.ToolPath generate-key -f $ephemeralKey 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "winsparkle-tool generate-key failed: $($keyGenOutput -join ' ')"
    }
    $pubMatch = [regex]::Match(($keyGenOutput -join "`n"), 'Public key:\s*([A-Za-z0-9+/=]+)')
    if (-not $pubMatch.Success) {
        throw "Could not parse ephemeral Ed25519 public key."
    }
    $ephemeralPubKey = $pubMatch.Groups[1].Value.Trim()

    $appcastPath = Join-Path $testRoot "windows-appcast.xml"
    & (Join-Path $PSScriptRoot "generate-windows-appcast.ps1") `
        -InstallerPath $installer `
        -Version $Version `
        -OutputPath $appcastPath `
        -ExpectedPublicKey $ephemeralPubKey `
        -SigningKeyPath $ephemeralKey `
        -WinSparkleToolPath $winSparkle.ToolPath | Out-Null

    [xml]$appcast = Get-Content -Raw -Encoding utf8 $appcastPath
    $sparkleNs = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    $nsManager = New-Object System.Xml.XmlNamespaceManager($appcast.NameTable)
    $nsManager.AddNamespace("sparkle", $sparkleNs)
    $enclosure = $appcast.SelectSingleNode("/rss/channel/item/enclosure")
    $signature = $enclosure.GetAttribute("edSignature", $sparkleNs)
    $installerArgs = $enclosure.GetAttribute("installerArguments", $sparkleNs)
    if ($installerArgs -ne "/SILENT /SP- /NOICONS /LAUNCHAFTERUPDATE=1") {
        throw "Unexpected sparkle:installerArguments: $installerArgs"
    }

    # 2. Negative check: mismatched Ed25519 private key must fail closed.
    $wrongKey = Join-Path $testRoot "wrong.key"
    & $winSparkle.ToolPath generate-key -f $wrongKey | Out-Null
    $wrongKeyAccepted = $false
    try {
        & (Join-Path $PSScriptRoot "generate-windows-appcast.ps1") `
            -InstallerPath $installer `
            -Version $Version `
            -OutputPath (Join-Path $testRoot "wrong-appcast.xml") `
            -ExpectedPublicKey $ephemeralPubKey `
            -SigningKeyPath $wrongKey `
            -WinSparkleToolPath $winSparkle.ToolPath | Out-Null
        $wrongKeyAccepted = $true
    }
    catch {
        # Expected failure.
    }
    if ($wrongKeyAccepted) {
        throw "generate-windows-appcast.ps1 unexpectedly accepted a mismatched Ed25519 key."
    }

    # 3. Negative check: tampered installer bytes must fail Ed25519 verification.
    $tamperedInstaller = Join-Path $testRoot "tampered-setup.exe"
    Copy-Item $installer $tamperedInstaller
    $stream = [System.IO.File]::Open($tamperedInstaller, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
    try {
        $stream.Seek(-1, [System.IO.SeekOrigin]::End) | Out-Null
        $lastByte = $stream.ReadByte()
        $stream.Seek(-1, [System.IO.SeekOrigin]::End) | Out-Null
        $stream.WriteByte($lastByte -bxor 0xFF)
    }
    finally {
        $stream.Dispose()
    }
    & $winSparkle.ToolPath verify -p $ephemeralPubKey -s $signature $tamperedInstaller *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "winsparkle-tool verify unexpectedly accepted a tampered installer."
    }
    $global:LASTEXITCODE = 0

    # 4. Verify Inno Setup silent update handoff packages WinSparkle.dll and relaunches in background.
    $installArguments = @(
        "/SILENT",
        "/SP-",
        "/NOICONS",
        "/LAUNCHAFTERUPDATE=1",
        "/DIR=`"$installDirectory`""
    )
    $installProcess = Start-Process $installer -ArgumentList $installArguments -PassThru
    Wait-BoundedProcess $installProcess "silent_update_install"
    if ($installProcess.ExitCode -ne 0) {
        throw "Inno Setup silent update exited with $($installProcess.ExitCode)."
    }

    $canonicalExecutable = Join-Path $installDirectory "OPLFleetAgent.exe"
    $installedProvider = Join-Path $installDirectory "OPLFleetAgentProvider.exe"
    $installedWinSparkle = Join-Path $installDirectory "WinSparkle.dll"
    foreach ($requiredFile in @($canonicalExecutable, $installedProvider, $installedWinSparkle)) {
        if (-not (Test-Path $requiredFile)) {
            throw "Installed payload is missing required file: $requiredFile"
        }
    }
    $installedDllHash = (Get-FileHash -Algorithm SHA256 $installedWinSparkle).Hash.ToLowerInvariant()
    if ($installedDllHash -ne $winSparkle.DllSha256) {
        throw "Installed WinSparkle.dll SHA-256 mismatch."
    }

    $versionInfo = (Get-Item $canonicalExecutable).VersionInfo
    if (-not $versionInfo.ProductVersion.StartsWith($Version)) {
        throw "Expected installed version $Version, got $($versionInfo.ProductVersion)."
    }
    if ($versionInfo.ProductName -ne "OPL Fleet Agent") {
        throw "Expected product name 'OPL Fleet Agent', got '$($versionInfo.ProductName)'."
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        $launchedProcess = Get-Process -Name "OPLFleetAgent" -ErrorAction SilentlyContinue |
            Where-Object {
                try { $_.Path -eq $canonicalExecutable } catch { $false }
            } |
            Select-Object -First 1
        if (-not $launchedProcess) {
            Start-Sleep -Milliseconds 250
        }
    } while (-not $launchedProcess -and (Get-Date) -lt $deadline)
    if (-not $launchedProcess -or $launchedProcess.HasExited) {
        throw "OPL Fleet Agent did not relaunch after Inno Setup /LAUNCHAFTERUPDATE=1 update."
    }

    Write-Output "Verified WinSparkle Ed25519 appcast signing, tamper rejection, WinSparkle.dll packaging, and silent update relaunch for v$Version (PID $($launchedProcess.Id))."
}
finally {
    if ($launchedProcess -and -not $launchedProcess.HasExited) {
        Stop-Process -Id $launchedProcess.Id -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name "OPLFleetAgent" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if (Test-Path $uninstaller) {
        $uninstallProcess = Start-Process `
            $uninstaller `
            -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART") `
            -PassThru
        Wait-BoundedProcess $uninstallProcess "uninstall_verification_copy"
        if ($uninstallProcess.ExitCode -ne 0) {
            Write-Warning "Updater test uninstaller exited with $($uninstallProcess.ExitCode)."
        }
        if (Test-Path (Join-Path $installDirectory "WinSparkle.dll")) {
            throw "WinSparkle.dll remains after uninstall."
        }
    }
    if (Test-Path $testRoot) {
        Remove-Item -Recurse -Force $testRoot
    }
}
