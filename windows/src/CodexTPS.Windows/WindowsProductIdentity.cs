namespace CodexTPS.WindowsApp;

internal static class WindowsProductIdentity
{
    public const string ProductName = "OPL Fleet Agent";
    public const string ExecutableName = "OPLFleetAgent.exe";
    public const string LegacyExecutableName = "CodexTPS.exe";
    public const string UpdaterExecutableName = "OPLFleetAgent.Updater.exe";
    public const string LegacyUpdaterExecutableName = "CodexTPS.Updater.exe";
    public const string InstallDirectoryName = "OPL Fleet Agent";
    public const string LegacyInstallDirectoryName = "Codex TPS";
    public const string InstallerAssetName = "OPL-Fleet-Agent-Windows-win-x64-Setup.exe";
    public const string LegacyInstallerAssetName = "Codex-TPS-Windows-win-x64-Setup.exe";
    public const string ArchiveAssetName = "OPL-Fleet-Agent-Windows-win-x64.zip";
    public const string LegacyArchiveAssetName = "Codex-TPS-Windows-win-x64.zip";

    public static string DefaultInstallDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Programs",
        InstallDirectoryName);

    public static string LegacyInstallDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Programs",
        LegacyInstallDirectoryName);

    public static string DefaultUpdateRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        InstallDirectoryName,
        "updates");

    public static string DefaultUpdateResultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        InstallDirectoryName,
        "update-result.json");

    public static string LegacyUpdateResultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        LegacyInstallDirectoryName,
        "update-result.json");

    public static bool IsLegacyExecutable(string path) =>
        string.Equals(
            Path.GetFileName(path),
            LegacyExecutableName,
            StringComparison.OrdinalIgnoreCase);

    public static string CanonicalExecutablePath(string installDirectory) =>
        Path.Combine(installDirectory, ExecutableName);

    public static string LegacyExecutablePath(string installDirectory) =>
        Path.Combine(installDirectory, LegacyExecutableName);

    public static string? FindCanonicalExecutable(string legacyExecutablePath)
    {
        var installDirectory = Path.GetDirectoryName(legacyExecutablePath);
        var installParent = installDirectory is null
            ? null
            : Path.GetDirectoryName(installDirectory);
        var candidates = new[]
        {
            installDirectory is null ? null : CanonicalExecutablePath(installDirectory),
            installParent is null
                ? null
                : CanonicalExecutablePath(Path.Combine(installParent, InstallDirectoryName)),
            CanonicalExecutablePath(DefaultInstallDirectory),
        };

        return candidates
            .Where(path => path is not null && File.Exists(path))
            .Cast<string>()
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault();
    }
}
