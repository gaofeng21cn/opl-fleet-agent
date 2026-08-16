using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using OPLFleetAgent.Core;

namespace OPLFleetAgent.Core.Tests;

public sealed class FleetAgentProviderTests
{
    private static readonly DateTimeOffset ObservedAt =
        DateTimeOffset.FromUnixTimeSeconds(1_755_331_200);

    [Fact]
    public void AdvertisesOnlyImplementedNativeCapabilities()
    {
        Assert.Equal(
            [
                "node_local_observation",
                "node_local_doctor",
                "local_codex_telemetry",
                "host_dashboard",
            ],
            OplFleetAgentProtocol.Capabilities);
    }

    [Fact]
    public void CollectionFallbackIsExplicitlyStale()
    {
        var failedAt = ObservedAt.AddMinutes(5);
        var projection = OplFleetAgentProvider.Telemetry(
            UsageSnapshot.Empty(failedAt, CollectionStatus.ReadFailed),
            Identity(),
            fallback: Usage(),
            now: failedAt);

        Assert.Equal("2025-08-16T08:05:00.000Z", projection.ObservedAt);
        Assert.Equal("stale", projection.Freshness.State);
        Assert.Equal("2025-08-16T08:00:00.000Z", projection.Freshness.LastObservedAt);
        Assert.True(projection.Freshness.LastKnown);
        Assert.Equal("usage_collection_failed", projection.Freshness.ReasonCode);
        Assert.Equal("degraded", projection.Payload.CollectionStatus);
        Assert.Equal(10, projection.Payload.Windows.OneMinute.TokenRatePerSecond);
        Assert.Equal(3, projection.Payload.ActiveConversationCount);
    }

    [Fact]
    public void DoctorReportsBoundedChecksAndDeferredSurfaces()
    {
        var doctor = OplFleetAgentProvider.Doctor(
            Usage(),
            Identity(),
            now: ObservedAt.AddSeconds(30));

        Assert.Equal("healthy", doctor.Payload.DoctorState);
        Assert.Equal("current", doctor.Payload.CapabilityCurrentness);
        Assert.Equal(
            [
                "provider_executable",
                "usage_collection",
                "sample_freshness",
                "execution_constraints",
                "sanitized_execution_receipts",
            ],
            doctor.Payload.Checks.Select(item => item.CheckId));
        Assert.Equal("unavailable", doctor.Payload.Checks[3].State);
        Assert.Equal("not_projected", doctor.Payload.Checks[3].ReasonCode);
        Assert.Equal("unavailable", doctor.Payload.Checks[4].State);
        Assert.Equal("deferred_no_source", doctor.Payload.Checks[4].ReasonCode);
    }

    [Fact]
    public void CSharpProjectionMatchesSharedProviderFixture()
    {
        var projection = OplFleetAgentProvider.Telemetry(
            Usage(),
            Identity(),
            cpuPercent: 42.5,
            network: new HostNetworkTelemetry(123.5, 12.25, ObservedAt),
            now: ObservedAt.AddSeconds(30));
        var actual = JsonSerializer.SerializeToNode(
            projection,
            OplFleetAgentProvider.SerializerOptions);
        var fixture = Path.Combine(
            RepositoryRoot(),
            "plugins",
            "opl-fleet-agent",
            "tests",
            "fixtures",
            "provider-telemetry.json");
        var expected = JsonNode.Parse(File.ReadAllText(fixture));

        Assert.True(JsonNode.DeepEquals(expected, actual));
    }

    [Fact]
    public void SanitizedLastKnownStoreFeedsAStaleFollowUpProjection()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            $"opl-fleet-last-known-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            var cachePath = Path.Combine(directory, "provider-last-known.json");
            var store = new FleetAgentLastKnownStore(cachePath);
            var fresh = OplFleetAgentProvider.Telemetry(
                Usage(),
                Identity(),
                now: ObservedAt.AddSeconds(30));

            store.Save(fresh);
            var loaded = store.Load(ObservedAt.AddMinutes(1));
            Assert.Equal(FleetAgentLastKnownLoadState.Available, loaded.State);
            var sample = Assert.IsType<FleetAgentLastKnownSample>(loaded.Sample);
            var stale = OplFleetAgentProvider.Telemetry(
                UsageSnapshot.Empty(ObservedAt.AddMinutes(1), CollectionStatus.ReadFailed),
                Identity(),
                fallback: sample.UsageSnapshot(),
                fallbackLastObservedAt: sample.LastObservedAt,
                now: ObservedAt.AddMinutes(1));

            Assert.Equal("stale", stale.Freshness.State);
            Assert.True(stale.Freshness.LastKnown);
            Assert.Equal(fresh.Freshness.LastObservedAt, stale.Freshness.LastObservedAt);
            Assert.Equal(
                fresh.Payload.Windows.OneMinute.TokenRatePerSecond,
                stale.Payload.Windows.OneMinute.TokenRatePerSecond);

            var root = JsonNode.Parse(File.ReadAllText(cachePath))?.AsObject();
            Assert.NotNull(root);
            Assert.Equal(
                ["last_observed_at", "payload"],
                root.Select(item => item.Key).OrderBy(item => item, StringComparer.Ordinal));

            Assert.Equal(
                FleetAgentLastKnownLoadState.Expired,
                store.Load(ObservedAt.Add(FleetAgentLastKnownStore.TimeToLive).AddSeconds(1)).State);
            File.WriteAllText(cachePath, "{}");
            Assert.Equal(FleetAgentLastKnownLoadState.Invalid, store.Load(ObservedAt).State);
            File.WriteAllText(
                cachePath,
                """{"last_observed_at":"2025-08-16T08:00:00.000Z","prompt":"secret"}""");
            Assert.Equal(
                FleetAgentLastKnownLoadState.PrivacyRejected,
                store.Load(ObservedAt).State);
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    [Fact]
    public void DoctorRefreshesLastKnownBeforeIndependentProcessFailure()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            $"opl-fleet-provider-doctor-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            var codexHome = Path.Combine(directory, "codex");
            var sessions = Path.Combine(codexHome, "sessions");
            Directory.CreateDirectory(sessions);
            var now = DateTimeOffset.UtcNow;
            var timestamp = now.AddSeconds(-5).ToString("O", CultureInfo.InvariantCulture);
            var log = string.Join(
                '\n',
                JsonSerializer.Serialize(new
                {
                    timestamp,
                    type = "session_meta",
                    payload = new { id = "session-doctor", model_provider = "test-provider" },
                }),
                JsonSerializer.Serialize(new
                {
                    timestamp,
                    type = "turn_context",
                    payload = new { model = "gpt-test" },
                }),
                JsonSerializer.Serialize(new
                {
                    timestamp,
                    type = "event_msg",
                    payload = new
                    {
                        type = "token_count",
                        info = new
                        {
                            total_token_usage = new
                            {
                                input_tokens = 200,
                                output_tokens = 40,
                                total_tokens = 240,
                            },
                            last_token_usage = new
                            {
                                input_tokens = 200,
                                output_tokens = 40,
                                total_tokens = 240,
                            },
                        },
                    },
                })
            ) + '\n';
            var logPath = Path.Combine(sessions, "rollout-session-doctor.jsonl");
            File.WriteAllText(logPath, log);
            File.SetLastWriteTimeUtc(logPath, now.UtcDateTime);

            var cachePath = Path.Combine(directory, "provider-last-known.json");
            var environment = new Dictionary<string, string>
            {
                ["OPL_FLEET_AGENT_PROVIDER_CACHE"] = cachePath,
                ["OPL_FLEET_AGENT_MACHINE_ID"] = "doctor-process-fixture",
                ["OPL_FLEET_AGENT_MACHINE_NAME"] = "Doctor Process Fixture",
                ["OPL_FLEET_AGENT_PLATFORM"] = "Windows",
            };

            _ = RunProvider(OplFleetAgentProvider.DoctorRef, codexHome, environment);
            RebaseCache(cachePath, DateTimeOffset.UtcNow.AddMinutes(-14));

            _ = RunProvider(OplFleetAgentProvider.DoctorRef, codexHome, environment);
            var refreshedAt = CacheObservedAt(cachePath);
            Assert.True((refreshedAt - DateTimeOffset.UtcNow).Duration() < TimeSpan.FromSeconds(5));

            // Advancing the simulated clock by two minutes makes an unrefreshed t0 sample expire.
            var failureObservedAt = refreshedAt.AddMinutes(-2);
            RebaseCache(cachePath, failureObservedAt);
            var failure = RunProvider(
                OplFleetAgentProvider.TelemetryRef,
                Path.Combine(directory, "missing-codex-home"),
                environment);

            var freshness = Assert.IsType<JsonObject>(failure["freshness"]);
            Assert.Equal("stale", freshness["state"]?.GetValue<string>());
            Assert.True(freshness["last_known"]?.GetValue<bool>() ?? false);
            Assert.Equal(
                Timestamp(failureObservedAt),
                freshness["last_observed_at"]?.GetValue<string>());
            var payload = Assert.IsType<JsonObject>(failure["payload"]);
            var windows = Assert.IsType<JsonObject>(payload["windows"]);
            var oneMinute = Assert.IsType<JsonObject>(windows["one_minute"]);
            Assert.Equal(4d, oneMinute["token_rate_per_second"]?.GetValue<double>());
        }
        finally
        {
            Directory.Delete(directory, true);
        }
    }

    private static JsonObject RunProvider(
        string readRef,
        string codexHome,
        IReadOnlyDictionary<string, string> environment)
    {
        var providerAssembly = Path.Combine(
            RepositoryRoot(),
            "windows",
            "src",
            "OPLFleetAgent.Provider",
            "bin",
            Configuration(),
            "net8.0",
            "OPLFleetAgentProvider.dll");
        Assert.True(File.Exists(providerAssembly), $"Missing provider assembly: {providerAssembly}");
        var startInfo = new ProcessStartInfo("dotnet")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        startInfo.ArgumentList.Add(providerAssembly);
        startInfo.ArgumentList.Add("--ref");
        startInfo.ArgumentList.Add(readRef);
        startInfo.Environment["CODEX_HOME"] = codexHome;
        foreach (var item in environment)
        {
            startInfo.Environment[item.Key] = item.Value;
        }
        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Failed to start Fleet Agent provider process.");
        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        Assert.True(process.ExitCode == 0, error);
        return Assert.IsType<JsonObject>(JsonNode.Parse(output));
    }

    private static string Configuration()
    {
        var segments = AppContext.BaseDirectory.Split(
            [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar],
            StringSplitOptions.RemoveEmptyEntries);
        return segments.LastOrDefault(item => item is "Debug" or "Release") ?? "Debug";
    }

    private static string RepositoryRoot([CallerFilePath] string sourcePath = "") =>
        Path.GetFullPath(Path.Combine(
            Path.GetDirectoryName(sourcePath)
                ?? throw new InvalidOperationException("Test source path has no parent directory."),
            "..",
            "..",
            ".."));

    private static DateTimeOffset CacheObservedAt(string cachePath)
    {
        var root = Assert.IsType<JsonObject>(JsonNode.Parse(File.ReadAllText(cachePath)));
        var value = root["last_observed_at"]?.GetValue<string>()
            ?? throw new InvalidOperationException("Provider cache is missing last_observed_at.");
        return DateTimeOffset.ParseExact(
            value,
            "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
    }

    private static void RebaseCache(string cachePath, DateTimeOffset observedAt)
    {
        var root = Assert.IsType<JsonObject>(JsonNode.Parse(File.ReadAllText(cachePath)));
        root["last_observed_at"] = Timestamp(observedAt);
        File.WriteAllText(cachePath, root.ToJsonString(OplFleetAgentProvider.SerializerOptions));
    }

    private static string Timestamp(DateTimeOffset value) =>
        value.UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
            CultureInfo.InvariantCulture);

    private static AmbientOpsMachineIdentity Identity() =>
        new("fixture-node", "Fixture Node", "macOS");

    private static UsageSnapshot Usage() =>
        new(
            ObservedAt,
            new WindowMetrics(60, 2, 2, 10, 8, 5, 2, 1, 0.625, 600),
            new WindowMetrics(300, 5, 1, 4, 3, 2, 1, 0.5, 0.5, 1_200),
            WindowMetrics.Empty(1_800),
            WindowMetrics.Empty(3_600),
            3,
            0,
            CollectionStatus.Ready);
}
