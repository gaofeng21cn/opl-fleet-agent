using OPLFleetAgent.Core;
using System.Net;

namespace OPLFleetAgent.WindowsApp;

internal enum AmbientOpsConnectionKind
{
    Disabled,
    Discovering,
    Ready,
    NeedsToken,
    Pairing,
    Pushing,
    Live,
    Failed,
}

internal sealed record AmbientOpsConnectionStatus(
    AmbientOpsConnectionKind Kind,
    string Message,
    Uri? Endpoint = null,
    Uri? ApprovalUri = null);

internal sealed class AmbientOpsCoordinator : IDisposable
{
    internal static readonly TimeSpan PairingCapabilityRefreshInterval =
        TimeSpan.FromSeconds(30);
    internal static readonly TimeSpan HostNetworkSampleInterval =
        TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan PushInterval = TimeSpan.FromSeconds(10);
    private readonly AmbientOpsDiscovery discovery = new();
    private readonly AmbientOpsPushClient pushClient = new();
    private readonly AmbientOpsPairingClient pairingClient = new();
    private readonly AmbientOpsPetTracker petTracker = new();
    private readonly HostCpuTelemetrySampler cpuSampler = new();
    private readonly CancellationTokenSource networkTelemetryCancellation = new();
    private readonly object networkTelemetryLock = new();
    private readonly Task networkTelemetryTask;
    private IReadOnlyList<AmbientOpsService> discoveredServices = [];
    private AmbientOpsService? selectedService;
    private AmbientOpsServiceSelector? selector;
    private AmbientOpsAgentSnapshot? lastSuccessfulSnapshot;
    private AmbientOpsPetAssetCatalog? petAssetCatalog;
    private DateTimeOffset? lastDiscovery;
    private DateTimeOffset? lastPush;
    private AmbientOpsPairingSession? pairingSession;
    private Uri? pairingEndpoint;
    private string configurationKey = string.Empty;
    private HostNetworkTelemetry? latestNetworkTelemetry;
    private bool disposed;

    public AmbientOpsCoordinator()
    {
        networkTelemetryTask = SampleNetworkTelemetryAsync(networkTelemetryCancellation.Token);
    }

    public AmbientOpsConnectionStatus Connection { get; private set; } = new(
        AmbientOpsConnectionKind.Discovering,
        "正在连接");

    public async Task PushIfDueAsync(
        UsageSnapshot usage,
        AppSettings settings,
        string codexHome,
        bool force,
        CancellationToken cancellationToken)
    {
        if (!settings.AmbientEnabled)
        {
            SetStatus(AmbientOpsConnectionKind.Disabled, "未启用");
            return;
        }

        ResetIfConfigurationChanged(settings, codexHome);
        Uri endpoint;
        string destination;

        if (!settings.AutoDiscover)
        {
            if (!Uri.TryCreate(settings.ManualUrl, UriKind.Absolute, out var manualEndpoint) ||
                manualEndpoint.Scheme is not ("http" or "https"))
            {
                SetStatus(AmbientOpsConnectionKind.Failed, "请输入有效的 HTTP(S) 地址");
                return;
            }
            endpoint = manualEndpoint;
            destination = endpoint.Host;
        }
        else
        {
            if (selectedService is { SupportsPairing: false } staleService &&
                ShouldRefreshPairingCapability(
                    settings.Token,
                    staleService,
                    lastDiscovery,
                    DateTimeOffset.Now))
            {
                discoveredServices = [];
                selectedService = null;
            }
            if (discoveredServices.Count == 0)
            {
                SetStatus(AmbientOpsConnectionKind.Discovering, "正在自动发现");
                discoveredServices = await discovery.DiscoverAsync(cancellationToken)
                    .ConfigureAwait(false);
                lastDiscovery = DateTimeOffset.Now;
                selector!.ResetFailures();
            }
            selectedService ??= selector!.Select(discoveredServices);
            if (selectedService is null)
            {
                SetStatus(AmbientOpsConnectionKind.Failed, "未发现兼容的 OPL Fleet Gateway");
                return;
            }
            endpoint = selectedService.Endpoint;
            destination = selectedService.Name;
        }

        var supportsPairing = settings.AutoDiscover
            ? selectedService!.SupportsPairing
            : true;
        if (string.IsNullOrWhiteSpace(settings.Token) && !supportsPairing)
        {
            SetStatus(
                AmbientOpsConnectionKind.NeedsToken,
                $"已发现 {destination} · 需要推送令牌",
                endpoint);
            return;
        }
        if (!force && lastPush is { } pushedAt && DateTimeOffset.Now - pushedAt < PushInterval)
        {
            return;
        }

        var identity = new AmbientOpsMachineIdentity(
            settings.MachineId,
            settings.MachineName,
            "Windows");
        var petAsset = settings.PetEnabled
            ? petAssetCatalog!.CurrentAsset()
            : null;
        var pet = petAsset is not null
            ? petTracker.Snapshot(petAsset.Definition, usage)
            : null;
        var payload = AmbientOpsAgentSnapshot.FromUsage(
            usage,
            identity,
            fallback: lastSuccessfulSnapshot,
            cpuPercent: cpuSampler.SampleCpuPercent(),
            network: CurrentNetworkTelemetry(),
            pet: pet);

        try
        {
            if (string.IsNullOrWhiteSpace(settings.Token))
            {
                if (!await PushSignedOrPairAsync(
                    endpoint,
                    payload,
                    identity,
                    settings,
                    petAsset,
                    force,
                    cancellationToken).ConfigureAwait(false))
                {
                    return;
                }
            }
            else
            {
                await PushAsync(
                    endpoint,
                    payload,
                    identity,
                    settings.Token,
                    petAsset,
                    cancellationToken).ConfigureAwait(false);
            }
        }
        catch (HttpRequestException error) when (
            error.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            SetStatus(
                AmbientOpsConnectionKind.Failed,
                $"推送被拒绝 · HTTP {(int)error.StatusCode.Value}",
                endpoint);
            return;
        }
        catch (Exception error) when (
            settings.AutoDiscover &&
            !cancellationToken.IsCancellationRequested &&
            error is HttpRequestException or TaskCanceledException)
        {
            selector!.RecordPushFailure(selectedService!);
            var fallback = selector.Select(discoveredServices);
            if (fallback is null)
            {
                discoveredServices = [];
                selectedService = null;
                SetStatus(AmbientOpsConnectionKind.Failed, $"推送失败 · {error.Message}");
                return;
            }
            selectedService = fallback;
            try
            {
                if (string.IsNullOrWhiteSpace(settings.Token))
                {
                    if (!fallback.SupportsPairing ||
                        !await PushSignedOrPairAsync(
                            fallback.Endpoint,
                            payload,
                            identity,
                            settings,
                            petAsset,
                            force,
                            cancellationToken).ConfigureAwait(false))
                    {
                        return;
                    }
                }
                else
                {
                    await PushAsync(
                        fallback.Endpoint,
                        payload,
                        identity,
                        settings.Token,
                        petAsset,
                        cancellationToken).ConfigureAwait(false);
                }
            }
            catch (Exception fallbackError) when (
                !cancellationToken.IsCancellationRequested &&
                fallbackError is HttpRequestException or TaskCanceledException)
            {
                SetStatus(
                    AmbientOpsConnectionKind.Failed,
                    $"推送失败 · {fallbackError.Message}",
                    fallback.Endpoint);
                return;
            }
            endpoint = fallback.Endpoint;
            destination = fallback.Name;
        }
        catch (Exception error) when (
            !cancellationToken.IsCancellationRequested &&
            error is HttpRequestException or TaskCanceledException)
        {
            SetStatus(
                AmbientOpsConnectionKind.Failed,
                $"推送失败 · {error.Message}",
                endpoint);
            return;
        }
        RecordSuccess(usage, payload, destination, endpoint);
    }

    internal static bool ShouldRefreshPairingCapability(
        string token,
        AmbientOpsService service,
        DateTimeOffset? discoveredAt,
        DateTimeOffset now) =>
        string.IsNullOrWhiteSpace(token) &&
        !service.SupportsPairing &&
        discoveredAt is { } timestamp &&
        now - timestamp >= PairingCapabilityRefreshInterval;

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        networkTelemetryCancellation.Cancel();
        try
        {
            networkTelemetryTask.GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
            // Expected while the tray application is closing.
        }
        networkTelemetryCancellation.Dispose();
    }

    private async Task SampleNetworkTelemetryAsync(CancellationToken cancellationToken)
    {
        var sampler = new HostNetworkTelemetrySampler();
        _ = sampler.Sample();
        using var timer = new PeriodicTimer(HostNetworkSampleInterval);
        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
            {
                if (sampler.Sample() is not { } telemetry)
                {
                    continue;
                }
                lock (networkTelemetryLock)
                {
                    latestNetworkTelemetry = telemetry;
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Normal shutdown.
        }
    }

    private HostNetworkTelemetry? CurrentNetworkTelemetry()
    {
        lock (networkTelemetryLock)
        {
            return latestNetworkTelemetry;
        }
    }

    private async Task PushAsync(
        Uri endpoint,
        AmbientOpsAgentSnapshot payload,
        AmbientOpsMachineIdentity identity,
        string token,
        AmbientOpsPetAsset? petAsset,
        CancellationToken cancellationToken)
    {
        SetStatus(AmbientOpsConnectionKind.Pushing, $"正在推送到 {endpoint.Host}", endpoint);
        await pushClient.PushAsync(
            endpoint, token, identity, payload, petAsset, cancellationToken)
            .ConfigureAwait(false);
    }

    private async Task<bool> PushSignedOrPairAsync(
        Uri endpoint,
        AmbientOpsAgentSnapshot payload,
        AmbientOpsMachineIdentity identity,
        AppSettings settings,
        AmbientOpsPetAsset? petAsset,
        bool force,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(settings.DevicePrivateKey))
        {
            SetStatus(
                AmbientOpsConnectionKind.Failed,
                "无法创建本机安全配对密钥",
                endpoint);
            return false;
        }

        using var deviceKey = AmbientOpsDeviceKey.Import(settings.DevicePrivateKey);
        try
        {
            SetStatus(AmbientOpsConnectionKind.Pushing, $"正在安全推送到 {endpoint.Host}", endpoint);
            await pushClient.PushSignedAsync(
                endpoint,
                deviceKey,
                identity,
                payload,
                petAsset,
                cancellationToken).ConfigureAwait(false);
            pairingSession = null;
            pairingEndpoint = endpoint;
            return true;
        }
        catch (HttpRequestException error) when (
            error.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
        {
            if (pairingEndpoint != endpoint)
            {
                pairingSession = null;
                pairingEndpoint = endpoint;
            }
            if (pairingSession is { IsPending: true })
            {
                try
                {
                    pairingSession = await pairingClient.GetAsync(
                        endpoint,
                        pairingSession.RequestId,
                        cancellationToken).ConfigureAwait(false);
                }
                catch (HttpRequestException pollError) when (pollError.StatusCode == HttpStatusCode.NotFound)
                {
                    pairingSession = null;
                }
            }
            if (pairingSession is { Status: "rejected" } && !force)
            {
                SetStatus(
                    AmbientOpsConnectionKind.Failed,
                    "配对请求已拒绝 · 手动刷新可重试",
                    endpoint);
                return false;
            }
            if (pairingSession is null || !pairingSession.IsPending && !pairingSession.IsApproved)
            {
                try
                {
                    pairingSession = await pairingClient.BeginAsync(
                        endpoint,
                        identity,
                        deviceKey,
                        cancellationToken: cancellationToken).ConfigureAwait(false);
                }
                catch (HttpRequestException pairingError) when (
                    pairingError.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.ServiceUnavailable)
                {
                    SetStatus(
                        AmbientOpsConnectionKind.NeedsToken,
                        "此 OPL Fleet Gateway 版本不支持安全配对 · 请升级或使用兼容令牌",
                        endpoint);
                    return false;
                }
            }
            if (pairingSession.IsApproved)
            {
                await pushClient.PushSignedAsync(
                    endpoint,
                    deviceKey,
                    identity,
                    payload,
                    petAsset,
                    cancellationToken).ConfigureAwait(false);
                pairingSession = null;
                return true;
            }
            var approvalUri = AmbientOpsPairingClient.ApprovalUri(endpoint, pairingSession);
            SetStatus(
                AmbientOpsConnectionKind.Pairing,
                $"等待批准 · 配对码 {deviceKey.VerificationCode}",
                endpoint,
                approvalUri);
            return false;
        }
    }

    private void RecordSuccess(
        UsageSnapshot usage,
        AmbientOpsAgentSnapshot payload,
        string destination,
        Uri endpoint)
    {
        if (usage.Status == CollectionStatus.Ready)
        {
            lastSuccessfulSnapshot = payload;
        }
        lastPush = DateTimeOffset.Now;
        SetStatus(AmbientOpsConnectionKind.Live, $"{destination} · 已连接", endpoint);
    }

    private void ResetIfConfigurationChanged(AppSettings settings, string codexHome)
    {
        var nextKey = string.Join('|',
            settings.AutoDiscover,
            settings.ManualUrl,
            settings.PreferredInstanceId,
            settings.MachineId,
            codexHome);
        if (nextKey == configurationKey)
        {
            return;
        }
        configurationKey = nextKey;
        selector = new AmbientOpsServiceSelector(settings.PreferredInstanceId);
        discoveredServices = [];
        selectedService = null;
        lastDiscovery = null;
        petAssetCatalog = new AmbientOpsPetAssetCatalog(codexHome);
        pairingSession = null;
        pairingEndpoint = null;
    }

    private void SetStatus(
        AmbientOpsConnectionKind kind,
        string message,
        Uri? endpoint = null,
        Uri? approvalUri = null) =>
        Connection = new AmbientOpsConnectionStatus(kind, message, endpoint, approvalUri);
}
