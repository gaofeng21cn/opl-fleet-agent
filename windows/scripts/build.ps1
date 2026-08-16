param(
    [ValidateSet("win-x64")]
    [string]$Runtime = "win-x64",
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Release",
    [string]$Version = "0.2.40",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$windowsRoot = Split-Path -Parent $PSScriptRoot
$repositoryRoot = Split-Path -Parent $windowsRoot
$solution = Join-Path $windowsRoot "OPLFleetAgent.Windows.sln"
$appProject = Join-Path $windowsRoot "src/OPLFleetAgent.Windows/OPLFleetAgent.Windows.csproj"
$providerProject = Join-Path $windowsRoot "src/OPLFleetAgent.Provider/OPLFleetAgent.Provider.csproj"
$coreTestProject = Join-Path $windowsRoot "tests/OPLFleetAgent.Core.Tests/OPLFleetAgent.Core.Tests.csproj"
$windowsTestProject = Join-Path $windowsRoot "tests/OPLFleetAgent.Windows.Tests/OPLFleetAgent.Windows.Tests.csproj"
$distRoot = Join-Path $windowsRoot "dist"
$publishRoot = Join-Path $distRoot $Runtime
$archive = Join-Path $distRoot "OPL-Fleet-Agent-Windows-$Runtime.zip"
$checksum = "$archive.sha256"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must use MAJOR.MINOR.PATCH format."
}

dotnet restore $solution --locked-mode --nologo
if ($LASTEXITCODE -ne 0) { throw "Locked dependency restore failed." }
dotnet restore $appProject -r $Runtime --locked-mode --nologo
if ($LASTEXITCODE -ne 0) { throw "Locked Windows runtime restore failed." }
dotnet restore $providerProject -r $Runtime --locked-mode --nologo
if ($LASTEXITCODE -ne 0) { throw "Locked Windows provider restore failed." }

if (-not $SkipTests) {
    dotnet test $coreTestProject -c $Configuration --no-restore --nologo
    if ($LASTEXITCODE -ne 0) { throw "Windows Core tests failed." }
    dotnet test $windowsTestProject -c $Configuration --no-restore --nologo
    if ($LASTEXITCODE -ne 0) { throw "Windows UI tests failed." }
}

if (Test-Path $publishRoot) {
    Remove-Item -Recurse -Force $publishRoot
}
New-Item -ItemType Directory -Force $publishRoot | Out-Null

dotnet publish $appProject `
    -c $Configuration `
    -r $Runtime `
    --self-contained true `
    --no-restore `
    --nologo `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -p:Version=$Version `
    -p:FileVersion="$Version.0" `
    -p:AssemblyVersion="$Version.0" `
    -o $publishRoot
if ($LASTEXITCODE -ne 0) { throw "Windows publish failed." }

dotnet publish $providerProject `
    -c $Configuration `
    -r $Runtime `
    --self-contained true `
    --no-restore `
    --nologo `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -p:Version=$Version `
    -p:FileVersion="$Version.0" `
    -p:AssemblyVersion="$Version.0" `
    -o $publishRoot
if ($LASTEXITCODE -ne 0) { throw "Windows provider publish failed." }

if (-not (Test-Path (Join-Path $publishRoot "OPLFleetAgent.exe"))) {
    throw "Published OPLFleetAgent.exe is missing."
}
if (-not (Test-Path (Join-Path $publishRoot "OPLFleetAgentProvider.exe"))) {
    throw "Published OPLFleetAgentProvider.exe is missing."
}
$allowedExecutables = @("OPLFleetAgent.exe", "OPLFleetAgentProvider.exe")
$unexpectedExecutables = Get-ChildItem $publishRoot -File -Filter "*.exe" |
    Where-Object { $_.Name -notin $allowedExecutables }
if ($unexpectedExecutables) {
    throw "Published payload contains an unexpected executable: $($unexpectedExecutables.Name -join ', ')."
}
Copy-Item (Join-Path $repositoryRoot "LICENSE") (Join-Path $publishRoot "LICENSE.txt")
Copy-Item (Join-Path $windowsRoot "THIRD-PARTY-NOTICES.md") $publishRoot
Copy-Item (Join-Path $windowsRoot "src/OPLFleetAgent.Windows/app.ico") $publishRoot
if (Test-Path $archive) { Remove-Item -Force $archive }
if (Test-Path $checksum) { Remove-Item -Force $checksum }
Compress-Archive -Path (Join-Path $publishRoot "*") -DestinationPath $archive -CompressionLevel Optimal

$hash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
$line = "$hash  $(Split-Path -Leaf $archive)"
[System.IO.File]::WriteAllText($checksum, "$line`n", [System.Text.Encoding]::ASCII)
Write-Output $archive
Write-Output $line
