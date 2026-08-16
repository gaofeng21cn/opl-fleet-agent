namespace OPLFleetAgent.WindowsApp;

internal static class WindowsProductIdentity
{
    public const string ProductName = "OPL Fleet Agent";
    public const string ExecutableName = "OPLFleetAgent.exe";
    public const string UpdaterExecutableName = "OPLFleetAgent.Updater.exe";
    public const string InstallDirectoryName = "OPL Fleet Agent";
    public const string InstallerAssetName = "OPL-Fleet-Agent-Windows-win-x64-Setup.exe";
    public const string ArchiveAssetName = "OPL-Fleet-Agent-Windows-win-x64.zip";

    public static string DefaultInstallDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Programs",
        InstallDirectoryName);

    public static string DefaultUpdateRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        InstallDirectoryName,
        "updates");

    public static string DefaultUpdateResultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        InstallDirectoryName,
        "update-result.json");

    public static string CanonicalExecutablePath(string installDirectory) =>
        Path.Combine(installDirectory, ExecutableName);
}
