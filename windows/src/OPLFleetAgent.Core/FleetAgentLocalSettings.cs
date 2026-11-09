using System.Text.Json;

namespace OPLFleetAgent.Core;

/// <summary>Reads the native app's non-secret collection identity without loading credentials.</summary>
public sealed record FleetAgentLocalSettings(AmbientOpsMachineIdentity Identity, string? CodexHome)
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);

    public static string DefaultSettingsPath() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OPL Fleet Agent",
        "settings.json");

    public static string DefaultMachineId(string? machineName = null)
    {
        var value = new string((machineName ?? Environment.MachineName).ToLowerInvariant()
            .Select(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-'
                ? character
                : '-')
            .Take(80)
            .ToArray());
        return string.IsNullOrWhiteSpace(value) ? "windows-pc" : value;
    }

    public static FleetAgentLocalSettings Load(
        string? settingsPath = null,
        Func<string, string?>? environment = null,
        string? machineName = null)
    {
        settingsPath ??= DefaultSettingsPath();
        environment ??= Environment.GetEnvironmentVariable;
        machineName ??= Environment.MachineName;
        var saved = File.Exists(settingsPath)
            ? JsonSerializer.Deserialize<ObservationSettings>(File.ReadAllText(settingsPath), Options)
                ?? throw new JsonException("Invalid local settings")
            : new ObservationSettings();
        var identity = new AmbientOpsMachineIdentity(
            environment("OPL_FLEET_AGENT_MACHINE_ID") ?? saved.MachineId ?? DefaultMachineId(machineName),
            environment("OPL_FLEET_AGENT_MACHINE_NAME") ?? saved.MachineName ?? machineName,
            environment("OPL_FLEET_AGENT_PLATFORM") ?? "Windows");
        var codexHome = NonEmpty(environment("CODEX_HOME")) ?? NonEmpty(saved.CodexHome);
        return new FleetAgentLocalSettings(identity, codexHome);
    }

    private static string? NonEmpty(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    // Deliberately excludes ProtectedToken and ProtectedDevicePrivateKey. The
    // native settings store remains their only decryption and mutation owner.
    private sealed class ObservationSettings
    {
        public string? MachineId { get; set; }
        public string? MachineName { get; set; }
        public string? CodexHome { get; set; }
    }
}
