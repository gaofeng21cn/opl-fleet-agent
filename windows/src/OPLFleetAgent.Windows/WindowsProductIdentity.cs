namespace OPLFleetAgent.WindowsApp;

internal static class WindowsProductIdentity
{
    public const string ProductName = "OPL Fleet Agent";
    public const string CompanyName = "Feng Gao";
    public const string ExecutableName = "OPLFleetAgent.exe";
    public const string WinSparkleDllName = "WinSparkle.dll";
    public const string InstallDirectoryName = "OPL Fleet Agent";
    public const string InstallerAssetName = "OPL-Fleet-Agent-Windows-win-x64-Setup.exe";
    public const string ArchiveAssetName = "OPL-Fleet-Agent-Windows-win-x64.zip";
    public const string WindowsAppcastAssetName = "windows-appcast.xml";
    public const string WindowsAppcastFeedUrl =
        "https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest/download/windows-appcast.xml";
    public const string WinSparkleEd25519PublicKey =
        "jejOvm5dBmhSxgZBYXbiz1LWqsDyb0l+pTchZIDBS48=";
    public const string WinSparkleRegistryPath = @"Software\OPL Fleet Agent\WinSparkle";
    public const int UpdateCheckIntervalSeconds = 21_600;

    public static string DefaultInstallDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Programs",
        InstallDirectoryName);

    public static string CanonicalExecutablePath(string installDirectory) =>
        Path.Combine(installDirectory, ExecutableName);
}
