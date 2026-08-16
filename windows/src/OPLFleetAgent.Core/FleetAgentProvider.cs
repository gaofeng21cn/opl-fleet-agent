using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace OPLFleetAgent.Core;

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
        string? fallbackLastObservedAt = null,
        double? cpuPercent = null,
        HostNetworkTelemetry? network = null,
        string? unavailableReasonCode = null,
        DateTimeOffset? now = null)
    {
        var observedAt = now ?? DateTimeOffset.UtcNow;
        var state = Projection(
            usage,
            fallback,
            fallbackLastObservedAt,
            unavailableReasonCode,
            observedAt);
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
        string? fallbackLastObservedAt = null,
        string? unavailableReasonCode = null,
        DateTimeOffset? now = null)
    {
        var observedAt = now ?? DateTimeOffset.UtcNow;
        var state = Projection(
            usage,
            fallback,
            fallbackLastObservedAt,
            unavailableReasonCode,
            observedAt);
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
        string? fallbackLastObservedAt,
        string? unavailableReasonCode,
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
                    unavailableReasonCode ?? CollectionReason(usage.Status)),
                "unavailable",
                "degraded");
        }

        var age = now - source.GeneratedAt;
        if (age < TimeSpan.Zero)
        {
            age = TimeSpan.Zero;
        }
        var fresh = usage.Status == CollectionStatus.Ready && age <= FreshAge;
        var lastObservedAt = usage.Status == CollectionStatus.Ready
            ? Timestamp(source.GeneratedAt)
            : fallbackLastObservedAt ?? Timestamp(source.GeneratedAt);
        return new ProjectionState(
            source,
            new FleetAgentFreshness(
                fresh ? "fresh" : "stale",
                lastObservedAt,
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

public sealed record FleetAgentLastKnownSample(
    string LastObservedAt,
    DateTimeOffset ObservedAt,
    FleetAgentTelemetryPayload Payload)
{
    public UsageSnapshot UsageSnapshot() =>
        new(
            ObservedAt,
            Metrics(Payload.Windows.OneMinute),
            Metrics(Payload.Windows.FiveMinutes),
            WindowMetrics.Empty(1_800),
            WindowMetrics.Empty(3_600),
            Payload.ActiveConversationCount ?? 0,
            0,
            CollectionStatus.Ready);

    public HostNetworkTelemetry? NetworkTelemetry() =>
        Payload.HostNetworkReceiveBytesPerSecond is { } receive &&
        Payload.HostNetworkTransmitBytesPerSecond is { } transmit
            ? new HostNetworkTelemetry(
                receive * 8 / 1_000_000,
                transmit * 8 / 1_000_000,
                ObservedAt)
            : null;

    private static WindowMetrics Metrics(FleetAgentRateWindow value) =>
        new(
            value.WindowSeconds,
            0,
            value.RequestRatePerMinute ?? 0,
            value.TokenRatePerSecond ?? 0,
            0,
            0,
            0,
            0,
            0,
            0);
}

public enum FleetAgentLastKnownLoadState
{
    Available,
    Missing,
    Expired,
    Invalid,
    PrivacyRejected,
}

public sealed record FleetAgentLastKnownLoad(
    FleetAgentLastKnownLoadState State,
    FleetAgentLastKnownSample? Sample = null)
{
    public string? UnavailableReasonCode => State switch
    {
        FleetAgentLastKnownLoadState.Expired => "last_known_cache_expired",
        FleetAgentLastKnownLoadState.Invalid => "last_known_cache_invalid",
        FleetAgentLastKnownLoadState.PrivacyRejected => "last_known_cache_privacy_rejected",
        _ => null,
    };
}

public sealed class FleetAgentLastKnownStore
{
    public static readonly TimeSpan TimeToLive = TimeSpan.FromMinutes(15);

    private const int MaximumBytes = 65_536;
    private static readonly string[] ForbiddenKeyParts =
    [
        "prompt",
        "response",
        "session",
        "path",
        "address",
        "credential",
        "secret",
        "raw_log",
        "rawlog",
    ];
    private static readonly HashSet<string> ForbiddenAuthorityKeys =
        new(StringComparer.Ordinal)
        {
            "admission",
            "lease",
            "dispatch",
            "task_completion",
            "completion_verdict",
        };

    private readonly string path;

    public FleetAgentLastKnownStore(string path)
    {
        this.path = Path.GetFullPath(path);
    }

    public static string DefaultPath()
    {
        var configured = Environment.GetEnvironmentVariable("OPL_FLEET_AGENT_PROVIDER_CACHE");
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return Path.GetFullPath(Environment.ExpandEnvironmentVariables(configured.Trim()));
        }
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OPL Fleet Agent",
            "provider-last-known.json");
    }

    public FleetAgentLastKnownLoad Load(DateTimeOffset? currentTime = null)
    {
        if (!File.Exists(path))
        {
            return new(FleetAgentLastKnownLoadState.Missing);
        }
        byte[] bytes;
        try
        {
            var info = new FileInfo(path);
            if (info.Length > MaximumBytes)
            {
                Remove();
                return new(FleetAgentLastKnownLoadState.Invalid);
            }
            bytes = File.ReadAllBytes(path);
        }
        catch (IOException)
        {
            Remove();
            return new(FleetAgentLastKnownLoadState.Invalid);
        }
        catch (UnauthorizedAccessException)
        {
            Remove();
            return new(FleetAgentLastKnownLoadState.Invalid);
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(bytes);
        }
        catch (JsonException)
        {
            Remove();
            return new(FleetAgentLastKnownLoadState.Invalid);
        }
        using (document)
        {
            if (ContainsForbiddenKey(document.RootElement))
            {
                Remove();
                return new(FleetAgentLastKnownLoadState.PrivacyRejected);
            }
            if (!HasExactCacheShape(document.RootElement))
            {
                Remove();
                return new(FleetAgentLastKnownLoadState.Invalid);
            }
        }

        CacheRecord? record;
        try
        {
            record = JsonSerializer.Deserialize<CacheRecord>(
                bytes,
                OplFleetAgentProvider.SerializerOptions);
        }
        catch (JsonException)
        {
            Remove();
            return new(FleetAgentLastKnownLoadState.Invalid);
        }
        if (record is null ||
            record.Payload is null ||
            !DateTimeOffset.TryParseExact(
                record.LastObservedAt,
                "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var observedAt) ||
            !IsValid(record.Payload))
        {
            Remove();
            return new(FleetAgentLastKnownLoadState.Invalid);
        }
        var age = (currentTime ?? DateTimeOffset.UtcNow) - observedAt;
        if (age < TimeSpan.Zero)
        {
            Remove();
            return new(FleetAgentLastKnownLoadState.Invalid);
        }
        if (age > TimeToLive)
        {
            Remove();
            return new(FleetAgentLastKnownLoadState.Expired);
        }
        return new(
            FleetAgentLastKnownLoadState.Available,
            new FleetAgentLastKnownSample(record.LastObservedAt, observedAt, record.Payload));
    }

    public void Save(FleetAgentProviderEnvelope<FleetAgentTelemetryPayload> projection)
    {
        if (projection.Freshness.State != "fresh" ||
            projection.Freshness.LastKnown ||
            projection.Freshness.LastObservedAt is not { } lastObservedAt ||
            !IsValid(projection.Payload))
        {
            throw new InvalidOperationException("Only fresh sanitized provider data can be cached.");
        }
        var directory = Path.GetDirectoryName(path)
            ?? throw new InvalidOperationException("Provider cache path has no parent directory.");
        Directory.CreateDirectory(directory);
        var temporaryPath = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllBytes(
                temporaryPath,
                JsonSerializer.SerializeToUtf8Bytes(
                    new CacheRecord(lastObservedAt, projection.Payload),
                    OplFleetAgentProvider.SerializerOptions));
            File.Move(temporaryPath, path, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }

    private sealed record CacheRecord(
        string LastObservedAt,
        FleetAgentTelemetryPayload Payload);

    private void Remove()
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static bool ContainsForbiddenKey(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Array)
        {
            return value.EnumerateArray().Any(ContainsForbiddenKey);
        }
        if (value.ValueKind != JsonValueKind.Object)
        {
            return false;
        }
        foreach (var property in value.EnumerateObject())
        {
            var normalized = property.Name.ToLowerInvariant();
            if (ForbiddenKeyParts.Any(part =>
                    normalized.Contains(part, StringComparison.Ordinal)) ||
                ForbiddenAuthorityKeys.Contains(normalized) ||
                ContainsForbiddenKey(property.Value))
            {
                return true;
            }
        }
        return false;
    }

    private static bool HasExactCacheShape(JsonElement root)
    {
        if (!HasExactProperties(root, "last_observed_at", "payload") ||
            !root.TryGetProperty("payload", out var payload) ||
            !HasExactProperties(
                payload,
                "collection_status",
                "windows",
                "active_conversation_count",
                "host_cpu_percent",
                "host_network_receive_bytes_per_second",
                "host_network_transmit_bytes_per_second",
                "host_capability_flags") ||
            !payload.TryGetProperty("windows", out var windows) ||
            !HasExactProperties(windows, "one_minute", "five_minutes") ||
            !windows.TryGetProperty("one_minute", out var oneMinute) ||
            !windows.TryGetProperty("five_minutes", out var fiveMinutes))
        {
            return false;
        }
        return HasExactProperties(
                oneMinute,
                "window_seconds",
                "token_rate_per_second",
                "request_rate_per_minute") &&
            HasExactProperties(
                fiveMinutes,
                "window_seconds",
                "token_rate_per_second",
                "request_rate_per_minute");
    }

    private static bool HasExactProperties(JsonElement value, params string[] expected)
    {
        if (value.ValueKind != JsonValueKind.Object)
        {
            return false;
        }
        return value.EnumerateObject().Select(item => item.Name).ToHashSet(StringComparer.Ordinal)
            .SetEquals(expected);
    }

    private static bool IsValid(FleetAgentTelemetryPayload payload) =>
        payload.CollectionStatus == "available" &&
        payload.Windows is not null &&
        payload.Windows.OneMinute is not null &&
        payload.Windows.FiveMinutes is not null &&
        payload.Windows.OneMinute.WindowSeconds == 60 &&
        payload.Windows.FiveMinutes.WindowSeconds == 300 &&
        IsNonNegative(payload.Windows.OneMinute.TokenRatePerSecond) &&
        IsNonNegative(payload.Windows.OneMinute.RequestRatePerMinute) &&
        IsNonNegative(payload.Windows.FiveMinutes.TokenRatePerSecond) &&
        IsNonNegative(payload.Windows.FiveMinutes.RequestRatePerMinute) &&
        payload.ActiveConversationCount is >= 0 &&
        IsOptionalRange(payload.HostCpuPercent, 0, 100) &&
        IsOptionalNonNegative(payload.HostNetworkReceiveBytesPerSecond) &&
        IsOptionalNonNegative(payload.HostNetworkTransmitBytesPerSecond) &&
        payload.HostCapabilityFlags is not null &&
        payload.HostCapabilityFlags.Distinct(StringComparer.Ordinal).Count() ==
            payload.HostCapabilityFlags.Count &&
        payload.HostCapabilityFlags.All(flag =>
            flag.Length <= 64 && Regex.IsMatch(
                flag,
                "^[a-z][a-z0-9._-]*$",
                RegexOptions.CultureInvariant));

    private static bool IsNonNegative(double? value) =>
        value is { } number && double.IsFinite(number) && number >= 0;

    private static bool IsOptionalNonNegative(double? value) =>
        value is null || double.IsFinite(value.Value) && value.Value >= 0;

    private static bool IsOptionalRange(double? value, double minimum, double maximum) =>
        value is null ||
        double.IsFinite(value.Value) && value.Value >= minimum && value.Value <= maximum;
}
