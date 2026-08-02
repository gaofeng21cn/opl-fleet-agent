using CodexTPS.Core;
using System.Diagnostics;

namespace CodexTPS.WindowsApp;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly AppSettingsStore settingsStore = new();
    private readonly AmbientOpsCoordinator ambientOps = new();
    private readonly WindowsUpdateManager updateManager = new();
    private readonly CancellationTokenSource cancellation = new();
    private readonly Icon applicationIcon;
    private readonly ContextMenuStrip trayMenu;
    private readonly ToolStripMenuItem updateMenuItem;
    private readonly NotifyIcon trayIcon;
    private readonly TaskbarReadoutForm taskbarReadout;
    private readonly System.Windows.Forms.Timer refreshTimer;
    private readonly System.Windows.Forms.Timer updateTimer;
    private readonly DashboardFormSlot dashboard;
    private Icon? rateIcon;
    private AppSettings settings;
    private SessionScanner scanner;
    private UsageSnapshot lastSnapshot = UsageSnapshot.Empty(
        DateTimeOffset.Now,
        CollectionStatus.SessionsDirectoryMissing);
    private bool refreshing;
    private bool exiting;
    private string? openedPairingUri;
    private string? notifiedUpdateTag;

    public TrayApplicationContext(bool showDashboard)
    {
        settings = settingsStore.Load();
        if (settings.AmbientEnabled &&
            settingsStore.LastError is null &&
            settingsStore.EnsureDeviceKey(settings))
        {
            settingsStore.Save(settings);
        }
        try
        {
            settings.StartWithWindows = StartupRegistration.IsEnabled();
        }
        catch
        {
            settings.StartWithWindows = false;
        }
        scanner = CreateScanner(settings);
        dashboard = new DashboardFormSlot(CreateDashboard);

        trayMenu = new ContextMenuStrip();
        trayMenu.Items.Add("打开", null, (_, _) => ShowDashboard());
        trayMenu.Items.Add("刷新", null, async (_, _) => await RefreshAsync(forcePush: true));
        updateMenuItem = new ToolStripMenuItem("检查更新");
        updateMenuItem.Click += async (_, _) => await RunUpdateActionAsync();
        trayMenu.Items.Add(updateMenuItem);
        trayMenu.Items.Add("设置", null, (_, _) => ShowSettings());
        trayMenu.Items.Add(new ToolStripSeparator());
        trayMenu.Items.Add("退出", null, (_, _) => ExitThread());
        applicationIcon = Icon.ExtractAssociatedIcon(Application.ExecutablePath)
            ?? (Icon)SystemIcons.Application.Clone();
        trayIcon = new NotifyIcon
        {
            Icon = applicationIcon,
            Text = "OPL Fleet Agent",
            Visible = true,
            ContextMenuStrip = trayMenu,
        };
        trayIcon.MouseClick += (_, eventArgs) =>
        {
            if (eventArgs.Button == MouseButtons.Left)
            {
                ShowDashboard();
            }
        };
        trayIcon.DoubleClick += (_, _) => ShowDashboard();
        taskbarReadout = new TaskbarReadoutForm(trayMenu);
        taskbarReadout.OpenRequested += (_, _) => ShowDashboard();
        taskbarReadout.Start();

        refreshTimer = new System.Windows.Forms.Timer
        {
            Interval = settings.RefreshSeconds * 1_000,
        };
        refreshTimer.Tick += async (_, _) => await RefreshAsync(forcePush: false);
        refreshTimer.Start();
        updateTimer = new System.Windows.Forms.Timer
        {
            Interval = (int)TimeSpan.FromHours(6).TotalMilliseconds,
        };
        updateTimer.Tick += async (_, _) => await updateManager.CheckForUpdatesAsync(
            manual: false,
            cancellation.Token);
        updateTimer.Start();
        updateManager.StateChanged += UpdateManagerOnStateChanged;
        Dashboard.SetRefreshCadence(settings.RefreshSeconds);
        Dashboard.SetStartupEnabled(settings.StartWithWindows);
        _ = Dashboard.Handle;
        ApplyUpdateState(updateManager.State);
        if (showDashboard)
        {
            ShowDashboard();
        }
        _ = RefreshAsync(forcePush: true);
        _ = updateManager.CheckForUpdatesAsync(manual: false, cancellation.Token);
    }

    protected override void ExitThreadCore()
    {
        exiting = true;
        refreshTimer.Stop();
        updateTimer.Stop();
        cancellation.Cancel();
        taskbarReadout.Dispose();
        trayIcon.Visible = false;
        trayIcon.ContextMenuStrip = null;
        trayIcon.Dispose();
        trayMenu.Dispose();
        rateIcon?.Dispose();
        applicationIcon.Dispose();
        dashboard.Dispose();
        updateTimer.Dispose();
        updateManager.StateChanged -= UpdateManagerOnStateChanged;
        updateManager.Dispose();
        ambientOps.Dispose();
        cancellation.Dispose();
        base.ExitThreadCore();
    }

    private DashboardForm Dashboard => dashboard.Current;

    private DashboardForm CreateDashboard()
    {
        var form = new DashboardForm(scanner.SessionsRoot);
        form.SettingsRequested += (_, _) => ShowSettings();
        form.RefreshRequested += async (_, _) => await RefreshAsync(forcePush: true);
        form.CheckForUpdatesRequested += async (_, _) => await updateManager.CheckForUpdatesAsync(
            manual: true,
            cancellation.Token);
        form.InstallUpdateRequested += async (_, _) => await InstallAvailableUpdateAsync();
        form.SessionsFolderRequested += (_, _) => OpenSessionsDirectory();
        form.ExitRequested += (_, _) => ExitThread();
        form.RefreshCadenceChanged += SetRefreshCadence;
        form.StartupChanged += SetStartupEnabled;
        form.UpdateSnapshot(lastSnapshot, ambientOps.Connection);
        form.SetRefreshCadence(settings.RefreshSeconds);
        form.SetStartupEnabled(settings.StartWithWindows);
        form.SetUpdateState(updateManager.State);
        return form;
    }

    private void ShowDashboard()
    {
        if (!exiting)
        {
            Dashboard.ShowFromTray();
        }
    }

    private async Task RefreshAsync(bool forcePush)
    {
        if (refreshing || exiting)
        {
            return;
        }
        refreshing = true;
        try
        {
            lastSnapshot = await Task.Run(() => scanner.Refresh(), cancellation.Token);
            await ambientOps.PushIfDueAsync(
                lastSnapshot,
                settings,
                scanner.CodexHome,
                forcePush,
                cancellation.Token);
            if (exiting)
            {
                return;
            }
            Dashboard.UpdateSnapshot(lastSnapshot, ambientOps.Connection);
            OpenPairingApprovalIfNeeded(ambientOps.Connection);
            UpdateTrayRateIcon(lastSnapshot);
            taskbarReadout.SetRate(
                lastSnapshot.Status == CollectionStatus.Ready
                    ? lastSnapshot.OneMinute.TokensPerSecond
                    : null);
            trayIcon.Text = lastSnapshot.Status == CollectionStatus.Ready
                ? $"OPL Fleet Agent · {Compact(lastSnapshot.OneMinute.TokensPerSecond)} t/s"
                : "OPL Fleet Agent · sessions unavailable";
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            return;
        }
        catch (Exception error)
        {
            if (exiting)
            {
                return;
            }
            Dashboard.UpdateSnapshot(
                lastSnapshot,
                new AmbientOpsConnectionStatus(
                    AmbientOpsConnectionKind.Failed,
                    $"错误 · {error.Message}"));
        }
        finally
        {
            refreshing = false;
        }
    }

    private async Task RunUpdateActionAsync()
    {
        if (updateManager.State.Kind == AppUpdateKind.Available)
        {
            await InstallAvailableUpdateAsync();
        }
        else
        {
            await updateManager.CheckForUpdatesAsync(manual: true, cancellation.Token);
        }
    }

    private async Task InstallAvailableUpdateAsync()
    {
        if (await updateManager.InstallAvailableUpdateAsync(cancellation.Token))
        {
            ExitThread();
        }
    }

    private void UpdateManagerOnStateChanged(object? sender, AppUpdateState state)
    {
        if (exiting)
        {
            return;
        }

        var form = Dashboard;
        if (form.InvokeRequired)
        {
            try
            {
                form.BeginInvoke(new Action(() => ApplyUpdateState(state)));
            }
            catch (InvalidOperationException)
            {
                // The application is already closing.
            }
            return;
        }

        ApplyUpdateState(state);
    }

    private void ApplyUpdateState(AppUpdateState state)
    {
        if (exiting)
        {
            return;
        }

        Dashboard.SetUpdateState(state);
        updateMenuItem.Enabled = !state.IsBusy;
        updateMenuItem.Text = state is { Kind: AppUpdateKind.Available, Release: { } release }
            ? $"更新到 {release.TagName}"
            : "检查更新";

        if (state is { Kind: AppUpdateKind.Available, Release: { } available } &&
            notifiedUpdateTag != available.TagName)
        {
            notifiedUpdateTag = available.TagName;
            trayIcon.ShowBalloonTip(
                5_000,
                "OPL Fleet Agent 有新版本",
                $"已发现 {available.TagName}，打开面板即可更新。",
                ToolTipIcon.Info);
        }
        else if (state is { Kind: AppUpdateKind.Failed, Message: { } message })
        {
            trayIcon.ShowBalloonTip(
                5_000,
                "OPL Fleet Agent 更新失败",
                message,
                ToolTipIcon.Warning);
        }
    }

    private void UpdateTrayRateIcon(UsageSnapshot snapshot)
    {
        var previous = rateIcon;
        if (snapshot.Status == CollectionStatus.Ready)
        {
            rateIcon = TrayRateIcon.Create(snapshot.OneMinute.TokensPerSecond);
            trayIcon.Icon = rateIcon;
        }
        else
        {
            rateIcon = null;
            trayIcon.Icon = applicationIcon;
        }
        previous?.Dispose();
    }

    private void ShowSettings()
    {
        if (exiting)
        {
            return;
        }
        var owner = Dashboard;
        using var form = new SettingsForm(settings, ambientOps.Connection);
        if (form.ShowDialog(owner) != DialogResult.OK || form.ResultSettings is not { } next)
        {
            return;
        }
        try
        {
            var previousStartup = StartupRegistration.IsEnabled();
            try
            {
                if (next.AmbientEnabled)
                {
                    settingsStore.EnsureDeviceKey(next);
                }
                StartupRegistration.SetEnabled(next.StartWithWindows);
                settingsStore.Save(next);
            }
            catch
            {
                StartupRegistration.SetEnabled(previousStartup);
                throw;
            }
            settings = next;
            scanner = CreateScanner(settings);
            Dashboard.UpdateSessionsRoot(scanner.SessionsRoot);
            refreshTimer.Interval = settings.RefreshSeconds * 1_000;
            Dashboard.SetRefreshCadence(settings.RefreshSeconds);
            Dashboard.SetStartupEnabled(settings.StartWithWindows);
            _ = RefreshAsync(forcePush: true);
        }
        catch (Exception error)
        {
            MessageBox.Show(
                Dashboard,
                error.Message,
                "Settings could not be saved",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
        }
    }

    private static SessionScanner CreateScanner(AppSettings settings)
    {
        try
        {
            return new SessionScanner(
                string.IsNullOrWhiteSpace(settings.CodexHome) ? null : settings.CodexHome);
        }
        catch (Exception error) when (
            error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            settings.CodexHome = string.Empty;
            return new SessionScanner();
        }
    }

    private static string Compact(double value) => Math.Abs(value) switch
    {
        >= 1_000_000 => $"{value / 1_000_000:0.0}M",
        >= 1_000 => $"{value / 1_000:0.0}K",
        _ => $"{value:0.0}",
    };

    private void OpenPairingApprovalIfNeeded(AmbientOpsConnectionStatus connection)
    {
        if (connection.ApprovalUri is null ||
            connection.ApprovalUri.AbsoluteUri == openedPairingUri)
        {
            return;
        }
        openedPairingUri = connection.ApprovalUri.AbsoluteUri;
        try
        {
            Process.Start(new ProcessStartInfo(openedPairingUri)
            {
                UseShellExecute = true,
            });
        }
        catch (Exception error)
        {
            ShowError("无法打开 Ambient Ops 批准页", error);
        }
    }

    private void SetRefreshCadence(int seconds)
    {
        if (seconds is not (5 or 15 or 30 or 60))
        {
            return;
        }
        var previous = settings.RefreshSeconds;
        try
        {
            settings.RefreshSeconds = seconds;
            settingsStore.Save(settings);
            refreshTimer.Interval = seconds * 1_000;
        }
        catch (Exception error)
        {
            settings.RefreshSeconds = previous;
            Dashboard.SetRefreshCadence(previous);
            ShowError("刷新间隔无法保存", error);
        }
    }

    private void SetStartupEnabled(bool enabled)
    {
        var previous = settings.StartWithWindows;
        try
        {
            StartupRegistration.SetEnabled(enabled);
            settings.StartWithWindows = enabled;
            settingsStore.Save(settings);
            Dashboard.SetStartupEnabled(enabled);
        }
        catch (Exception error)
        {
            StartupRegistration.SetEnabled(previous);
            settings.StartWithWindows = previous;
            Dashboard.SetStartupEnabled(previous);
            ShowError("登录启动无法更新", error);
        }
    }

    private void OpenSessionsDirectory()
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = scanner.SessionsRoot,
                UseShellExecute = true,
            });
        }
        catch (Exception error)
        {
            ShowError("会话目录无法打开", error);
        }
    }

    private void ShowError(string title, Exception error) => MessageBox.Show(
        Dashboard,
        error.Message,
        title,
        MessageBoxButtons.OK,
        MessageBoxIcon.Error);
}

internal sealed class DashboardFormSlot(Func<DashboardForm> createForm) : IDisposable
{
    private DashboardForm? current;
    private bool disposed;

    public DashboardForm Current
    {
        get
        {
            if (disposed)
            {
                throw new ObjectDisposedException(nameof(DashboardFormSlot));
            }
            if (current is null || current.IsDisposed || current.Disposing)
            {
                current = createForm();
            }
            return current;
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        if (current is { IsDisposed: false })
        {
            current.CloseForExit();
            current.Dispose();
        }
        current = null;
    }
}
