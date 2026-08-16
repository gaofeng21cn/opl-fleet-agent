using System.Text.Json;
using System.Text.Json.Nodes;
using CodexTPS.Core;

namespace CodexTPS.Core.Tests;

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
            Environment.CurrentDirectory,
            "plugins",
            "opl-fleet-agent",
            "tests",
            "fixtures",
            "provider-telemetry.json");
        var expected = JsonNode.Parse(File.ReadAllText(fixture));

        Assert.True(JsonNode.DeepEquals(expected, actual));
    }

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
