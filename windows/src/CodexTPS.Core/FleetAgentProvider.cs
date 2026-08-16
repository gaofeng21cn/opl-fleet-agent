using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace CodexTPS.Core;

public sealed record FleetAgentCapabilityAbi(string Id, string Version);

public sealed record FleetAgentNativeCarrier(string Kind, string Availability, string Status);

public sealed record FleetAgentFreshness(
    string State,
    string? LastObservedAt,
    bool LastKnown,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ReasonCode);

public sealed record FleetAgentNodeIdentity(
    string StableNodeId,
    string DisplayName,
    string Platform,
    string AgentVersion);

public sealed record FleetAgentRateWindow(
    int WindowSeconds,
    double? TokenRatePerSecond,
    double? RequestRatePerMinute);

public sealed record FleetAgentRateWindows(
    FleetAgentRateWindow OneMinute,
    FleetAgentRateWindow FiveMinutes);

public sealed record FleetAgentTelemetryPayload(
    string CollectionStatus,
    FleetAgentRateWindows Windows,
    int? ActiveConversationCount,
    double? HostCpuPercent,
    double? HostNetworkReceiveBytesPerSecond,
    double? HostNetworkTransmitBytesPerSecond,
    IReadOnlyList<string> HostCapabilityFlags);

public sealed record FleetAgentDoctorCheck(
    string CheckId,
    string State,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ReasonCode);

public sealed record FleetAgentDoctorPayload(
    string DoctorState,
    string CapabilityCurrentness,
    IReadOnlyList<FleetAgentDoctorCheck> Checks);

public sealed record FleetAgentProviderEnvelope<TPayload>(
    string Schema,
    FleetAgentCapabilityAbi CapabilityAbi,
    string Access,
    string Authority,
    string Operation,
    string ReadRef,
    string ObservedAt,
    FleetAgentFreshness Freshness,
    FleetAgentNativeCarrier NativeCarrier,
    FleetAgentNodeIdentity? Node,
    TPayload Payload);

public static class OplFleetAgentProvider
{
    public const string Schema = "opl_fleet_agent_provider.v1";
    public const string TelemetryRef = "fleet.agent.telemetry.v1#local";
    public const string DoctorRef = "fleet.agent.doctor.v1#current";

    private static readonly FleetAgentCapabilityAbi CapabilityAbi =
        new("opl-fleet-agent.capabilities", "1.0.0");
    private static readonly IReadOnlyList<string> ProjectedCapabilityFlags =
    [
        .. OplFleetAgentProtocol.Capabilities,
        "execution_constraints.not_projected",
        "sanitized_execution_receipts.deferred",
    ];
    private static readonly TimeSpan FreshAge = TimeSpan.FromSeconds(90);

    public static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    public static FleetAgentProviderEnvelope<FleetAgentTelemetryPayload> Telemetry(
        UsageSnapshot usage,
        AmbientOpsMachineIdentity identity,
        UsageSnapshot? fallback = null,
        double? cpuPercent = null,
        HostNetworkTelemetry? network = null,
        DateTimeOffset? now = null)
    {
        var observedAt = now ?? DateTimeOffset.UtcNow;
        var state = Projection(usage, fallback, observedAt);
        var source = state.Source;
        var payload = new FleetAgentTelemetryPayload(
            state.CollectionStatus,
            new FleetAgentRateWindows(
                RateWindow(source?.OneMinute, 60),
                RateWindow(source?.FiveMinutes, 300)),
            source?.ActiveSessions,
            source is null || cpuPercent is null ? null : Math.Clamp(cpuPercent.Value, 0, 100),
            source is null || network is null ? null : MegabitsToBytes(network.DownloadMbps),
            source is null || network is null ? null : MegabitsToBytes(network.UploadMbps),
            source is null ? [] : ProjectedCapabilityFlags);
        return Envelope(
            "telemetry.read",
            TelemetryRef,
            identity,
            observedAt,
            state,
            payload);
    }

    public static FleetAgentProviderEnvelope<FleetAgentDoctorPayload> Doctor(
        UsageSnapshot usage,
        AmbientOpsMachineIdentity identity,
        UsageSnapshot? fallback = null,
        DateTimeOffset? now = null)
    {
        var observedAt = now ?? DateTimeOffset.UtcNow;
        var state = Projection(usage, fallback, observedAt);
        FleetAgentDoctorPayload payload;
        if (state.Source is null)
        {
            payload = new FleetAgentDoctorPayload("unavailable", "unavailable", []);
        }
        else
        {
            var current = state.Freshness.State == "fresh" && usage.Status == CollectionStatus.Ready;
            payload = new FleetAgentDoctorPayload(
                current ? "healthy" : "degraded",
                current ? "current" : "stale",
                [
                    new("provider_executable", "pass", null),
                    new(
                        "usage_collection",
                        usage.Status == CollectionStatus.Ready ? "pass" : "warn",
                        usage.Status == CollectionStatus.Ready ? null : CollectionReason(usage.Status)),
                    new(
                        "sample_freshness",
                        state.Freshness.State == "fresh" ? "pass" : "warn",
                        state.Freshness.State == "fresh" ? null : "last_known_sample"),
                    new("execution_constraints", "unavailable", "not_projected"),
                    new("sanitized_execution_receipts", "unavailable", "deferred_no_source"),
                ]);
        }
        return Envelope("doctor.read", DoctorRef, identity, observedAt, state, payload);
    }

    private sealed record ProjectionState(
        UsageSnapshot? Source,
        FleetAgentFreshness Freshness,
        string CollectionStatus,
        string CarrierStatus);

    private static ProjectionState Projection(
        UsageSnapshot usage,
        UsageSnapshot? fallback,
        DateTimeOffset now)
    {
        var source = usage.Status == CollectionStatus.Ready
            ? usage
            : fallback?.Status == CollectionStatus.Ready
                ? fallback
                : null;
        if (source is null)
        {
            return new ProjectionState(
                null,
                new FleetAgentFreshness(
                    "unavailable",
                    null,
                    false,
                    CollectionReason(usage.Status)),
                "unavailable",
                "degraded");
        }

        var age = now - source.GeneratedAt;
        if (age < TimeSpan.Zero)
        {
            age = TimeSpan.Zero;
        }
        var fresh = usage.Status == CollectionStatus.Ready && age <= FreshAge;
        return new ProjectionState(
            source,
            new FleetAgentFreshness(
                fresh ? "fresh" : "stale",
                Timestamp(source.GeneratedAt),
                !fresh,
                fresh
                    ? null
                    : usage.Status == CollectionStatus.Ready
                        ? "sample_stale"
                        : CollectionReason(usage.Status)),
            fresh ? "available" : "degraded",
            fresh ? "ready" : "degraded");
    }

    private static FleetAgentProviderEnvelope<TPayload> Envelope<TPayload>(
        string operation,
        string readRef,
        AmbientOpsMachineIdentity identity,
        DateTimeOffset now,
        ProjectionState state,
        TPayload payload) =>
        new(
            Schema,
            CapabilityAbi,
            "read_only",
            "observation_only",
            operation,
            readRef,
            Timestamp(now),
            state.Freshness,
            new FleetAgentNativeCarrier(
                "opl_fleet_agent_process",
                "available",
                state.CarrierStatus),
            new FleetAgentNodeIdentity(
                identity.MachineId,
                identity.MachineName,
                SafePlatform(identity.Platform),
                OplFleetAgentProtocol.AgentVersion),
            payload);

    private static FleetAgentRateWindow RateWindow(WindowMetrics? metrics, int seconds) =>
        new(seconds, metrics?.TokensPerSecond, metrics?.RequestsPerMinute);

    private static double MegabitsToBytes(double value) => Math.Max(0, value) * 1_000_000 / 8;

    private static string SafePlatform(string value)
    {
        var safe = Regex.Replace(value, "[^A-Za-z0-9._-]", "-", RegexOptions.CultureInvariant);
        var normalized = string.IsNullOrEmpty(safe) ? "unknown" : safe;
        return normalized[..Math.Min(normalized.Length, 64)];
    }

    private static string CollectionReason(CollectionStatus status) => status switch
    {
        CollectionStatus.Ready => "sample_unavailable",
        CollectionStatus.SessionsDirectoryMissing => "usage_source_unavailable",
        CollectionStatus.ReadFailed => "usage_collection_failed",
        _ => "usage_collection_failed",
    };

    private static string Timestamp(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
}
