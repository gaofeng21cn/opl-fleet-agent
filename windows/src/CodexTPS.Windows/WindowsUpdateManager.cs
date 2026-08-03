using System.Diagnostics;
using System.Net.Http.Headers;
using System.Reflection;

namespace CodexTPS.WindowsApp;

internal sealed class WindowsUpdateManager : IDisposable
{
    private static readonly Uri LatestReleasePage = new(
        "https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest");
    private static readonly Uri ReleaseDownloadRoot = new(
        "https://github.com/gaofeng21cn/opl-fleet-agent/releases/download/");
    private readonly HttpClient httpClient;
    private readonly bool ownsHttpClient;
    private readonly SemaphoreSlim operationLock = new(1, 1);
    private readonly string executablePath;
    private readonly string updateRoot;
    private readonly string resultPath;
    private CancellationTokenSource? statusReset;
    private bool disposed;

    public WindowsUpdateManager(
        HttpClient? httpClient = null,
        SemanticVersion? currentVersion = null,
        string? executablePath = null,
        string? updateRoot = null,
        string? resultPath = null)
    {
        ownsHttpClient = httpClient is null;
        this.httpClient = httpClient ?? CreateHttpClient();
        this.executablePath = executablePath ?? Application.ExecutablePath;
        this.updateRoot = updateRoot ?? WindowsProductIdentity.DefaultUpdateRoot;
        this.resultPath = resultPath ?? UpdateResultStore.DefaultPath;
        CurrentVersion = currentVersion ?? ReadCurrentVersion();

        var previousResult = UpdateResultStore.ReadAndDelete(this.resultPath);
        if (previousResult is null && resultPath is null)
        {
            previousResult = UpdateResultStore.ReadAndDelete(
                WindowsProductIdentity.LegacyUpdateResultPath);
        }
        State = previousResult switch
        {
            { Success: true } => new(
                AppUpdateKind.UpToDate,
                Message: $"已更新到 v{previousResult.Version}"),
            { Success: false } => new(
                AppUpdateKind.Failed,
                Message: previousResult.Error ?? "上次更新失败，当前版本已恢复运行。"),
            _ => AppUpdateState.Idle,
        };
        CleanupOldStagingDirectories();
    }

    public event EventHandler<AppUpdateState>? StateChanged;

    public SemanticVersion CurrentVersion { get; }

    public AppUpdateState State { get; private set; }

    public async Task CheckForUpdatesAsync(
        bool manual = true,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!await operationLock.WaitAsync(0, cancellationToken))
        {
            return;
        }

        statusReset?.Cancel();
        var previousState = State;
        SetState(new(AppUpdateKind.Checking));
        try
        {
            var release = await FetchLatestReleaseAsync(cancellationToken);
            if (release.Version > CurrentVersion)
            {
                SetState(new(AppUpdateKind.Available, release));
            }
            else
            {
                SetState(new(AppUpdateKind.UpToDate, Message: "已是最新版本"));
                ScheduleStatusReset(manual ? TimeSpan.FromSeconds(4) : TimeSpan.FromSeconds(2));
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            SetState(previousState);
        }
        catch (Exception error)
        {
            if (manual)
            {
                SetState(new(AppUpdateKind.Failed, Message: UserMessage(error)));
                ScheduleStatusReset(TimeSpan.FromSeconds(8), previousState);
            }
            else
            {
                SetState(previousState);
            }
        }
        finally
        {
            operationLock.Release();
        }
    }

    public async Task<bool> InstallAvailableUpdateAsync(
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (State is not { Kind: AppUpdateKind.Available, Release: { } release } ||
            !await operationLock.WaitAsync(0, cancellationToken))
        {
            return false;
        }

        statusReset?.Cancel();
        SetState(new(AppUpdateKind.Installing, release));
        string? stagingDirectory = null;
        try
        {
            stagingDirectory = Path.Combine(updateRoot, $"v{release.Version}-{Guid.NewGuid():N}");
            Directory.CreateDirectory(stagingDirectory);

            var installerName = Path.GetFileName(release.InstallerUri.AbsolutePath);
            var installerPath = Path.Combine(stagingDirectory, installerName);
            var checksum = await DownloadTextAsync(release.ChecksumUri, cancellationToken);
            var expectedSha256 = UpdatePackageVerifier.ParseExpectedSha256(checksum, installerName);
            await DownloadFileAsync(release.InstallerUri, installerPath, cancellationToken);
            await UpdatePackageVerifier.VerifyAsync(
                installerPath,
                expectedSha256,
                cancellationToken);

            var helperPath = Path.Combine(
                stagingDirectory,
                WindowsProductIdentity.UpdaterExecutableName);
            File.Copy(executablePath, helperPath, overwrite: true);
            var requestPath = Path.Combine(stagingDirectory, "update-request.json");
            var request = new UpdateWorkerRequest
            {
                ParentProcessId = Environment.ProcessId,
                CurrentExecutablePath = Path.GetFullPath(executablePath),
                InstallDirectory = Path.GetDirectoryName(Path.GetFullPath(executablePath))
                    ?? throw new InvalidOperationException("无法确定当前安装目录。"),
                InstallerPath = installerPath,
                ExpectedSha256 = expectedSha256,
                ExpectedVersion = release.Version.ToString(),
                ResultPath = resultPath,
                StagingDirectory = stagingDirectory,
            };
            request.Save(requestPath);

            var helper = Process.Start(new ProcessStartInfo(helperPath)
            {
                UseShellExecute = false,
                WorkingDirectory = stagingDirectory,
                ArgumentList = { WindowsUpdateWorker.ApplyArgument, requestPath },
            });
            if (helper is null)
            {
                throw new InvalidOperationException("无法启动 Windows 更新助手。");
            }

            SetState(new(
                AppUpdateKind.Restarting,
                release,
                "更新已验证，正在重新启动"));
            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            SetState(new(AppUpdateKind.Available, release));
            CleanupDirectory(stagingDirectory);
            return false;
        }
        catch (Exception error)
        {
            SetState(new(AppUpdateKind.Failed, release, UserMessage(error)));
            CleanupDirectory(stagingDirectory);
            return false;
        }
        finally
        {
            operationLock.Release();
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        statusReset?.Cancel();
        statusReset?.Dispose();
        operationLock.Dispose();
        if (ownsHttpClient)
        {
            httpClient.Dispose();
        }
    }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromMinutes(5),
        };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("OPL-Fleet-Agent", "1"));
        client.DefaultRequestHeaders.Accept.Add(
            new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }

    private static SemanticVersion ReadCurrentVersion()
    {
        var assemblyVersion = Assembly.GetEntryAssembly()?.GetName().Version;
        return assemblyVersion is null
            ? default
            : new SemanticVersion(
                Math.Max(0, assemblyVersion.Major),
                Math.Max(0, assemblyVersion.Minor),
                Math.Max(0, assemblyVersion.Build));
    }

    private async Task<AppRelease> FetchLatestReleaseAsync(CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Head, LatestReleasePage);
        using var response = await httpClient.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);
        response.EnsureSuccessStatusCode();
        return ReleaseFromPage(response.RequestMessage?.RequestUri);
    }

    private static AppRelease ReleaseFromPage(Uri? pageUri)
    {
        const string releasePagePrefix = "/gaofeng21cn/opl-fleet-agent/releases/tag/";
        if (pageUri is null ||
            pageUri.Scheme != Uri.UriSchemeHttps ||
            !string.Equals(pageUri.Host, "github.com", StringComparison.OrdinalIgnoreCase) ||
            !pageUri.AbsolutePath.StartsWith(releasePagePrefix, StringComparison.Ordinal))
        {
            throw new InvalidDataException("GitHub 返回了无效的版本信息。");
        }

        var tagName = pageUri.AbsolutePath[releasePagePrefix.Length..];
        if (tagName.Length == 0 ||
            tagName.Contains('/') ||
            !SemanticVersion.TryParse(tagName, out var version))
        {
            throw new InvalidDataException("GitHub 返回了无效的版本信息。");
        }

        var releaseRoot = new Uri(ReleaseDownloadRoot, $"{tagName}/");
        const string installerName = WindowsProductIdentity.InstallerAssetName;
        return new AppRelease(
            tagName,
            version,
            new Uri(releaseRoot, installerName),
            new Uri(releaseRoot, installerName + ".sha256"));
    }

    private async Task<string> DownloadTextAsync(
        Uri uri,
        CancellationToken cancellationToken)
    {
        using var response = await httpClient.GetAsync(uri, cancellationToken);
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync(cancellationToken);
    }

    private async Task DownloadFileAsync(
        Uri uri,
        string destination,
        CancellationToken cancellationToken)
    {
        using var response = await httpClient.GetAsync(
            uri,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);
        response.EnsureSuccessStatusCode();
        await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
        await using var target = new FileStream(
            destination,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            81_920,
            useAsync: true);
        await source.CopyToAsync(target, cancellationToken);
        await target.FlushAsync(cancellationToken);
    }

    private void ScheduleStatusReset(
        TimeSpan delay,
        AppUpdateState? nextState = null)
    {
        statusReset?.Cancel();
        statusReset?.Dispose();
        statusReset = new CancellationTokenSource();
        var token = statusReset.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(delay, token);
                if (!token.IsCancellationRequested && !disposed)
                {
                    SetState(nextState ?? AppUpdateState.Idle);
                }
            }
            catch (OperationCanceledException)
            {
                // A newer status superseded this transient result.
            }
        }, token);
    }

    private void SetState(AppUpdateState state)
    {
        State = state;
        StateChanged?.Invoke(this, state);
    }

    private void CleanupOldStagingDirectories()
    {
        if (!Directory.Exists(updateRoot))
        {
            return;
        }

        foreach (var directory in Directory.EnumerateDirectories(updateRoot))
        {
            try
            {
                if (Directory.GetLastWriteTimeUtc(directory) <
                    DateTime.UtcNow.Subtract(TimeSpan.FromDays(1)))
                {
                    Directory.Delete(directory, recursive: true);
                }
            }
            catch
            {
                // Locked updater copies are retried on a later launch.
            }
        }
    }

    private static void CleanupDirectory(string? directory)
    {
        if (directory is null)
        {
            return;
        }

        try
        {
            Directory.Delete(directory, recursive: true);
        }
        catch
        {
            // A failed cleanup must not hide the updater result.
        }
    }

    private static string UserMessage(Exception error) => error switch
    {
        HttpRequestException => "检查更新失败，请确认网络连接。",
        InvalidDataException invalidData => invalidData.Message,
        _ => $"更新失败：{error.Message}",
    };
}
