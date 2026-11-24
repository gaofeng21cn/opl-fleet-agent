using System.Xml.Linq;
using OPLFleetAgent.WindowsApp;

namespace OPLFleetAgent.Windows.Tests;

public sealed class InstallerLaunchContractTests
{
    [Fact]
    public void StandardInstallerLaunchesPostInstallInBackground()
    {
        var definition = ReadContract("OPLFleetAgent.iss");

        Assert.Contains(
            """Filename: "{app}\OPLFleetAgent.exe"; Parameters: "--background"; Description: "{cm:LaunchProgram,OPL Fleet Agent}"; Flags: nowait postinstall skipifsilent""",
            definition);
        Assert.Contains(
            """Filename: "{app}\OPLFleetAgent.exe"; Parameters: "--background"; Flags: nowait skipifnotsilent; Check: LaunchAfterSilentUpdate""",
            definition);
        Assert.Contains("ExpandConstant('{param:LAUNCHAFTERUPDATE|0}') = '1'", definition);
    }

    [Fact]
    public void StandardInstallerUsesOnlyFleetInstallIdentityAndPackagesWinSparkle()
    {
        var definition = ReadContract("OPLFleetAgent.iss");

        Assert.Contains("AppName=OPL Fleet Agent", definition);
        Assert.Contains(@"DefaultDirName={localappdata}\Programs\OPL Fleet Agent", definition);
        Assert.Contains("OutputBaseFilename=OPL-Fleet-Agent-Windows-win-x64-Setup", definition);
        Assert.Contains("CloseApplicationsFilter=OPLFleetAgent.exe", definition);
        Assert.Contains("WinSparkle.dll", definition);
        Assert.Contains("""Source: "{#SourceDir}\WinSparkle.dll"; DestDir: "{app}"; Flags: ignoreversion""", definition);
        Assert.DoesNotContain("LEGACYBRIDGEPATH", definition);
    }

    [Fact]
    public void WinSparklePublicKeyMatchesMacOsSparklePublicKey()
    {
        var plist = XDocument.Parse(ReadContract("Info.plist"));
        var keys = plist.Descendants("key").ToList();
        var publicKeyNode = keys.FirstOrDefault(node => node.Value == "SUPublicEDKey")
            ?.ElementsAfterSelf("string")
            .FirstOrDefault();

        Assert.NotNull(publicKeyNode);
        var macOsPublicKey = publicKeyNode!.Value.Trim();
        Assert.Equal(WindowsProductIdentity.WinSparkleEd25519PublicKey, macOsPublicKey);
        Assert.Equal(32, Convert.FromBase64String(WindowsProductIdentity.WinSparkleEd25519PublicKey).Length);
    }

    [Fact]
    public void WinSparkleScriptsPinChecksumsAndSignWindowsAppcast()
    {
        var fetchScript = ReadContract("fetch-winsparkle.ps1");
        var appcastScript = ReadContract("generate-windows-appcast.ps1");

        Assert.Contains("$winSparkleVersion = \"0.9.4\"", fetchScript);
        Assert.Contains("6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976", fetchScript);
        Assert.Contains("9b43b1c16ee39fb9a91b5bd75138767898779510e0836be2919250607cdbe8ab", fetchScript);
        Assert.Contains("0c5412c481be6146313a2af46cce4a928913c94754763a75bb11ef15c9097cc3", fetchScript);

        Assert.Contains(WindowsProductIdentity.WinSparkleEd25519PublicKey, appcastScript);
        Assert.Contains("windows-x64", appcastScript);
        Assert.Contains("/SILENT /SP- /NOICONS /LAUNCHAFTERUPDATE=1", appcastScript);
        Assert.Contains("edSignature", appcastScript);
        Assert.Contains("verify -p", appcastScript);
    }

    [Fact]
    public void PortableInstallerLaunchesInBackgroundAndRequiresWinSparkle()
    {
        var script = ReadContract("install.ps1");

        Assert.Contains(
            Normalize(
                """
                Start-Process `
                            (Join-Path $InstallDirectory "OPLFleetAgent.exe") `
                            -ArgumentList "--background"
                """),
            script);
        Assert.Contains("Programs/OPL Fleet Agent", script);
        Assert.Contains("The archive contains an unexpected executable:", script);
        Assert.Contains("WinSparkle.dll is missing from the archive.", script);
    }

    [Fact]
    public void PayloadAllowsOnlyCanonicalExecutablesAndRequiresWinSparkle()
    {
        var buildScript = ReadContract("build.ps1");
        var installerScript = ReadContract("build-installer.ps1");

        Assert.Contains("$allowedExecutables = @(\"OPLFleetAgent.exe\", \"OPLFleetAgentProvider.exe\")", buildScript);
        Assert.Contains("Published payload contains an unexpected executable:", buildScript);
        Assert.Contains("Published payload contains an unexpected executable:", installerScript);
        Assert.Contains("fetch-winsparkle.ps1", buildScript);
        Assert.Contains("WinSparkle.dll", buildScript);
        Assert.Contains("Published WinSparkle.dll is missing.", installerScript);
    }

    private static string ReadContract(string name) =>
        Normalize(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "LaunchContracts", name)));

    private static string Normalize(string value) =>
        value.Replace("\r\n", "\n", StringComparison.Ordinal);
}
