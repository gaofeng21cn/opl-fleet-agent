using OPLFleetAgent.WindowsApp;

namespace OPLFleetAgent.Windows.Tests;

public sealed class WindowsUpdateManagerTests
{
    [Fact]
    public void DefaultConfigurationUsesHttpsAppcastAnd32ByteEd25519Key()
    {
        var config = WinSparkleConfiguration.CreateDefault(automaticCheckForUpdates: true);
        config.Validate();

        Assert.Equal(
            "https://github.com/gaofeng21cn/opl-fleet-agent/releases/latest/download/windows-appcast.xml",
            config.AppcastFeedUri.AbsoluteUri);
        Assert.Equal(WindowsProductIdentity.WinSparkleEd25519PublicKey, config.Ed25519PublicKey);
        Assert.Equal(32, Convert.FromBase64String(config.Ed25519PublicKey).Length);
        Assert.Equal("Feng Gao", config.CompanyName);
        Assert.Equal("OPL Fleet Agent", config.AppName);
        Assert.Equal(@"Software\OPL Fleet Agent\WinSparkle", config.RegistryPath);
        Assert.Equal(21_600, config.CheckIntervalSeconds);
        Assert.True(config.AutomaticCheckForUpdates);
    }

    [Fact]
    public void ConfigurationRejectsInsecureFeedAndInvalidEd25519Key()
    {
        var valid = WinSparkleConfiguration.CreateDefault(appVersion: "0.2.54");

        var httpFeed = valid with { AppcastFeedUri = new Uri("http://example.com/windows-appcast.xml") };
        Assert.Throws<InvalidOperationException>(() => httpFeed.Validate());

        var badBase64 = valid with { Ed25519PublicKey = "not-valid-base64!!!" };
        Assert.Throws<InvalidOperationException>(() => badBase64.Validate());

        var wrongLength = valid with { Ed25519PublicKey = Convert.ToBase64String(new byte[16]) };
        Assert.Throws<InvalidOperationException>(() => wrongLength.Validate());

        var shortInterval = valid with { CheckIntervalSeconds = 60 };
        Assert.Throws<InvalidOperationException>(() => shortInterval.Validate());
    }

    [Fact]
    public void StartConfiguresAndInitializesBackendOnce()
    {
        var backend = new FakeWinSparkleBackend();
        var config = WinSparkleConfiguration.CreateDefault(automaticCheckForUpdates: true, appVersion: "0.2.54");
        using var manager = new WindowsUpdateManager(config, backend);

        manager.Start();
        manager.Start();

        Assert.True(manager.IsAvailable);
        Assert.Equal(1, backend.ConfigureCalls);
        Assert.Equal(1, backend.InitializeCalls);
        Assert.Equal(config, backend.LastConfiguration);
    }

    [Fact]
    public void StartHandlesMissingWinSparkleDllWithoutCrashing()
    {
        var backend = new FakeWinSparkleBackend
        {
            ThrowOnConfigure = new DllNotFoundException("Unable to load DLL 'WinSparkle.dll'"),
        };
        using var manager = new WindowsUpdateManager(
            WinSparkleConfiguration.CreateDefault(appVersion: "0.2.54"),
            backend);

        manager.Start();

        Assert.False(manager.IsAvailable);
        Assert.Equal(AppUpdateKind.Failed, manager.State.Kind);
        Assert.Contains("WinSparkle.dll", manager.State.Message);
    }

    [Fact]
    public void ManualCheckAndCallbacksDriveUpdateStates()
    {
        var backend = new FakeWinSparkleBackend();
        using var manager = new WindowsUpdateManager(
            WinSparkleConfiguration.CreateDefault(appVersion: "0.2.54"),
            backend);
        manager.Start();

        manager.CheckForUpdatesWithUi();
        Assert.Equal(1, backend.CheckWithUiCalls);
        Assert.Equal(AppUpdateKind.Checking, manager.State.Kind);

        backend.Callbacks!.DidFindUpdate();
        Assert.Equal(AppUpdateKind.Available, manager.State.Kind);

        backend.Callbacks.UpdateCancelled();
        Assert.Equal(AppUpdateKind.Idle, manager.State.Kind);

        manager.CheckForUpdatesWithUi();
        backend.Callbacks.DidNotFindUpdate();
        Assert.Equal(AppUpdateKind.UpToDate, manager.State.Kind);
        Assert.Equal("已是最新版本", manager.State.Message);

        backend.Callbacks.UpdateDismissed();
        Assert.Equal(AppUpdateKind.Idle, manager.State.Kind);
    }

    [Fact]
    public void ManualErrorIsVisibleWhileBackgroundErrorStaysQuiet()
    {
        var backend = new FakeWinSparkleBackend();
        using var manager = new WindowsUpdateManager(
            WinSparkleConfiguration.CreateDefault(appVersion: "0.2.54"),
            backend);
        manager.Start();

        manager.CheckForUpdatesInBackground();
        Assert.Equal(1, backend.CheckWithoutUiCalls);
        backend.Callbacks!.UpdateError();
        Assert.Equal(AppUpdateKind.Idle, manager.State.Kind);

        manager.CheckForUpdatesWithUi();
        backend.Callbacks.UpdateError();
        Assert.Equal(AppUpdateKind.Failed, manager.State.Kind);
    }

    [Fact]
    public void ShutdownCallbackTransitionsToRestartingAndSignalsHost()
    {
        var backend = new FakeWinSparkleBackend();
        using var manager = new WindowsUpdateManager(
            WinSparkleConfiguration.CreateDefault(appVersion: "0.2.54"),
            backend);
        var shutdownCount = 0;
        manager.ShutdownRequested += (_, _) => shutdownCount++;
        manager.Start();

        Assert.True(backend.Callbacks!.CanShutdown());

        backend.Callbacks.ShutdownRequested();

        Assert.Equal(1, shutdownCount);
        Assert.Equal(AppUpdateKind.Restarting, manager.State.Kind);
    }

    [Fact]
    public void AutomaticCheckTogglePropagatesToBackend()
    {
        var backend = new FakeWinSparkleBackend();
        using var manager = new WindowsUpdateManager(
            WinSparkleConfiguration.CreateDefault(automaticCheckForUpdates: true, appVersion: "0.2.54"),
            backend);
        manager.Start();

        manager.SetAutomaticCheckForUpdates(false);
        Assert.False(manager.AutomaticCheckForUpdates);
        Assert.False(backend.AutomaticCheckForUpdates);

        manager.SetAutomaticCheckForUpdates(true);
        Assert.True(manager.AutomaticCheckForUpdates);
        Assert.True(backend.AutomaticCheckForUpdates);
    }

    [Fact]
    public void DisposeCleansUpBackendAndDeclinesShutdown()
    {
        var backend = new FakeWinSparkleBackend();
        var manager = new WindowsUpdateManager(
            WinSparkleConfiguration.CreateDefault(appVersion: "0.2.54"),
            backend);
        manager.Start();
        var callbacks = backend.Callbacks!;

        manager.Dispose();

        Assert.True(backend.Disposed);
        Assert.False(callbacks.CanShutdown());
    }

    [Fact]
    public void NativeWinSparkleDllAcceptsConfiguredEd25519KeyAndRejectsInvalidKey()
    {
        var dllPath = Path.Combine(AppContext.BaseDirectory, WindowsProductIdentity.WinSparkleDllName);
        var isCi = string.Equals(
            Environment.GetEnvironmentVariable("CI"),
            "true",
            StringComparison.OrdinalIgnoreCase);
        if (!File.Exists(dllPath) && !isCi)
        {
            return;
        }

        Assert.True(
            File.Exists(dllPath),
            $"Expected native {WindowsProductIdentity.WinSparkleDllName} in test output directory ({dllPath}). Run windows/scripts/fetch-winsparkle.ps1 first.");

        Assert.True(NativeWinSparkleBackend.TrySetEdDsaPublicKey(
            WindowsProductIdentity.WinSparkleEd25519PublicKey));
        Assert.False(NativeWinSparkleBackend.TrySetEdDsaPublicKey("invalid-key"));
        Assert.False(NativeWinSparkleBackend.TrySetEdDsaPublicKey(Convert.ToBase64String(new byte[16])));
    }

    private sealed class FakeWinSparkleBackend : IWinSparkleBackend
    {
        public Exception? ThrowOnConfigure { get; set; }

        public int ConfigureCalls { get; private set; }

        public int InitializeCalls { get; private set; }

        public int CheckWithUiCalls { get; private set; }

        public int CheckWithoutUiCalls { get; private set; }

        public bool AutomaticCheckForUpdates { get; private set; }

        public bool Disposed { get; private set; }

        public WinSparkleConfiguration? LastConfiguration { get; private set; }

        public WinSparkleCallbacks? Callbacks { get; private set; }

        public void Configure(WinSparkleConfiguration configuration, WinSparkleCallbacks callbacks)
        {
            if (ThrowOnConfigure is not null)
            {
                throw ThrowOnConfigure;
            }

            ConfigureCalls++;
            LastConfiguration = configuration;
            AutomaticCheckForUpdates = configuration.AutomaticCheckForUpdates;
            Callbacks = callbacks;
        }

        public void Initialize() => InitializeCalls++;

        public void SetAutomaticCheckForUpdates(bool enabled) => AutomaticCheckForUpdates = enabled;

        public bool GetAutomaticCheckForUpdates() => AutomaticCheckForUpdates;

        public void CheckForUpdatesWithUi() => CheckWithUiCalls++;

        public void CheckForUpdatesWithoutUi() => CheckWithoutUiCalls++;

        public void Cleanup()
        {
        }

        public void Dispose() => Disposed = true;
    }
}
