using System.Runtime.InteropServices;

namespace OPLFleetAgent.WindowsApp;

internal enum AppUpdateKind
{
    Idle,
    Checking,
    UpToDate,
    Available,
    Restarting,
    Failed,
}

internal sealed record AppUpdateState(
    AppUpdateKind Kind,
    string? Message = null)
{
    public static AppUpdateState Idle { get; } = new(AppUpdateKind.Idle);

    public bool IsBusy => Kind is AppUpdateKind.Checking or AppUpdateKind.Restarting;
}

internal sealed record WinSparkleConfiguration(
    Uri AppcastFeedUri,
    string Ed25519PublicKey,
    string CompanyName,
    string AppName,
    string AppVersion,
    string RegistryPath,
    int CheckIntervalSeconds,
    bool AutomaticCheckForUpdates)
{
    public const int MinimumCheckIntervalSeconds = 3_600;

    public static WinSparkleConfiguration CreateDefault(
        bool automaticCheckForUpdates = true,
        string? appVersion = null) => new(
            new Uri(WindowsProductIdentity.WindowsAppcastFeedUrl),
            WindowsProductIdentity.WinSparkleEd25519PublicKey,
            WindowsProductIdentity.CompanyName,
            WindowsProductIdentity.ProductName,
            appVersion ?? ReadCurrentVersion(),
            WindowsProductIdentity.WinSparkleRegistryPath,
            WindowsProductIdentity.UpdateCheckIntervalSeconds,
            automaticCheckForUpdates);

    public void Validate()
    {
        if (!AppcastFeedUri.IsAbsoluteUri ||
            !string.Equals(AppcastFeedUri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("WinSparkle appcast feed URL must use HTTPS.");
        }

        if (!IsValidEd25519PublicKey(Ed25519PublicKey))
        {
            throw new InvalidOperationException("WinSparkle Ed25519 public key must be a 32-byte base64 value.");
        }

        if (string.IsNullOrWhiteSpace(CompanyName) ||
            string.IsNullOrWhiteSpace(AppName) ||
            string.IsNullOrWhiteSpace(AppVersion) ||
            string.IsNullOrWhiteSpace(RegistryPath))
        {
            throw new InvalidOperationException("WinSparkle application metadata and registry path are required.");
        }

        if (CheckIntervalSeconds < MinimumCheckIntervalSeconds)
        {
            throw new InvalidOperationException(
                $"WinSparkle check interval must be at least {MinimumCheckIntervalSeconds} seconds.");
        }
    }

    public static bool IsValidEd25519PublicKey(string? base64PublicKey)
    {
        if (string.IsNullOrWhiteSpace(base64PublicKey))
        {
            return false;
        }

        try
        {
            return Convert.FromBase64String(base64PublicKey.Trim()).Length == 32;
        }
        catch (FormatException)
        {
            return false;
        }
    }

    public static string ReadCurrentVersion()
    {
        var version = typeof(WindowsUpdateManager).Assembly.GetName().Version;
        if (version is null)
        {
            return "0.0.0";
        }

        return $"{Math.Max(0, version.Major)}.{Math.Max(0, version.Minor)}.{Math.Max(0, version.Build)}";
    }
}

internal sealed record WinSparkleCallbacks(
    Func<bool> CanShutdown,
    Action ShutdownRequested,
    Action DidFindUpdate,
    Action DidNotFindUpdate,
    Action UpdateError,
    Action UpdateCancelled,
    Action UpdateSkipped,
    Action UpdatePostponed,
    Action UpdateDismissed);

internal interface IWinSparkleBackend : IDisposable
{
    void Configure(WinSparkleConfiguration configuration, WinSparkleCallbacks callbacks);

    void Initialize();

    void SetAutomaticCheckForUpdates(bool enabled);

    bool GetAutomaticCheckForUpdates();

    void CheckForUpdatesWithUi();

    void CheckForUpdatesWithoutUi();

    void Cleanup();
}

internal sealed class NativeWinSparkleBackend : IWinSparkleBackend
{
    private readonly object lifecycleLock = new();
    private bool initialized;
    private bool disposed;

    // Keep unmanaged delegate references alive for the full lifetime of WinSparkle.
    private CanShutdownNativeCallback? canShutdownDelegate;
    private VoidNativeCallback? shutdownRequestDelegate;
    private VoidNativeCallback? didFindUpdateDelegate;
    private VoidNativeCallback? didNotFindUpdateDelegate;
    private VoidNativeCallback? errorDelegate;
    private VoidNativeCallback? cancelledDelegate;
    private VoidNativeCallback? skippedDelegate;
    private VoidNativeCallback? postponedDelegate;
    private VoidNativeCallback? dismissedDelegate;

    public static bool TrySetEdDsaPublicKey(string publicKey) =>
        NativeMethods.win_sparkle_set_eddsa_public_key(publicKey) != 0;

    public void Configure(WinSparkleConfiguration configuration, WinSparkleCallbacks callbacks)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        configuration.Validate();

        NativeMethods.win_sparkle_set_appcast_url(configuration.AppcastFeedUri.AbsoluteUri);
        if (NativeMethods.win_sparkle_set_eddsa_public_key(configuration.Ed25519PublicKey.Trim()) == 0)
        {
            throw new InvalidOperationException("WinSparkle rejected the configured Ed25519 public key.");
        }

        NativeMethods.win_sparkle_set_app_details(
            configuration.CompanyName,
            configuration.AppName,
            configuration.AppVersion);
        NativeMethods.win_sparkle_set_app_build_version(configuration.AppVersion);
        NativeMethods.win_sparkle_set_registry_path(configuration.RegistryPath);
        NativeMethods.win_sparkle_set_update_check_interval(configuration.CheckIntervalSeconds);
        NativeMethods.win_sparkle_set_automatic_check_for_updates(
            configuration.AutomaticCheckForUpdates ? 1 : 0);

        canShutdownDelegate = () => callbacks.CanShutdown() ? 1 : 0;
        shutdownRequestDelegate = () => callbacks.ShutdownRequested();
        didFindUpdateDelegate = () => callbacks.DidFindUpdate();
        didNotFindUpdateDelegate = () => callbacks.DidNotFindUpdate();
        errorDelegate = () => callbacks.UpdateError();
        cancelledDelegate = () => callbacks.UpdateCancelled();
        skippedDelegate = () => callbacks.UpdateSkipped();
        postponedDelegate = () => callbacks.UpdatePostponed();
        dismissedDelegate = () => callbacks.UpdateDismissed();

        NativeMethods.win_sparkle_set_can_shutdown_callback(canShutdownDelegate);
        NativeMethods.win_sparkle_set_shutdown_request_callback(shutdownRequestDelegate);
        NativeMethods.win_sparkle_set_did_find_update_callback(didFindUpdateDelegate);
        NativeMethods.win_sparkle_set_did_not_find_update_callback(didNotFindUpdateDelegate);
        NativeMethods.win_sparkle_set_error_callback(errorDelegate);
        NativeMethods.win_sparkle_set_update_cancelled_callback(cancelledDelegate);
        NativeMethods.win_sparkle_set_update_skipped_callback(skippedDelegate);
        NativeMethods.win_sparkle_set_update_postponed_callback(postponedDelegate);
        NativeMethods.win_sparkle_set_update_dismissed_callback(dismissedDelegate);
    }

    public void Initialize()
    {
        lock (lifecycleLock)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (initialized)
            {
                return;
            }

            NativeMethods.win_sparkle_init();
            initialized = true;
        }
    }

    public void SetAutomaticCheckForUpdates(bool enabled)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        NativeMethods.win_sparkle_set_automatic_check_for_updates(enabled ? 1 : 0);
    }

    public bool GetAutomaticCheckForUpdates()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        return NativeMethods.win_sparkle_get_automatic_check_for_updates() != 0;
    }

    public void CheckForUpdatesWithUi()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        NativeMethods.win_sparkle_check_update_with_ui();
    }

    public void CheckForUpdatesWithoutUi()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        NativeMethods.win_sparkle_check_update_without_ui();
    }

    public void Cleanup()
    {
        lock (lifecycleLock)
        {
            if (!initialized)
            {
                return;
            }

            NativeMethods.win_sparkle_cleanup();
            NativeMethods.win_sparkle_set_can_shutdown_callback(null);
            NativeMethods.win_sparkle_set_shutdown_request_callback(null);
            NativeMethods.win_sparkle_set_did_find_update_callback(null);
            NativeMethods.win_sparkle_set_did_not_find_update_callback(null);
            NativeMethods.win_sparkle_set_error_callback(null);
            NativeMethods.win_sparkle_set_update_cancelled_callback(null);
            NativeMethods.win_sparkle_set_update_skipped_callback(null);
            NativeMethods.win_sparkle_set_update_postponed_callback(null);
            NativeMethods.win_sparkle_set_update_dismissed_callback(null);

            canShutdownDelegate = null;
            shutdownRequestDelegate = null;
            didFindUpdateDelegate = null;
            didNotFindUpdateDelegate = null;
            errorDelegate = null;
            cancelledDelegate = null;
            skippedDelegate = null;
            postponedDelegate = null;
            dismissedDelegate = null;
            initialized = false;
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        Cleanup();
        disposed = true;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int CanShutdownNativeCallback();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void VoidNativeCallback();

    private static class NativeMethods
    {
        private const string DllName = WindowsProductIdentity.WinSparkleDllName;

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_init();

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_cleanup();

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_appcast_url(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string url);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int win_sparkle_set_eddsa_public_key(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string pubkey);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_app_details(
            [MarshalAs(UnmanagedType.LPWStr)] string companyName,
            [MarshalAs(UnmanagedType.LPWStr)] string appName,
            [MarshalAs(UnmanagedType.LPWStr)] string appVersion);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_app_build_version(
            [MarshalAs(UnmanagedType.LPWStr)] string build);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_registry_path(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string path);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_automatic_check_for_updates(int state);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern int win_sparkle_get_automatic_check_for_updates();

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_update_check_interval(int interval);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_check_update_with_ui();

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_check_update_without_ui();

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_can_shutdown_callback(
            CanShutdownNativeCallback? callback);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_shutdown_request_callback(
            VoidNativeCallback? callback);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_did_find_update_callback(
            VoidNativeCallback? callback);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_did_not_find_update_callback(
            VoidNativeCallback? callback);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_error_callback(
            VoidNativeCallback? callback);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_update_cancelled_callback(
            VoidNativeCallback? callback);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_update_skipped_callback(
            VoidNativeCallback? callback);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_update_postponed_callback(
            VoidNativeCallback? callback);

        [DllImport(DllName, CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
        public static extern void win_sparkle_set_update_dismissed_callback(
            VoidNativeCallback? callback);
    }
}

internal sealed class WindowsUpdateManager : IDisposable
{
    private readonly IWinSparkleBackend backend;
    private readonly object gate = new();
    private CancellationTokenSource? statusReset;
    private bool initialized;
    private bool manualCheckActive;
    private bool disposed;

    public WindowsUpdateManager(
        WinSparkleConfiguration? configuration = null,
        IWinSparkleBackend? backend = null)
    {
        Configuration = configuration ?? WinSparkleConfiguration.CreateDefault();
        Configuration.Validate();
        this.backend = backend ?? new NativeWinSparkleBackend();
    }

    public event EventHandler<AppUpdateState>? StateChanged;

    public event EventHandler? ShutdownRequested;

    public WinSparkleConfiguration Configuration { get; private set; }

    public AppUpdateState State { get; private set; } = AppUpdateState.Idle;

    public bool IsAvailable { get; private set; }

    public bool AutomaticCheckForUpdates => Configuration.AutomaticCheckForUpdates;

    public void Start()
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (initialized)
            {
                return;
            }

            try
            {
                backend.Configure(Configuration, CreateCallbacks());
                backend.Initialize();
                initialized = true;
                IsAvailable = true;
            }
            catch (Exception error) when (
                error is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException)
            {
                IsAvailable = false;
                State = new(AppUpdateKind.Failed, "未能加载 WinSparkle.dll，应用内自动更新暂不可用。");
            }
        }

        if (!IsAvailable)
        {
            StateChanged?.Invoke(this, State);
        }
    }

    public void CheckForUpdatesWithUi()
    {
        Start();
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!IsAvailable)
            {
                return;
            }

            CancelStatusResetLocked();
            manualCheckActive = true;
            State = new(AppUpdateKind.Checking);
        }

        StateChanged?.Invoke(this, State);
        backend.CheckForUpdatesWithUi();
    }

    public void CheckForUpdatesInBackground()
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!initialized || !IsAvailable)
            {
                return;
            }

            manualCheckActive = false;
        }

        backend.CheckForUpdatesWithoutUi();
    }

    public void SetAutomaticCheckForUpdates(bool enabled)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            Configuration = Configuration with { AutomaticCheckForUpdates = enabled };
            if (initialized && IsAvailable)
            {
                backend.SetAutomaticCheckForUpdates(enabled);
            }
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            disposed = true;
            CancelStatusResetLocked();
        }

        backend.Dispose();
    }

    private WinSparkleCallbacks CreateCallbacks() => new(
        CanShutdown: OnCanShutdown,
        ShutdownRequested: OnShutdownRequested,
        DidFindUpdate: OnDidFindUpdate,
        DidNotFindUpdate: OnDidNotFindUpdate,
        UpdateError: OnUpdateError,
        UpdateCancelled: OnUpdateEnded,
        UpdateSkipped: OnUpdateEnded,
        UpdatePostponed: OnUpdateEnded,
        UpdateDismissed: OnUpdateDismissed);

    private bool OnCanShutdown()
    {
        lock (gate)
        {
            return !disposed;
        }
    }

    private void OnShutdownRequested()
    {
        AppUpdateState next;
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            CancelStatusResetLocked();
            manualCheckActive = false;
            next = new(AppUpdateKind.Restarting, "更新已校验，正在启动安装程序");
            State = next;
        }

        StateChanged?.Invoke(this, next);
        ShutdownRequested?.Invoke(this, EventArgs.Empty);
    }

    private void OnDidFindUpdate()
    {
        AppUpdateState next;
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            CancelStatusResetLocked();
            manualCheckActive = false;
            next = new(AppUpdateKind.Available, "发现新版本，请在更新窗口中确认安装");
            State = next;
        }

        StateChanged?.Invoke(this, next);
    }

    private void OnDidNotFindUpdate()
    {
        AppUpdateState? next = null;
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            var wasManual = manualCheckActive;
            manualCheckActive = false;
            if (wasManual)
            {
                next = new(AppUpdateKind.UpToDate, "已是最新版本");
                State = next;
                ScheduleStatusResetLocked(TimeSpan.FromSeconds(4));
            }
            else if (State.Kind == AppUpdateKind.Checking)
            {
                next = AppUpdateState.Idle;
                State = next;
            }
        }

        if (next is not null)
        {
            StateChanged?.Invoke(this, next);
        }
    }

    private void OnUpdateError()
    {
        AppUpdateState? next = null;
        lock (gate)
        {
            if (disposed)
            {
                return;
            }

            var wasManual = manualCheckActive;
            manualCheckActive = false;
            if (wasManual)
            {
                next = new(AppUpdateKind.Failed, "检查更新失败，请确认网络连接。");
                State = next;
                ScheduleStatusResetLocked(TimeSpan.FromSeconds(8));
            }
            else if (State.Kind == AppUpdateKind.Checking)
            {
                next = AppUpdateState.Idle;
                State = next;
            }
        }

        if (next is not null)
        {
            StateChanged?.Invoke(this, next);
        }
    }

    private void OnUpdateEnded()
    {
        AppUpdateState next;
        lock (gate)
        {
            if (disposed || State.Kind == AppUpdateKind.Restarting)
            {
                return;
            }

            CancelStatusResetLocked();
            manualCheckActive = false;
            next = AppUpdateState.Idle;
            State = next;
        }

        StateChanged?.Invoke(this, next);
    }

    private void OnUpdateDismissed()
    {
        AppUpdateState? next = null;
        lock (gate)
        {
            if (disposed || State.Kind == AppUpdateKind.Restarting)
            {
                return;
            }

            CancelStatusResetLocked();
            manualCheckActive = false;
            if (State.Kind != AppUpdateKind.Available)
            {
                next = AppUpdateState.Idle;
                State = next;
            }
        }

        if (next is not null)
        {
            StateChanged?.Invoke(this, next);
        }
    }

    private void CancelStatusResetLocked()
    {
        statusReset?.Cancel();
        statusReset?.Dispose();
        statusReset = null;
    }

    private void ScheduleStatusResetLocked(TimeSpan delay)
    {
        CancelStatusResetLocked();
        statusReset = new CancellationTokenSource();
        var token = statusReset.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(delay, token);
                var notify = false;
                lock (gate)
                {
                    if (!token.IsCancellationRequested && !disposed)
                    {
                        State = AppUpdateState.Idle;
                        notify = true;
                    }
                }
                if (notify)
                {
                    StateChanged?.Invoke(this, AppUpdateState.Idle);
                }
            }
            catch (OperationCanceledException)
            {
                // Superseded by a newer updater event.
            }
        }, token);
    }
}
