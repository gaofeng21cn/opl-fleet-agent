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
    public void StandardInstallerUsesFleetBrandAndCleansLegacyShortcuts()
    {
        var definition = ReadContract("CodexTPS.iss");

        Assert.Contains("AppName=OPL Fleet Agent", definition);
        Assert.Contains(@"DefaultDirName={localappdata}\Programs\OPL Fleet Agent", definition);
        Assert.Contains(@"{autoprograms}\Codex TPS.lnk", definition);
        Assert.Contains(@"{autodesktop}\Codex TPS.lnk", definition);
        Assert.Contains("OutputBaseFilename=OPL-Fleet-Agent-Windows-win-x64-Setup", definition);
        Assert.Contains("CloseApplicationsFilter=OPLFleetAgent.exe;CodexTPS.exe", definition);
        Assert.Contains("LegacyBridgePath", definition);
        Assert.Contains("procedure InitializeWizard;", definition);
        Assert.Contains("WizardForm.DirEdit.Text", definition);
        Assert.Contains("CurrentInstallDirectory := WizardForm.DirEdit.Text", definition);
        Assert.Contains("FileExists(AddBackslash(CurrentInstallDirectory) + 'CodexTPS.exe')", definition);
        Assert.Contains("LegacyBridgePath := AddBackslash(CurrentInstallDirectory) + 'CodexTPS.exe'", definition);
        Assert.Contains("WizardForm.DirEdit.Text := ExpandConstant('{localappdata}\\Programs\\OPL Fleet Agent')", definition);
        Assert.DoesNotContain("function PrepareToInstall", definition);
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
            "Programs/Codex TPS",
            script);
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

    [Fact]
    public void LegacyBridgeUsesBoundedHandoffBeforeCleanup()
    {
        var bridge = ReadContract("LegacyExecutableBridge.cs");

        Assert.Contains("HandoffGracePeriodMilliseconds", bridge);
        Assert.Contains("Thread.Sleep(HandoffGracePeriodMilliseconds)", bridge);
        Assert.DoesNotContain("child.WaitForExit();", bridge);
    }

    private static string ReadContract(string name) =>
        Normalize(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "LaunchContracts", name)));

    private static string Normalize(string value) =>
        value.Replace("\r\n", "\n", StringComparison.Ordinal);
}
