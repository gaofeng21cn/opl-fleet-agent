namespace CodexTPS.Windows.Tests;

public sealed class InstallerLaunchContractTests
{
    [Fact]
    public void StandardInstallerLaunchesPostInstallInBackground()
    {
        var definition = ReadContract("CodexTPS.iss");

        Assert.Contains(
            """Filename: "{app}\OPLFleetAgent.exe"; Parameters: "--background"; Description: "{cm:LaunchProgram,OPL Fleet Agent}"; Flags: nowait postinstall skipifsilent""",
            definition);
    }

    [Fact]
    public void StandardInstallerUsesOnlyFleetInstallIdentity()
    {
        var definition = ReadContract("CodexTPS.iss");

        Assert.Contains("AppName=OPL Fleet Agent", definition);
        Assert.Contains(@"DefaultDirName={localappdata}\Programs\OPL Fleet Agent", definition);
        Assert.Contains("OutputBaseFilename=OPL-Fleet-Agent-Windows-win-x64-Setup", definition);
        Assert.Contains("CloseApplicationsFilter=OPLFleetAgent.exe", definition);
        Assert.DoesNotContain("Codex TPS", definition);
        Assert.DoesNotContain("CodexTPS.exe", definition);
        Assert.DoesNotContain("LEGACYBRIDGEPATH", definition);
    }

    [Fact]
    public void UpdaterTargetsTheCanonicalInstallDirectory()
    {
        var worker = ReadContract("WindowsUpdateWorker.cs");

        Assert.Contains(
            "startInfo.ArgumentList.Add($\"/DIR={request.InstallDirectory}\")",
            worker);
        Assert.DoesNotContain("LEGACYBRIDGEPATH", worker);
    }

    [Fact]
    public void PortableInstallerLaunchesInBackground()
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
        Assert.Contains(
            "Programs/OPL Fleet Agent",
            script);
        Assert.DoesNotContain("Programs/Codex TPS", script);
        Assert.Contains(
            "The archive must not include CodexTPS.exe.",
            script);
    }

    [Fact]
    public void NewPayloadCannotCarryLegacyExecutable()
    {
        var buildScript = ReadContract("build.ps1");
        var installerScript = ReadContract("build-installer.ps1");

        Assert.Contains("Published payload must not include CodexTPS.exe.", buildScript);
        Assert.Contains("Published payload must not include CodexTPS.exe.", installerScript);
        Assert.DoesNotContain(
            "Copy-Item (Join-Path $publishRoot \"OPLFleetAgent.exe\") (Join-Path $publishRoot \"CodexTPS.exe\")",
            buildScript);
    }

    private static string ReadContract(string name) =>
        Normalize(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "LaunchContracts", name)));

    private static string Normalize(string value) =>
        value.Replace("\r\n", "\n", StringComparison.Ordinal);
}
