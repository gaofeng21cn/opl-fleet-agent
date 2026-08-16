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
    }

    [Fact]
    public void StandardInstallerUsesOnlyFleetInstallIdentity()
    {
        var definition = ReadContract("OPLFleetAgent.iss");

        Assert.Contains("AppName=OPL Fleet Agent", definition);
        Assert.Contains(@"DefaultDirName={localappdata}\Programs\OPL Fleet Agent", definition);
        Assert.Contains("OutputBaseFilename=OPL-Fleet-Agent-Windows-win-x64-Setup", definition);
        Assert.Contains("CloseApplicationsFilter=OPLFleetAgent.exe", definition);
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
        Assert.Contains(
            "The archive contains an unexpected executable:",
            script);
    }

    [Fact]
    public void PayloadAllowsOnlyCanonicalExecutables()
    {
        var buildScript = ReadContract("build.ps1");
        var installerScript = ReadContract("build-installer.ps1");

        Assert.Contains("$allowedExecutables = @(\"OPLFleetAgent.exe\", \"OPLFleetAgentProvider.exe\")", buildScript);
        Assert.Contains("Published payload contains an unexpected executable:", buildScript);
        Assert.Contains("Published payload contains an unexpected executable:", installerScript);
    }

    private static string ReadContract(string name) =>
        Normalize(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "LaunchContracts", name)));

    private static string Normalize(string value) =>
        value.Replace("\r\n", "\n", StringComparison.Ordinal);
}
