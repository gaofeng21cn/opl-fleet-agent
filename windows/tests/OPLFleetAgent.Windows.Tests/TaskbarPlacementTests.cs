using OPLFleetAgent.WindowsApp;

namespace OPLFleetAgent.Windows.Tests;

public sealed class TaskbarPlacementTests
{
    [Fact]
    public void BottomTaskbarPlacesReadoutLeftOfNotificationArea()
    {
        var notification = new Rectangle(1580, 1040, 340, 40);
        var placement = TaskbarPlacement.Calculate(new TaskbarGeometry(
            new Rectangle(0, 1040, 1920, 40),
            new Rectangle(0, 0, 1920, 1080),
            notification,
            Dpi: 96,
            AutoHide: false));

        Assert.True(placement.IsVisible);
        Assert.Equal(TaskbarEdge.Bottom, placement.Edge);
        Assert.Equal(new Rectangle(1446, 1044, 128, 32), placement.Bounds);
        Assert.False(placement.Bounds.IntersectsWith(notification));
    }

    [Fact]
    public void TopTaskbarPlacesReadoutInsideTaskbar()
    {
        var placement = TaskbarPlacement.Calculate(new TaskbarGeometry(
            new Rectangle(0, 0, 2560, 48),
            new Rectangle(0, 0, 2560, 1440),
            new Rectangle(2200, 0, 360, 48),
            Dpi: 96,
            AutoHide: false));

        Assert.True(placement.IsVisible);
        Assert.Equal(TaskbarEdge.Top, placement.Edge);
        Assert.Equal(new Rectangle(2066, 8, 128, 32), placement.Bounds);
    }

    [Theory]
    [InlineData(0, 0, "Left")]
    [InlineData(1872, 0, "Right")]
    public void VerticalTaskbarPlacesReadoutAboveNotificationArea(
        int taskbarX,
        int monitorX,
        string expectedEdge)
    {
        var notification = new Rectangle(taskbarX, 800, 48, 280);
        var placement = TaskbarPlacement.Calculate(new TaskbarGeometry(
            new Rectangle(taskbarX, 0, 48, 1080),
            new Rectangle(monitorX, 0, 1920, 1080),
            notification,
            Dpi: 96,
            AutoHide: false));

        Assert.True(placement.IsVisible);
        Assert.Equal(expectedEdge, placement.Edge.ToString());
        Assert.Equal(new Rectangle(taskbarX + 4, 742, 40, 52), placement.Bounds);
        Assert.False(placement.Bounds.IntersectsWith(notification));
    }

    [Fact]
    public void HiddenAutoHideTaskbarDoesNotShowReadout()
    {
        var placement = TaskbarPlacement.Calculate(new TaskbarGeometry(
            new Rectangle(0, 1078, 1920, 48),
            new Rectangle(0, 0, 1920, 1080),
            NotificationBounds: null,
            Dpi: 96,
            AutoHide: true));

        Assert.False(placement.IsVisible);
        Assert.Equal(TaskbarEdge.Bottom, placement.Edge);
        Assert.Equal(Rectangle.Empty, placement.Bounds);
    }

    [Fact]
    public void ExpandedAutoHideTaskbarShowsReadout()
    {
        var placement = TaskbarPlacement.Calculate(new TaskbarGeometry(
            new Rectangle(0, 1032, 1920, 48),
            new Rectangle(0, 0, 1920, 1080),
            new Rectangle(1580, 1032, 340, 48),
            Dpi: 96,
            AutoHide: true));

        Assert.True(placement.IsVisible);
        Assert.Equal(TaskbarEdge.Bottom, placement.Edge);
    }

    [Fact]
    public void LayoutScalesWithTaskbarDpi()
    {
        var placement = TaskbarPlacement.Calculate(new TaskbarGeometry(
            new Rectangle(-2560, 1344, 2560, 96),
            new Rectangle(-2560, 0, 2560, 1440),
            new Rectangle(-520, 1344, 520, 96),
            Dpi: 192,
            AutoHide: false));

        Assert.True(placement.IsVisible);
        Assert.Equal(new Rectangle(-788, 1360, 256, 64), placement.Bounds);
    }

    [Fact]
    public void InsufficientSpaceBeforeNotificationAreaHidesReadout()
    {
        var placement = TaskbarPlacement.Calculate(new TaskbarGeometry(
            new Rectangle(0, 1040, 200, 40),
            new Rectangle(0, 0, 200, 1080),
            new Rectangle(70, 1040, 130, 40),
            Dpi: 96,
            AutoHide: false));

        Assert.False(placement.IsVisible);
    }

    [Fact]
    public void AdjacentThirdPartyTaskbarContentExtendsNotificationArea()
    {
        var taskbar = new Rectangle(0, 1032, 1920, 48);
        var notification = new Rectangle(1610, 1032, 310, 48);
        var trafficMonitor = new Rectangle(1518, 1040, 94, 32);
        var unrelatedWidget = new Rectangle(1420, 1040, 98, 32);
        var taskList = new Rectangle(583, 1032, 577, 48);
        var fullTaskbarSurface = taskbar;

        var occupied = TaskbarPlacement.IncludeAdjacentTaskbarContent(
            taskbar,
            notification,
            [trafficMonitor, unrelatedWidget, taskList, fullTaskbarSurface],
            dpi: 96);
        var placement = TaskbarPlacement.Calculate(new TaskbarGeometry(
            taskbar,
            new Rectangle(0, 0, 1920, 1080),
            occupied,
            Dpi: 96,
            AutoHide: false));

        Assert.Equal(new Rectangle(1518, 1032, 402, 48), occupied);
        Assert.True(placement.IsVisible);
        Assert.Equal(new Rectangle(1384, 1040, 128, 32), placement.Bounds);
        Assert.False(placement.Bounds.IntersectsWith(trafficMonitor));
    }

    [Fact]
    public void AdjacentTaskbarContentToleranceScalesWithDpi()
    {
        var taskbar = new Rectangle(0, 2016, 3840, 144);
        var notification = new Rectangle(3200, 2016, 640, 144);
        var trafficMonitor = new Rectangle(3000, 2036, 185, 64);

        var occupied = TaskbarPlacement.IncludeAdjacentTaskbarContent(
            taskbar,
            notification,
            [trafficMonitor],
            dpi: 192);

        Assert.Equal(new Rectangle(3000, 2016, 840, 144), occupied);
    }
}
