param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [string]$OutputPath,
    [string]$Repository = "gaofeng21cn/opl-fleet-agent",
    [string]$ExpectedPublicKey = "jejOvm5dBmhSxgZBYXbiz1LWqsDyb0l+pTchZIDBS48=",
    [string]$SigningKeyPath,
    [string]$WinSparkleToolPath,
    [switch]$RequireSigningKey
)

$ErrorActionPreference = "Stop"

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version must use MAJOR.MINOR.PATCH format, got '$Version'."
}
if (-not (Test-Path $InstallerPath)) {
    throw "Installer not found: $InstallerPath"
}

$expectedKeyBytes = [Convert]::FromBase64String($ExpectedPublicKey.Trim())
if ($expectedKeyBytes.Length -ne 32) {
    throw "Expected a 32-byte base64 Ed25519 public key, got $($expectedKeyBytes.Length) bytes."
}

$resolvedInstaller = (Resolve-Path $InstallerPath).Path
$installerInfo = Get-Item $resolvedInstaller
$installerName = $installerInfo.Name
$installerLength = $installerInfo.Length
if ($installerLength -le 0) {
    throw "Installer file is empty: $resolvedInstaller"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $installerInfo.DirectoryName "windows-appcast.xml"
}

if ([string]::IsNullOrWhiteSpace($WinSparkleToolPath)) {
    $winSparkle = & (Join-Path $PSScriptRoot "fetch-winsparkle.ps1") -Runtime "win-x64" -PassThru
    $WinSparkleToolPath = $winSparkle.ToolPath
}
if (-not (Test-Path $WinSparkleToolPath)) {
    throw "winsparkle-tool.exe not found: $WinSparkleToolPath"
}

$tempKeyRoot = $null
$effectiveKeyPath = $null
try {
    if (-not [string]::IsNullOrWhiteSpace($SigningKeyPath)) {
        if (-not (Test-Path $SigningKeyPath)) {
            throw "Signing key file not found: $SigningKeyPath"
        }
        $effectiveKeyPath = (Resolve-Path $SigningKeyPath).Path
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:SPARKLE_ED25519_PRIVATE_KEY)) {
        $tempKeyRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("opl-winsparkle-key-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force $tempKeyRoot | Out-Null
        $effectiveKeyPath = Join-Path $tempKeyRoot "ed25519.key"
        [System.IO.File]::WriteAllText(
            $effectiveKeyPath,
            $env:SPARKLE_ED25519_PRIVATE_KEY.Trim(),
            (New-Object System.Text.UTF8Encoding($false)))
    }
    else {
        if ($RequireSigningKey) {
            throw "SPARKLE_ED25519_PRIVATE_KEY is required for Windows appcast generation."
        }
        throw "Provide -SigningKeyPath or set SPARKLE_ED25519_PRIVATE_KEY."
    }

    $pubKeyOutput = & $WinSparkleToolPath public-key -f $effectiveKeyPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "winsparkle-tool public-key failed (exit $LASTEXITCODE): $($pubKeyOutput -join ' ')"
    }
    $pubKeyMatch = [regex]::Match(($pubKeyOutput -join "`n"), 'Public key:\s*([A-Za-z0-9+/=]+)')
    if (-not $pubKeyMatch.Success) {
        throw "Unable to parse public key from winsparkle-tool output."
    }
    $derivedPublicKey = $pubKeyMatch.Groups[1].Value.Trim()
    if ($derivedPublicKey -ne $ExpectedPublicKey.Trim()) {
        throw "Ed25519 private key does not match the expected public key."
    }

    $signOutput = & $WinSparkleToolPath sign -f $effectiveKeyPath $resolvedInstaller 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "winsparkle-tool sign failed (exit $LASTEXITCODE): $($signOutput -join ' ')"
    }
    $signature = (($signOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1).ToString().Trim()
    $signatureBytes = [Convert]::FromBase64String($signature)
    if ($signatureBytes.Length -ne 64) {
        throw "Expected a 64-byte Ed25519 signature, got $($signatureBytes.Length) bytes."
    }

    $verifyOutput = & $WinSparkleToolPath verify -p $ExpectedPublicKey.Trim() -s $signature $resolvedInstaller 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "winsparkle-tool verify failed (exit $LASTEXITCODE): $($verifyOutput -join ' ')"
    }

    $releaseTag = "v$Version"
    $releasePageUrl = "https://github.com/$Repository/releases/tag/$releaseTag"
    $downloadUrl = "https://github.com/$Repository/releases/download/$releaseTag/$installerName"
    $installerArguments = "/SILENT /SP- /NOICONS /LAUNCHAFTERUPDATE=1"
    $pubDate = [DateTimeOffset]::UtcNow.ToString("ddd, dd MMM yyyy HH:mm:ss '+0000'", [System.Globalization.CultureInfo]::InvariantCulture)
    $descriptionHtml = "<p>OPL Fleet Agent $Version for Windows.</p><p>See the <a href=`"$releasePageUrl`">GitHub Release $releaseTag</a> for full release notes and checksums.</p>"

    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
        New-Item -ItemType Directory -Force $outputDirectory | Out-Null
    }

    $sparkleNs = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    $dcNs = "http://purl.org/dc/elements/1.1/"
    $writerSettings = New-Object System.Xml.XmlWriterSettings
    $writerSettings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writerSettings.Indent = $true
    $writerSettings.IndentChars = "  "
    $writerSettings.NewLineChars = "`n"

    $writer = [System.Xml.XmlWriter]::Create($OutputPath, $writerSettings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement("rss")
        $writer.WriteAttributeString("version", "2.0")
        $writer.WriteAttributeString("xmlns", "sparkle", $null, $sparkleNs)
        $writer.WriteAttributeString("xmlns", "dc", $null, $dcNs)

        $writer.WriteStartElement("channel")
        $writer.WriteElementString("title", "OPL Fleet Agent (Windows)")
        $writer.WriteElementString("link", $releasePageUrl)
        $writer.WriteElementString("description", "OPL Fleet Agent Windows release feed.")
        $writer.WriteElementString("language", "en")

        $writer.WriteStartElement("item")
        $writer.WriteElementString("title", "OPL Fleet Agent $Version")
        $writer.WriteElementString("link", $releasePageUrl)
        $writer.WriteElementString("pubDate", $pubDate)
        $writer.WriteElementString("version", $sparkleNs, $Version)
        $writer.WriteElementString("shortVersionString", $sparkleNs, $Version)
        $writer.WriteElementString("minimumSystemVersion", $sparkleNs, "10.0")

        $writer.WriteStartElement("description")
        $writer.WriteCData($descriptionHtml)
        $writer.WriteEndElement()

        $writer.WriteStartElement("enclosure")
        $writer.WriteAttributeString("url", $downloadUrl)
        $writer.WriteAttributeString("os", $sparkleNs, "windows-x64")
        $writer.WriteAttributeString("version", $sparkleNs, $Version)
        $writer.WriteAttributeString("shortVersionString", $sparkleNs, $Version)
        $writer.WriteAttributeString("edSignature", $sparkleNs, $signature)
        $writer.WriteAttributeString("installerArguments", $sparkleNs, $installerArguments)
        $writer.WriteAttributeString("length", $installerLength.ToString([System.Globalization.CultureInfo]::InvariantCulture))
        $writer.WriteAttributeString("type", "application/octet-stream")
        $writer.WriteEndElement()

        $writer.WriteEndElement() # item
        $writer.WriteEndElement() # channel
        $writer.WriteEndElement() # rss
        $writer.WriteEndDocument()
    }
    finally {
        $writer.Dispose()
    }

    # Read back and verify the generated appcast XML and its embedded signature.
    [xml]$parsed = Get-Content -Raw -Encoding utf8 $OutputPath
    $nsManager = New-Object System.Xml.XmlNamespaceManager($parsed.NameTable)
    $nsManager.AddNamespace("sparkle", $sparkleNs)
    $items = $parsed.SelectNodes("/rss/channel/item")
    if ($items.Count -ne 1) {
        throw "Expected 1 item in generated Windows appcast, found $($items.Count)."
    }
    $item = $items[0]
    $enclosure = $item.SelectSingleNode("enclosure")
    if ($null -eq $enclosure) {
        throw "Generated Windows appcast is missing an enclosure element."
    }
    if ($item.SelectSingleNode("sparkle:version", $nsManager).InnerText -ne $Version) {
        throw "Generated Windows appcast sparkle:version mismatch."
    }
    if ($item.SelectSingleNode("sparkle:shortVersionString", $nsManager).InnerText -ne $Version) {
        throw "Generated Windows appcast sparkle:shortVersionString mismatch."
    }
    if ($enclosure.GetAttribute("url") -ne $downloadUrl) {
        throw "Generated Windows appcast enclosure URL mismatch."
    }
    if ($enclosure.GetAttribute("length") -ne $installerLength.ToString([System.Globalization.CultureInfo]::InvariantCulture)) {
        throw "Generated Windows appcast enclosure length mismatch."
    }
    if ($enclosure.GetAttribute("os", $sparkleNs) -ne "windows-x64") {
        throw "Generated Windows appcast sparkle:os mismatch."
    }
    if ($enclosure.GetAttribute("installerArguments", $sparkleNs) -ne $installerArguments) {
        throw "Generated Windows appcast sparkle:installerArguments mismatch."
    }
    $parsedSignature = $enclosure.GetAttribute("edSignature", $sparkleNs)
    $reverifyOutput = & $WinSparkleToolPath verify -p $ExpectedPublicKey.Trim() -s $parsedSignature $resolvedInstaller 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Re-verification of generated Windows appcast signature failed: $($reverifyOutput -join ' ')"
    }

    Write-Output (Resolve-Path $OutputPath).Path
}
finally {
    if ($tempKeyRoot -and (Test-Path $tempKeyRoot)) {
        Remove-Item -Recurse -Force $tempKeyRoot
    }
}
