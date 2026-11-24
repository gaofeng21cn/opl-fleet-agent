using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Windows.Forms;
using OPLFleetAgent.WindowsApp;

namespace OPLFleetAgent.Windows.Tests;

public sealed class DashboardFormBehaviorTests
{
    [Fact]
    public void DeactivationHidesDashboardToTray()
    {
        RunOnStaThread(() =>
        {
            using var form = new DashboardForm(string.Empty);
            form.Show();
            Assert.True(form.Visible);

            var onDeactivate = typeof(DashboardForm).GetMethod(
                "OnDeactivate",
                BindingFlags.Instance | BindingFlags.NonPublic);
            Assert.NotNull(onDeactivate);
            onDeactivate.Invoke(form, [EventArgs.Empty]);

            Assert.False(form.Visible);
            Assert.Equal(FormWindowState.Normal, form.WindowState);
        });
    }

    [Fact]
    public void HeaderProvidesExplicitMinimizeToTrayButton()
    {
        RunOnStaThread(() =>
        {
            using var form = new DashboardForm(string.Empty);
            var minimize = Assert.IsAssignableFrom<Button>(
                FindByAccessibleName(form, "最小化到通知区域"));

            form.Show();
            Assert.True(form.Visible);
            minimize.PerformClick();

            Assert.False(form.Visible);
            Assert.False(form.ShowInTaskbar);
        });
    }

    [Fact]
    public void HeaderUsesUntruncatedFleetAgentBrand()
    {
        RunOnStaThread(() =>
        {
            using var form = new DashboardForm(string.Empty);
            var title = Assert.IsAssignableFrom<Label>(
                FindByAccessibleName(form, "应用名称"));

            Assert.Equal("OPL Fleet Agent", title.Text);
        });
    }

    [Fact]
    public void LayoutScaleFitsUpdateStateInsideSmallWorkingArea()
    {
        var workingArea = new Size(640, 360);
        var scale = DashboardForm.CalculateLayoutScale(workingArea, nativeScale: 2f);

        Assert.True((int)Math.Ceiling(380 * scale) <= workingArea.Width - 24);
        Assert.True((int)Math.Ceiling(451 * scale) <= workingArea.Height - 24);
    }

    [Fact]
    public void HeaderProvidesManualUpdateCheckAndAvailableReleaseAction()
    {
        RunOnStaThread(() =>
        {
            using var form = new DashboardForm(string.Empty);
            var check = Assert.IsAssignableFrom<Button>(
                FindByAccessibleName(form, "检查更新"));
            var install = Assert.IsAssignableFrom<Button>(
                FindByAccessibleName(form, "立即更新"));
            var checkRequested = false;
            var installRequested = false;
            form.CheckForUpdatesRequested += (_, _) => checkRequested = true;
            form.InstallUpdateRequested += (_, _) => installRequested = true;

            form.SetUpdateState(new AppUpdateState(
                AppUpdateKind.Available,
                "发现新版本，请在更新窗口中确认安装"));
            form.Show();
            check.PerformClick();
            install.PerformClick();

            Assert.True(checkRequested);
            Assert.True(installRequested);
            Assert.True(install.Visible);
            Assert.Equal(BaseDashboardHeight + 43, form.ClientSize.Height);
        });
    }

    [Fact]
    public void SettingsFormExposesAutoUpdateToggleAndManualCheckControl()
    {
        RunOnStaThread(() =>
        {
            var settings = new AppSettings { AutoCheckForUpdates = true };
            var connection = new AmbientOpsConnectionStatus(AmbientOpsConnectionKind.Disabled, "未启用");
            using var form = new SettingsForm(settings, connection);

            var autoUpdateToggle = Assert.IsAssignableFrom<ToggleSwitch>(
                FindByAccessibleName(form, "自动检查更新"));
            var checkButton = Assert.IsAssignableFrom<Button>(
                FindByAccessibleName(form, "检查更新"));

            var checkRequested = false;
            form.CheckForUpdatesRequested += (_, _) => checkRequested = true;

            Assert.True(autoUpdateToggle.Checked);
            form.Show();
            checkButton.PerformClick();
            Assert.True(checkRequested);
        });
    }

    private const int BaseDashboardHeight = 408;

    private static Control? FindByAccessibleName(Control root, string accessibleName)
    {
        foreach (Control child in root.Controls)
        {
            if (child.AccessibleName == accessibleName)
            {
                return child;
            }

            var nested = FindByAccessibleName(child, accessibleName);
            if (nested is not null)
            {
                return nested;
            }
        }

        return null;
    }

    private static void RunOnStaThread(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                action();
            }
            catch (Exception error)
            {
                failure = error;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();

        Assert.True(thread.Join(TimeSpan.FromSeconds(10)), "WinForms test thread timed out.");
        if (failure is not null)
        {
            ExceptionDispatchInfo.Capture(failure).Throw();
        }
    }
}
