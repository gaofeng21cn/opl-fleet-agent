using OPLFleetAgent.Core;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OPLFleetAgent.WindowsApp;

internal sealed class AppSettings
{
    public int SchemaVersion { get; set; } = 2;
    public bool AmbientEnabled { get; set; } = true;
    public bool AutoDiscover { get; set; } = true;
    public string CodexHome { get; set; } = string.Empty;
    public string ManualUrl { get; set; } = string.Empty;
    public string PreferredInstanceId { get; set; } = string.Empty;
    public string MachineId { get; set; } = DefaultMachineId();
    public string MachineName { get; set; } = Environment.MachineName;
    public bool PetEnabled { get; set; } = true;
    public bool StartWithWindows { get; set; }
    public int RefreshSeconds { get; set; } = 5;
    public string ProtectedToken { get; set; } = string.Empty;
    public string ProtectedDevicePrivateKey { get; set; } = string.Empty;

    [JsonIgnore]
    public string Token { get; set; } = string.Empty;

    [JsonIgnore]
    public string DevicePrivateKey { get; set; } = string.Empty;

    private static string DefaultMachineId()
    {
        var value = new string(Environment.MachineName.ToLowerInvariant()
            .Select(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-'
                ? character
                : '-')
            .Take(80)
            .ToArray());
        return string.IsNullOrWhiteSpace(value) ? "windows-pc" : value;
    }
}

internal sealed class AppSettingsStore
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };

    public AppSettingsStore()
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            WindowsProductIdentity.InstallDirectoryName);
        SettingsPath = Path.Combine(root, "settings.json");
    }

    public string SettingsPath { get; }
    public string? LastError { get; private set; }

    public AppSettings Load()
    {
        LastError = null;
        if (!File.Exists(SettingsPath))
        {
            return new AppSettings();
        }
        try
        {
            var settings = JsonSerializer.Deserialize<AppSettings>(
                File.ReadAllText(SettingsPath),
                Options) ?? new AppSettings();
            var needsMigration = settings.SchemaVersion < 2;
            settings.SchemaVersion = 2;
            if (settings.RefreshSeconds is not (5 or 15 or 30 or 60))
            {
                settings.RefreshSeconds = 5;
            }
            settings.Token = Unprotect(settings.ProtectedToken);
            settings.DevicePrivateKey = Unprotect(settings.ProtectedDevicePrivateKey);
            if (needsMigration)
            {
                Save(settings);
            }
            return settings;
        }
        catch (Exception error) when (
            error is IOException or JsonException or CryptographicException or FormatException)
        {
            LastError = $"Settings could not be read: {error.Message}";
            return new AppSettings();
        }
    }

    public void Save(AppSettings settings)
    {
        LastError = null;
        settings.ProtectedToken = Protect(settings.Token);
        settings.ProtectedDevicePrivateKey = Protect(settings.DevicePrivateKey);
        var directory = Path.GetDirectoryName(SettingsPath)!;
        Directory.CreateDirectory(directory);
        var temporaryPath = SettingsPath + ".tmp";
        File.WriteAllText(temporaryPath, JsonSerializer.Serialize(settings, Options));
        File.Move(temporaryPath, SettingsPath, overwrite: true);
    }

    public bool EnsureDeviceKey(AppSettings settings)
    {
        if (!string.IsNullOrWhiteSpace(settings.DevicePrivateKey))
        {
            return false;
        }
        using var key = AmbientOpsDeviceKey.Create();
        settings.DevicePrivateKey = key.ExportPrivateKey();
        return true;
    }

    private static string Protect(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }
        var encrypted = ProtectedData.Protect(
            Encoding.UTF8.GetBytes(value),
            optionalEntropy: null,
            DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(encrypted);
    }

    private static string Unprotect(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }
        var decrypted = ProtectedData.Unprotect(
            Convert.FromBase64String(value),
            optionalEntropy: null,
            DataProtectionScope.CurrentUser);
        return Encoding.UTF8.GetString(decrypted);
    }
}
