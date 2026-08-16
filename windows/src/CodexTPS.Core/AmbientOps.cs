using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace CodexTPS.Core;

public sealed record AmbientOpsService(
    string InstanceId,
    string Name,
    Uri Endpoint,
    string DisplayPath,
    bool SupportsPairing = false);

public static partial class AmbientOpsDiscoveryContract
{
    public const string ServiceType = "_ambient-ops._tcp.local.";
    public const string ProtocolVersion = "1";
    public const string DefaultDisplayPath = "/display/overview";

    public static AmbientOpsService? CreateService(
        string serviceName,
        string? host,
        int port,
        IReadOnlyDictionary<string, string> txt)
    {
        if (string.IsNullOrWhiteSpace(host) || port is <= 0 or > 65_535 ||
            !txt.TryGetValue("protocol", out var protocol) || protocol != ProtocolVersion)
        {
            return null;
        }
        var normalizedHost = host.Trim().TrimEnd('.');
        if (!Uri.TryCreate($"http://{FormatHost(normalizedHost)}:{port}", UriKind.Absolute, out var endpoint))
        {
            return null;
        }

        var instanceId = NormalizeInstanceId(txt.GetValueOrDefault("id")) ??
            NormalizeInstanceId(serviceName);
        if (instanceId is null)
        {
            return null;
        }
        var name = txt.GetValueOrDefault("name");
        if (string.IsNullOrWhiteSpace(name))
        {
            name = serviceName;
        }
        return new AmbientOpsService(
            instanceId,
            name.Trim()[..Math.Min(name.Trim().Length, 80)],
            endpoint,
            NormalizePath(txt.GetValueOrDefault("path")),
            txt.GetValueOrDefault("pairing") == "1");
    }

    public static string NormalizePath(string? value)
    {
        var path = value?.Trim();
        return path is { Length: > 0 and <= 160 } && path.StartsWith('/')
            ? path
            : DefaultDisplayPath;
    }

    public static string? NormalizeInstanceId(string? value)
    {
        var normalized = value?.Trim().ToLowerInvariant();
        return normalized is not null && InstanceIdPattern().IsMatch(normalized)
            ? normalized
            : null;
    }

    private static string FormatHost(string host) => host.Contains(':') ? $"[{host}]" : host;

    [GeneratedRegex("^[a-z0-9][a-z0-9._-]{0,79}$", RegexOptions.CultureInvariant)]
    private static partial Regex InstanceIdPattern();
}

public sealed class AmbientOpsServiceSelector
{
    private readonly string? preferredInstanceId;
    private readonly HashSet<Uri> failedEndpoints = [];

    public AmbientOpsServiceSelector(string? preferredInstanceId)
    {
        this.preferredInstanceId =
            AmbientOpsDiscoveryContract.NormalizeInstanceId(preferredInstanceId);
    }

    public AmbientOpsService? Select(IEnumerable<AmbientOpsService> services) =>
        services
            .Where(service => !failedEndpoints.Contains(service.Endpoint))
            .OrderBy(service => service.InstanceId == preferredInstanceId ? 0 : 1)
            .ThenBy(service => service.InstanceId, StringComparer.Ordinal)
            .ThenBy(service => service.Endpoint.AbsoluteUri, StringComparer.Ordinal)
            .FirstOrDefault();

    public void RecordPushFailure(AmbientOpsService service) =>
        failedEndpoints.Add(service.Endpoint);

    public void ResetFailures() => failedEndpoints.Clear();
}

public sealed partial record AmbientOpsMachineIdentity
{
    public AmbientOpsMachineIdentity(string machineId, string machineName, string platform)
    {
        if (!MachineIdPattern().IsMatch(machineId))
        {
            throw new ArgumentException(
                "Machine ID must contain 1-80 letters, numbers, dots, underscores, or hyphens.",
                nameof(machineId));
        }
        MachineId = machineId;
        MachineName = machineName[..Math.Min(machineName.Length, 80)];
        Platform = platform[..Math.Min(platform.Length, 32)];
    }

    [JsonIgnore]
    public string MachineId { get; }

    public string MachineName { get; }
    public string Platform { get; }

    [GeneratedRegex("^[A-Za-z0-9._-]{1,80}$", RegexOptions.CultureInvariant)]
    private static partial Regex MachineIdPattern();
}

public sealed record AmbientOpsWindowSnapshot(
    double Tps,
    long InputTokens,
    long OutputTokens,
    long CachedInputTokens,
    long ReasoningOutputTokens,
    int Requests)
{
    public static AmbientOpsWindowSnapshot FromMetrics(WindowMetrics metrics) =>
        new(
            metrics.TokensPerSecond,
            (long)Math.Round(metrics.InputTokensPerSecond * metrics.WindowSeconds),
            (long)Math.Round(metrics.OutputTokensPerSecond * metrics.WindowSeconds),
            (long)Math.Round(metrics.CachedInputTokensPerSecond * metrics.WindowSeconds),
            (long)Math.Round(metrics.ReasoningTokensPerSecond * metrics.WindowSeconds),
            metrics.RequestCount);
}

public enum AmbientOpsPetState
{
    Idle,
    Running,
    Waiting,
    Review,
    Failed,
}

public sealed record AmbientOpsPetDefinition(
    string Id,
    string DisplayName,
    int SpriteVersionNumber,
    string AssetHash)
{
    public static readonly AmbientOpsPetDefinition LedgerOwl = new(
        "ledger-owl",
        "Ledger Owl",
        1,
        "783854af87d6ee8639843ca7812917e062345b0095d43f9be5ea2374a41ada6c");
}

public sealed record AmbientOpsPetSnapshot(
    string Id,
    string DisplayName,
    int SpriteVersionNumber,
    string AssetHash,
    AmbientOpsPetState State,
    DateTimeOffset StateSince);

public sealed class AmbientOpsPetTracker
{
    private AmbientOpsPetState? state;
    private DateTimeOffset? stateSince;

    public AmbientOpsPetSnapshot Snapshot(
        AmbientOpsPetDefinition definition,
        UsageSnapshot usage)
    {
        var next = usage.Status != CollectionStatus.Ready
            ? AmbientOpsPetState.Failed
            : usage.ActiveSessions > 0 && usage.OneMinute.RequestCount > 0
                ? AmbientOpsPetState.Running
                : AmbientOpsPetState.Idle;
        if (next != state)
        {
            state = next;
            stateSince = usage.GeneratedAt;
        }
        return new AmbientOpsPetSnapshot(
            definition.Id,
            definition.DisplayName,
            Math.Max(definition.SpriteVersionNumber, 1),
            definition.AssetHash,
            next,
            stateSince ?? usage.GeneratedAt);
    }
}

public static class OplFleetAgentProtocol
{
    public const string Schema = "opl_fleet_agent_telemetry.v1";
    public const string ProductName = "OPL Fleet Agent";
    public const string GatewayProductName = "OPL Fleet Gateway";
    public const string GatewayShortName = "Fleet Gateway";
    public const string AgentVersion = "0.2.38";
    public static readonly string[] Modes = ["local", "direct", "fleet"];
    public static readonly string[] Capabilities =
    [
        "node_local_observation",
        "node_local_doctor",
        "local_codex_telemetry",
        "host_dashboard",
    ];
}

public sealed record OplFleetAgentEnvelope(
    string Schema,
    string Product,
    [property: JsonPropertyName("stableNodeID")]
    string StableNodeId,
    string AgentVersion,
    IReadOnlyList<string> Modes,
    IReadOnlyList<string> Capabilities,
    string Authority)
{
    public static OplFleetAgentEnvelope For(AmbientOpsMachineIdentity identity) => new(
        OplFleetAgentProtocol.Schema,
        OplFleetAgentProtocol.ProductName,
        identity.MachineId,
        OplFleetAgentProtocol.AgentVersion,
        OplFleetAgentProtocol.Modes,
        OplFleetAgentProtocol.Capabilities,
        "node_agent");
}

public sealed record AmbientOpsAgentSnapshot(
    int SchemaVersion,
    string MachineName,
    string Platform,
    DateTimeOffset GeneratedAt,
    string Status,
    string? Error,
    AmbientOpsWindowSnapshot OneMinute,
    AmbientOpsWindowSnapshot FiveMinutes,
    int ActiveSessions,
    double? CpuPercent,
    HostNetworkTelemetry? Network,
    AmbientOpsPetSnapshot? Pet,
    OplFleetAgentEnvelope? OplFleet)
{
    public static AmbientOpsAgentSnapshot FromUsage(
        UsageSnapshot usage,
        AmbientOpsMachineIdentity identity,
        AmbientOpsAgentSnapshot? fallback = null,
        double? cpuPercent = null,
        HostNetworkTelemetry? network = null,
        AmbientOpsPetSnapshot? pet = null)
    {
        var live = usage.Status == CollectionStatus.Ready;
        return new AmbientOpsAgentSnapshot(
            3,
            identity.MachineName,
            identity.Platform,
            usage.GeneratedAt,
            live ? "live" : "error",
            live ? null : ErrorMessage(usage.Status),
            live || fallback is null
                ? AmbientOpsWindowSnapshot.FromMetrics(usage.OneMinute)
                : fallback.OneMinute,
            live || fallback is null
                ? AmbientOpsWindowSnapshot.FromMetrics(usage.FiveMinutes)
                : fallback.FiveMinutes,
            live ? usage.ActiveSessions : fallback?.ActiveSessions ?? 0,
            live ? cpuPercent : fallback?.CpuPercent,
            live ? network : fallback?.Network,
            pet,
            OplFleetAgentEnvelope.For(identity));
    }

    private static string ErrorMessage(CollectionStatus status) => status switch
    {
        CollectionStatus.SessionsDirectoryMissing => "Codex sessions directory is unavailable",
        CollectionStatus.ReadFailed => "Codex usage collection failed",
        _ => string.Empty,
    };
}

public sealed record AmbientOpsMachineObservation(
    AmbientOpsMachineIdentity Identity,
    AmbientOpsAgentSnapshot Snapshot,
    AmbientOpsPetAsset? PetAsset);

public sealed class AmbientOpsPushClient
{
    public static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly HttpClient httpClient;

    public AmbientOpsPushClient(HttpClient? httpClient = null)
    {
        this.httpClient = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
    }

    public HttpRequestMessage CreateRequest(
        Uri endpoint,
        string token,
        AmbientOpsMachineIdentity identity,
        AmbientOpsAgentSnapshot snapshot)
    {
        if (endpoint.Scheme is not ("http" or "https") || string.IsNullOrWhiteSpace(endpoint.Host))
        {
            throw new ArgumentException("OPL Fleet Gateway URL must be HTTP or HTTPS.", nameof(endpoint));
        }
        if (string.IsNullOrWhiteSpace(token))
        {
            throw new ArgumentException("OPL Fleet Gateway push token is required.", nameof(token));
        }

        var url = new Uri(
            endpoint.AbsoluteUri.TrimEnd('/') +
            $"/api/v1/agents/{Uri.EscapeDataString(identity.MachineId)}/snapshot");
        var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(
                JsonSerializer.Serialize(snapshot, SerializerOptions),
                Encoding.UTF8,
                "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Trim());
        return request;
    }

    public HttpRequestMessage CreateSignedRequest(
        Uri endpoint,
        AmbientOpsDeviceKey deviceKey,
        AmbientOpsMachineIdentity identity,
        AmbientOpsAgentSnapshot snapshot,
        DateTimeOffset? now = null,
        string? nonce = null)
    {
        if (endpoint.Scheme is not ("http" or "https") || string.IsNullOrWhiteSpace(endpoint.Host))
        {
            throw new ArgumentException("OPL Fleet Gateway URL must be HTTP or HTTPS.", nameof(endpoint));
        }
        ArgumentNullException.ThrowIfNull(deviceKey);

        var url = new Uri(
            endpoint.AbsoluteUri.TrimEnd('/') +
            $"/api/v1/agents/{Uri.EscapeDataString(identity.MachineId)}/snapshot");
        var body = JsonSerializer.SerializeToUtf8Bytes(snapshot, SerializerOptions);
        return CreateSignedContentRequest(
            url,
            HttpMethod.Post,
            deviceKey,
            identity,
            body,
            "application/json",
            includeUtf8Charset: true,
            now: now,
            nonce: nonce);
    }

    public async Task PushAsync(
        Uri endpoint,
        string token,
        AmbientOpsMachineIdentity identity,
        AmbientOpsAgentSnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        await PushAsync(
            endpoint,
            token,
            identity,
            snapshot,
            petAsset: null,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task PushAsync(
        Uri endpoint,
        string token,
        AmbientOpsMachineIdentity identity,
        AmbientOpsAgentSnapshot snapshot,
        AmbientOpsPetAsset? petAsset,
        CancellationToken cancellationToken = default)
    {
        await PushAsync(
            endpoint,
            token,
            identity,
            snapshot,
            petAsset,
            retryUploadConflict: true,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task PushAsync(
        Uri endpoint,
        string token,
        AmbientOpsMachineIdentity identity,
        AmbientOpsAgentSnapshot snapshot,
        AmbientOpsPetAsset? petAsset,
        bool retryUploadConflict,
        CancellationToken cancellationToken)
    {
        using var request = CreateRequest(endpoint, token, identity, snapshot);
        using var response = await httpClient.SendAsync(request, cancellationToken)
            .ConfigureAwait(false);
        if ((int)response.StatusCode != 202)
        {
            throw new HttpRequestException(
                $"OPL Fleet Gateway returned HTTP {(int)response.StatusCode}.",
                inner: null,
                response.StatusCode);
        }

        var body = await response.Content.ReadAsStringAsync(cancellationToken)
            .ConfigureAwait(false);
        AmbientOpsPushResponse accepted;
        try
        {
            accepted = string.IsNullOrWhiteSpace(body)
                ? new AmbientOpsPushResponse()
                : JsonSerializer.Deserialize<AmbientOpsPushResponse>(body, SerializerOptions)
                    ?? throw new JsonException("OPL Fleet Gateway returned an empty response.");
        }
        catch (JsonException error)
        {
            throw new HttpRequestException("OPL Fleet Gateway returned an invalid response.", error);
        }

        if (petAsset is null ||
            !accepted.MissingPetAssets.Contains(
                petAsset.Definition.AssetHash,
                StringComparer.Ordinal))
        {
            return;
        }

        using var uploadRequest = CreatePetAssetRequest(
            endpoint,
            token,
            identity,
            petAsset);
        using var uploadResponse = await httpClient.SendAsync(uploadRequest, cancellationToken)
            .ConfigureAwait(false);
        if ((int)uploadResponse.StatusCode == 409 && retryUploadConflict)
        {
            await PushAsync(
                endpoint,
                token,
                identity,
                snapshot,
                petAsset,
                retryUploadConflict: false,
                cancellationToken).ConfigureAwait(false);
            return;
        }
        if ((int)uploadResponse.StatusCode is not (201 or 204))
        {
            throw new HttpRequestException(
                $"OPL Fleet Gateway returned HTTP {(int)uploadResponse.StatusCode}.");
        }
    }

    internal HttpRequestMessage CreatePetAssetRequest(
        Uri endpoint,
        string token,
        AmbientOpsMachineIdentity identity,
        AmbientOpsPetAsset asset)
    {
        var url = new Uri(
            endpoint.AbsoluteUri.TrimEnd('/') +
            $"/api/v1/agents/{Uri.EscapeDataString(identity.MachineId)}/pets/" +
            asset.Definition.AssetHash);
        var content = new ByteArrayContent(asset.Data.ToArray());
        content.Headers.ContentType = new MediaTypeHeaderValue("image/webp");
        var request = new HttpRequestMessage(HttpMethod.Put, url)
        {
            Content = content,
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Trim());
        return request;
    }

    internal HttpRequestMessage CreateSignedPetAssetRequest(
        Uri endpoint,
        AmbientOpsDeviceKey deviceKey,
        AmbientOpsMachineIdentity identity,
        AmbientOpsPetAsset asset,
        DateTimeOffset? now = null,
        string? nonce = null)
    {
        var url = new Uri(
            endpoint.AbsoluteUri.TrimEnd('/') +
            $"/api/v1/agents/{Uri.EscapeDataString(identity.MachineId)}/pets/" +
            asset.Definition.AssetHash);
        return CreateSignedContentRequest(
            url,
            HttpMethod.Put,
            deviceKey,
            identity,
            asset.Data.ToArray(),
            "image/webp",
            includeUtf8Charset: false,
            now: now,
            nonce: nonce);
    }

    private static HttpRequestMessage CreateSignedContentRequest(
        Uri url,
        HttpMethod method,
        AmbientOpsDeviceKey deviceKey,
        AmbientOpsMachineIdentity identity,
        byte[] body,
        string mediaType,
        bool includeUtf8Charset,
        DateTimeOffset? now,
        string? nonce)
    {
        var timestamp = (now ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds().ToString(
            System.Globalization.CultureInfo.InvariantCulture);
        var requestNonce = nonce ?? AmbientOpsDeviceKey.CreateNonce();
        var signature = deviceKey.Sign(
            method.Method,
            url.AbsolutePath,
            timestamp,
            requestNonce,
            body);
        var content = new ByteArrayContent(body);
        content.Headers.ContentType = new MediaTypeHeaderValue(mediaType);
        if (includeUtf8Charset)
        {
            content.Headers.ContentType.CharSet = Encoding.UTF8.WebName;
        }
        var request = new HttpRequestMessage(method, url)
        {
            Content = content,
        };
        request.Headers.Authorization = new AuthenticationHeaderValue(
            "AmbientKey",
            identity.MachineId);
        request.Headers.TryAddWithoutValidation("X-Ambient-Timestamp", timestamp);
        request.Headers.TryAddWithoutValidation("X-Ambient-Nonce", requestNonce);
        request.Headers.TryAddWithoutValidation("X-Ambient-Signature", signature);
        return request;
    }

    private sealed record AmbientOpsPushResponse
    {
        public string[] MissingPetAssets { get; init; } = [];
    }

    public async Task PushSignedAsync(
        Uri endpoint,
        AmbientOpsDeviceKey deviceKey,
        AmbientOpsMachineIdentity identity,
        AmbientOpsAgentSnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        await PushSignedAsync(
            endpoint,
            deviceKey,
            identity,
            snapshot,
            petAsset: null,
            cancellationToken).ConfigureAwait(false);
    }

    public async Task PushSignedAsync(
        Uri endpoint,
        AmbientOpsDeviceKey deviceKey,
        AmbientOpsMachineIdentity identity,
        AmbientOpsAgentSnapshot snapshot,
        AmbientOpsPetAsset? petAsset,
        CancellationToken cancellationToken = default)
    {
        await PushSignedAsync(
            endpoint,
            deviceKey,
            identity,
            snapshot,
            petAsset,
            retryUploadConflict: true,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task PushSignedAsync(
        Uri endpoint,
        AmbientOpsDeviceKey deviceKey,
        AmbientOpsMachineIdentity identity,
        AmbientOpsAgentSnapshot snapshot,
        AmbientOpsPetAsset? petAsset,
        bool retryUploadConflict,
        CancellationToken cancellationToken)
    {
        using var request = CreateSignedRequest(endpoint, deviceKey, identity, snapshot);
        using var response = await httpClient.SendAsync(request, cancellationToken)
            .ConfigureAwait(false);
        if ((int)response.StatusCode != 202)
        {
            throw new HttpRequestException(
                $"OPL Fleet Gateway returned HTTP {(int)response.StatusCode}.",
                inner: null,
                response.StatusCode);
        }

        var body = await response.Content.ReadAsStringAsync(cancellationToken)
            .ConfigureAwait(false);
        AmbientOpsPushResponse accepted;
        try
        {
            accepted = string.IsNullOrWhiteSpace(body)
                ? new AmbientOpsPushResponse()
                : JsonSerializer.Deserialize<AmbientOpsPushResponse>(body, SerializerOptions)
                    ?? throw new JsonException("OPL Fleet Gateway returned an empty response.");
        }
        catch (JsonException error)
        {
            throw new HttpRequestException("OPL Fleet Gateway returned an invalid response.", error);
        }

        if (petAsset is null ||
            !accepted.MissingPetAssets.Contains(
                petAsset.Definition.AssetHash,
                StringComparer.Ordinal))
        {
            return;
        }

        using var uploadRequest = CreateSignedPetAssetRequest(
            endpoint,
            deviceKey,
            identity,
            petAsset);
        using var uploadResponse = await httpClient.SendAsync(uploadRequest, cancellationToken)
            .ConfigureAwait(false);
        if ((int)uploadResponse.StatusCode == 409 && retryUploadConflict)
        {
            await PushSignedAsync(
                endpoint,
                deviceKey,
                identity,
                snapshot,
                petAsset,
                retryUploadConflict: false,
                cancellationToken).ConfigureAwait(false);
            return;
        }
        if ((int)uploadResponse.StatusCode is not (201 or 204))
        {
            throw new HttpRequestException(
                $"OPL Fleet Gateway returned HTTP {(int)uploadResponse.StatusCode}.",
                inner: null,
                uploadResponse.StatusCode);
        }
    }
}
