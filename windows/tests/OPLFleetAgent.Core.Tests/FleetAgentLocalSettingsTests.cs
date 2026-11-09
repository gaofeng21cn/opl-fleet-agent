using System.Text.Json;
using OPLFleetAgent.Core;

namespace OPLFleetAgent.Core.Tests;

public sealed class FleetAgentLocalSettingsTests : IDisposable
{
    private readonly string directory = Path.Combine(
        Path.GetTempPath(), $"opl-fleet-local-settings-{Guid.NewGuid():N}");

    public FleetAgentLocalSettingsTests() => Directory.CreateDirectory(directory);

    [Fact]
    public void ProviderUsesSavedNativeIdentityAndCollectionSourceWithoutCredentials()
    {
        var codexHome = Path.Combine(directory, "chosen-codex");
        Directory.CreateDirectory(Path.Combine(codexHome, "sessions"));
        var settingsPath = Path.Combine(directory, "settings.json");
        var bytes = JsonSerializer.Serialize(new
        {
            machineId = "native-node",
            machineName = "Saved Native Node",
            codexHome,
            // Reading identity must not try to decrypt either field.
            protectedToken = "not-dpapi-data",
            protectedDevicePrivateKey = "not-a-key",
        });
        File.WriteAllText(settingsPath, bytes);

        var settings = FleetAgentLocalSettings.Load(settingsPath, _ => null, "different-hostname");
        var usage = new SessionScanner(settings.CodexHome).Refresh();
        var projection = OplFleetAgentProvider.Telemetry(usage, settings.Identity);

        Assert.Equal("native-node", projection.Node?.StableNodeId);
        Assert.Equal("Saved Native Node", projection.Node?.DisplayName);
        Assert.Equal("fresh", projection.Freshness.State);
        Assert.Equal(CollectionStatus.Ready, usage.Status);
        Assert.Equal(bytes, File.ReadAllText(settingsPath));
        var output = JsonSerializer.Serialize(projection, OplFleetAgentProvider.SerializerOptions);
        Assert.DoesNotContain("not-dpapi-data", output);
        Assert.DoesNotContain("not-a-key", output);
        Assert.DoesNotContain(codexHome, output);
    }

    [Fact]
    public void ExplicitProcessConfigurationOverridesSavedObservationFields()
    {
        var settingsPath = Path.Combine(directory, "settings.json");
        File.WriteAllText(settingsPath,
            """{"machineId":"saved-node","machineName":"Saved","codexHome":"saved-source"}""");
        var environment = new Dictionary<string, string>
        {
            ["OPL_FLEET_AGENT_MACHINE_ID"] = "explicit-node",
            ["OPL_FLEET_AGENT_MACHINE_NAME"] = "Explicit",
            ["OPL_FLEET_AGENT_PLATFORM"] = "Windows-Test",
            ["CODEX_HOME"] = "explicit-source",
        };
        var settings = FleetAgentLocalSettings.Load(
            settingsPath, key => environment.GetValueOrDefault(key), "fallback");

        Assert.Equal("explicit-node", settings.Identity.MachineId);
        Assert.Equal("Explicit", settings.Identity.MachineName);
        Assert.Equal("Windows-Test", settings.Identity.Platform);
        Assert.Equal("explicit-source", settings.CodexHome);
    }

    [Fact]
    public void MissingSettingsUsesNativeDefaultsWithoutCreatingASettingsFile()
    {
        var settingsPath = Path.Combine(directory, "missing.json");
        var settings = FleetAgentLocalSettings.Load(settingsPath, _ => null, "My PC");

        Assert.Equal(FleetAgentLocalSettings.DefaultMachineId("My PC"), settings.Identity.MachineId);
        Assert.Equal("my-pc", settings.Identity.MachineId);
        Assert.Equal("My PC", settings.Identity.MachineName);
        Assert.Null(settings.CodexHome);
        Assert.False(File.Exists(settingsPath));
    }

    [Fact]
    public void InvalidSavedIdentityDoesNotBecomeAHostDerivedNode()
    {
        var settingsPath = Path.Combine(directory, "settings.json");
        File.WriteAllText(settingsPath, """{"machineId":"invalid node"}""");

        Assert.Throws<ArgumentException>(() =>
            FleetAgentLocalSettings.Load(settingsPath, _ => null, "fallback"));
    }

    [Fact]
    public void InvalidSavedDocumentDoesNotBecomeAHostDerivedNode()
    {
        var settingsPath = Path.Combine(directory, "settings.json");
        File.WriteAllText(settingsPath, "not-json");

        Assert.Throws<JsonException>(() =>
            FleetAgentLocalSettings.Load(settingsPath, _ => null, "fallback"));
    }

    public void Dispose() => Directory.Delete(directory, recursive: true);
}
