namespace OPLFleetAgent.Core;

public sealed record AmbientOpsLoadVisualState(
    int ModelVersion,
    string State,
    string Label,
    double Score,
    bool Constrained,
    double Activity,
    double Parallel,
    double Tempo,
    double TravelMs,
    int ClusterCount,
    double TaskDensity,
    double Pressure,
    double QueueDepth,
    double Heat);

public static class AmbientOpsLoadModel
{
    public const int ModelVersion = 1;

    public static AmbientOpsLoadVisualState VisualState(
        double tps,
        double activeSessions,
        double? cpuPercent)
    {
        var safeTps = Math.Max(0, tps);
        var sessions = Math.Max(0, activeSessions);
        double? cpu = cpuPercent is { } value ? Math.Clamp(value, 0, 100) : null;
        var tpsIntensity = Math.Clamp(Math.Sqrt(safeTps / 60_000), 0, 1);
        var sessionIntensity = Math.Min(1, sessions / 12);
        var cpuIntensity = cpu is { } cpuValue
            ? Math.Min(1, Math.Max(0, cpuValue / 100))
            : (double?)null;
        var score = cpuIntensity is { } intensity
            ? tpsIntensity * 0.56 + sessionIntensity * 0.22 + intensity * 0.22
            : tpsIntensity * 0.72 + sessionIntensity * 0.28;
        var normalizedScore = Math.Clamp(score, 0, 1);
        var hasWork = safeTps > 0 || sessions > 0;
        var pressure = cpu is { } pressureCpu
            ? Math.Clamp((pressureCpu - 68) / 32, 0, 1)
            : 0;
        var constrained = hasWork && cpu is { } constrainedCpu &&
            constrainedCpu >= 88 && normalizedScore >= 0.35;
        var parallel = hasWork ? Math.Clamp(Math.Sqrt(sessions / 18), 0, 1) : 0;
        var tempo = hasWork
            ? Math.Clamp(
                0.45 + normalizedScore * 1.35 + Math.Sqrt(safeTps / 90_000) * 0.7,
                0.45,
                2.5)
            : 0.2;
        var clusterCount = hasWork
            ? Math.Max(1, Math.Min(4, (int)Math.Round(
                1 + parallel * 3,
                MidpointRounding.AwayFromZero)))
            : 0;
        var activity = hasWork
            ? Math.Clamp(normalizedScore * 0.72 + parallel * 0.28, 0, 1)
            : 0;
        var travelSeconds = Math.Clamp(
            3.1 - tpsIntensity * 1.8 - sessionIntensity * 0.35,
            0.8,
            3.1);
        var travelMs = hasWork ? Math.Clamp(travelSeconds * 1_000, 800, 3_100) : 4_800;
        var queueDepth = constrained
            ? Math.Clamp(0.24 + pressure * 0.76, 0.24, 1)
            : Math.Clamp(Math.Max(0, normalizedScore - 0.68) * 0.7, 0, 0.25);
        var state = constrained
            ? (Id: "constrained", Label: "CONSTRAINED")
            : normalizedScore >= 0.45
                ? (Id: "heavy", Label: "HEAVY")
                : normalizedScore >= 0.18
                    ? (Id: "active", Label: "ACTIVE")
                    : (Id: "quiet", Label: "QUIET");

        return new AmbientOpsLoadVisualState(
            ModelVersion,
            state.Id,
            state.Label,
            normalizedScore,
            constrained,
            activity,
            parallel,
            tempo,
            travelMs,
            clusterCount,
            hasWork
                ? Math.Clamp(0.16 + activity * 0.68 + parallel * 0.16, 0.16, 1)
                : 0,
            pressure,
            queueDepth,
            Math.Clamp(pressure * 0.9 + activity * 0.12, 0, 1));
    }
}

public sealed record AmbientOpsDirectStatus(
    int SchemaVersion,
    string ServerVersion,
    string InstanceId,
    DateTimeOffset GeneratedAt,
    bool Demo,
    AmbientOpsDirectSite Site,
    string OverallStatus,
    AmbientOpsDirectProvider Provider,
    AmbientOpsDirectCapabilities Capabilities,
    AmbientOpsDirectNetwork Network,
    AmbientOpsDirectCodex Codex,
    IReadOnlyList<AmbientOpsDirectMachine> Machines);

public sealed record AmbientOpsDirectSite(string Name, string TimeZone);

public sealed record AmbientOpsDirectProvider(string Kind, string Scope, string Id, string Name);

public sealed record AmbientOpsDirectCapabilities(
    bool LoadVisualState,
    bool Network,
    bool NetworkHistory,
    bool PersistentHistory,
    bool Pets,
    bool WebDisplay,
    bool LiveActivityPush);

public sealed record AmbientOpsDirectNetwork(
    string Status,
    string? Source,
    double? DownloadMbps,
    double? UploadMbps,
    double? Clients,
    double? LatencyMs,
    DateTimeOffset? UpdatedAt,
    string? Error,
    double? AgeSeconds,
    IReadOnlyList<AmbientOpsDirectNetworkHistoryPoint> History);

public sealed record AmbientOpsDirectNetworkHistoryPoint(
    DateTimeOffset At,
    double DownloadMbps,
    double UploadMbps);

public sealed record AmbientOpsDirectCodex(
    string Status,
    double OneMinuteTps,
    double FiveMinuteTps,
    double CachePercent,
    double ActiveSessions,
    double? CpuPercent,
    double CpuReportedMachineCount,
    double? MemoryPercent,
    double MemoryReportedMachineCount,
    double MachineCount,
    double LiveMachineCount,
    double StaleMachineCount);

public sealed record AmbientOpsDirectMachine(
    string MachineId,
    string MachineName,
    string Platform,
    DateTimeOffset GeneratedAt,
    DateTimeOffset ReceivedAt,
    string ReportedStatus,
    string? Error,
    AmbientOpsWindowSnapshot OneMinute,
    AmbientOpsWindowSnapshot FiveMinutes,
    double ActiveSessions,
    double? CpuPercent,
    double? MemoryPercent,
    AmbientOpsDirectPet? Pet,
    string Status,
    double AgeSeconds,
    double CachePercent,
    AmbientOpsLoadVisualState LoadVisualState);

public sealed record AmbientOpsDirectPet(
    string Id,
    string DisplayName,
    int SpriteVersionNumber,
    string AssetHash,
    AmbientOpsPetState State,
    DateTimeOffset StateSince,
    string AssetUrl);

public static class AmbientOpsDirectStatusBuilder
{
    public static AmbientOpsDirectStatus Build(
        AmbientOpsMachineObservation observation,
        string serverVersion,
        HostNetworkTelemetry? networkTelemetry = null,
        DateTimeOffset? generatedAt = null)
    {
        var now = generatedAt ?? DateTimeOffset.Now;
        var identity = observation.Identity;
        var snapshot = observation.Snapshot;
        var live = snapshot.Status == "live";
        var cachePercent = snapshot.OneMinute.InputTokens > 0
            ? Math.Round(
                (double)snapshot.OneMinute.CachedInputTokens /
                snapshot.OneMinute.InputTokens * 100)
            : 0;
        var visual = AmbientOpsLoadModel.VisualState(
            snapshot.OneMinute.Tps,
            snapshot.ActiveSessions,
            snapshot.CpuPercent);
        var pet = snapshot.Pet is { } petSnapshot
            ? new AmbientOpsDirectPet(
                petSnapshot.Id,
                petSnapshot.DisplayName,
                petSnapshot.SpriteVersionNumber,
                petSnapshot.AssetHash,
                petSnapshot.State,
                petSnapshot.StateSince,
                $"/api/v1/pets/{petSnapshot.AssetHash}")
            : null;
        var machine = new AmbientOpsDirectMachine(
            identity.MachineId,
            identity.MachineName,
            identity.Platform,
            snapshot.GeneratedAt,
            now,
            snapshot.Status,
            snapshot.Error,
            snapshot.OneMinute,
            snapshot.FiveMinutes,
            snapshot.ActiveSessions,
            snapshot.CpuPercent,
            null,
            pet,
            live ? "live" : "error",
            Math.Max(0, Math.Round((now - snapshot.GeneratedAt).TotalSeconds)),
            cachePercent,
            visual);
        var providerId = $"opl-fleet-agent-{identity.MachineId}";
        var status = live ? "live" : "error";

        return new AmbientOpsDirectStatus(
            1,
            serverVersion,
            providerId,
            now,
            false,
            new AmbientOpsDirectSite(identity.MachineName, TimeZoneInfo.Local.Id),
            status,
            new AmbientOpsDirectProvider(
                "opl-fleet-agent",
                "machine",
                identity.MachineId,
                identity.MachineName),
            new AmbientOpsDirectCapabilities(
                true,
                true,
                false,
                false,
                true,
                false,
                false),
            new AmbientOpsDirectNetwork(
                networkTelemetry is null ? "unavailable" : "live",
                "host",
                networkTelemetry?.DownloadMbps,
                networkTelemetry?.UploadMbps,
                null,
                null,
                networkTelemetry?.SampledAt,
                null,
                networkTelemetry is null
                    ? null
                    : Math.Max(0, Math.Round((now - networkTelemetry.SampledAt).TotalSeconds)),
                []),
            new AmbientOpsDirectCodex(
                status,
                snapshot.OneMinute.Tps,
                snapshot.FiveMinutes.Tps,
                cachePercent,
                snapshot.ActiveSessions,
                snapshot.CpuPercent,
                snapshot.CpuPercent is null ? 0 : 1,
                null,
                0,
                1,
                live ? 1 : 0,
                0),
            [machine]);
    }
}
