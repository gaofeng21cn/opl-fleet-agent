namespace OPLFleetAgent.WindowsApp;

internal enum TaskbarEdge
{
    Bottom,
    Top,
    Left,
    Right,
}

internal readonly record struct TaskbarGeometry(
    Rectangle TaskbarBounds,
    Rectangle MonitorBounds,
    Rectangle? NotificationBounds,
    int Dpi,
    bool AutoHide,
    bool IsTaskbarVisible = true);

internal readonly record struct TaskbarPlacement(
    Rectangle Bounds,
    TaskbarEdge Edge,
    bool IsVisible)
{
    private const int HiddenEdgeLogicalPixels = 8;
    private const int HorizontalWidthLogicalPixels = 128;
    private const int HorizontalHeightLogicalPixels = 32;
    private const int HorizontalMinimumWidthLogicalPixels = 112;
    private const int HorizontalMinimumHeightLogicalPixels = 28;
    private const int VerticalWidthLogicalPixels = 42;
    private const int VerticalHeightLogicalPixels = 52;
    private const int VerticalMinimumWidthLogicalPixels = 28;
    private const int VerticalMinimumHeightLogicalPixels = 36;
    private const int HorizontalInsetLogicalPixels = 2;
    private const int VerticalInsetLogicalPixels = 4;
    private const int NotificationGapLogicalPixels = 6;

    public static TaskbarPlacement Calculate(TaskbarGeometry geometry)
    {
        var edge = DetectEdge(geometry.TaskbarBounds, geometry.MonitorBounds);
        if (!geometry.IsTaskbarVisible)
        {
            return Hidden(edge);
        }

        var visibleTaskbar = Rectangle.Intersect(
            geometry.TaskbarBounds,
            geometry.MonitorBounds);
        if (visibleTaskbar.Width <= 0 || visibleTaskbar.Height <= 0)
        {
            return Hidden(edge);
        }

        var horizontal = edge is TaskbarEdge.Bottom or TaskbarEdge.Top;
        var visibleThickness = horizontal
            ? visibleTaskbar.Height
            : visibleTaskbar.Width;
        if (geometry.AutoHide &&
            visibleThickness <= Scale(HiddenEdgeLogicalPixels, geometry.Dpi))
        {
            return Hidden(edge);
        }

        return horizontal
            ? CalculateHorizontal(geometry, visibleTaskbar, edge)
            : CalculateVertical(geometry, visibleTaskbar, edge);
    }

    internal static Rectangle IncludeAdjacentTaskbarContent(
        Rectangle taskbar,
        Rectangle notification,
        IEnumerable<Rectangle> candidates,
        int dpi)
    {
        var horizontal = taskbar.Width >= taskbar.Height;
        var occupied = Rectangle.Intersect(taskbar, notification);
        if (occupied.IsEmpty)
        {
            return notification;
        }
        var notificationAnchor = occupied;
        var adjacencyTolerance = Scale(8, dpi);

        foreach (var candidate in candidates)
        {
            var bounded = Rectangle.Intersect(taskbar, candidate);
            if (bounded.IsEmpty)
            {
                continue;
            }

            var consumesMostTaskbar = horizontal
                ? bounded.Width >= taskbar.Width / 2
                : bounded.Height >= taskbar.Height / 2;
            if (consumesMostTaskbar)
            {
                continue;
            }

            var isAdjacent = horizontal
                ? bounded.Left < notificationAnchor.Left &&
                    bounded.Right >= notificationAnchor.Left - adjacencyTolerance
                : bounded.Top < notificationAnchor.Top &&
                    bounded.Bottom >= notificationAnchor.Top - adjacencyTolerance;
            if (isAdjacent)
            {
                occupied = Rectangle.Union(occupied, bounded);
            }
        }

        return occupied;
    }

    private static TaskbarPlacement CalculateHorizontal(
        TaskbarGeometry geometry,
        Rectangle taskbar,
        TaskbarEdge edge)
    {
        var inset = Scale(HorizontalInsetLogicalPixels, geometry.Dpi);
        var gap = Scale(NotificationGapLogicalPixels, geometry.Dpi);
        var left = taskbar.Left + inset;
        var notificationLeft = NotificationAnchor(
            geometry.NotificationBounds,
            taskbar,
            horizontal: true);
        var right = notificationLeft.HasValue
            ? notificationLeft.Value - gap
            : taskbar.Right - inset;
        var availableWidth = right - left;
        var width = Math.Min(
            Scale(HorizontalWidthLogicalPixels, geometry.Dpi),
            availableWidth);
        var height = Math.Min(
            Scale(HorizontalHeightLogicalPixels, geometry.Dpi),
            taskbar.Height - (2 * inset));

        if (width < Scale(HorizontalMinimumWidthLogicalPixels, geometry.Dpi) ||
            height < Scale(HorizontalMinimumHeightLogicalPixels, geometry.Dpi))
        {
            return Hidden(edge);
        }

        return new TaskbarPlacement(
            new Rectangle(
                right - width,
                taskbar.Top + ((taskbar.Height - height) / 2),
                width,
                height),
            edge,
            IsVisible: true);
    }

    private static TaskbarPlacement CalculateVertical(
        TaskbarGeometry geometry,
        Rectangle taskbar,
        TaskbarEdge edge)
    {
        var inset = Scale(VerticalInsetLogicalPixels, geometry.Dpi);
        var gap = Scale(NotificationGapLogicalPixels, geometry.Dpi);
        var top = taskbar.Top + inset;
        var notificationTop = NotificationAnchor(
            geometry.NotificationBounds,
            taskbar,
            horizontal: false);
        var bottom = notificationTop.HasValue
            ? notificationTop.Value - gap
            : taskbar.Bottom - inset;
        var availableHeight = bottom - top;
        var width = Math.Min(
            Scale(VerticalWidthLogicalPixels, geometry.Dpi),
            taskbar.Width - (2 * inset));
        var height = Math.Min(
            Scale(VerticalHeightLogicalPixels, geometry.Dpi),
            availableHeight);

        if (width < Scale(VerticalMinimumWidthLogicalPixels, geometry.Dpi) ||
            height < Scale(VerticalMinimumHeightLogicalPixels, geometry.Dpi))
        {
            return Hidden(edge);
        }

        return new TaskbarPlacement(
            new Rectangle(
                taskbar.Left + ((taskbar.Width - width) / 2),
                bottom - height,
                width,
                height),
            edge,
            IsVisible: true);
    }

    private static int? NotificationAnchor(
        Rectangle? notificationBounds,
        Rectangle taskbar,
        bool horizontal)
    {
        if (notificationBounds is not { } notification ||
            !notification.IntersectsWith(taskbar))
        {
            return null;
        }

        return horizontal
            ? Math.Clamp(notification.Left, taskbar.Left, taskbar.Right)
            : Math.Clamp(notification.Top, taskbar.Top, taskbar.Bottom);
    }

    private static TaskbarEdge DetectEdge(Rectangle taskbar, Rectangle monitor)
    {
        if (taskbar.Width >= taskbar.Height)
        {
            var topDistance = Math.Abs(taskbar.Top - monitor.Top);
            var bottomDistance = Math.Abs(monitor.Bottom - taskbar.Bottom);
            return topDistance <= bottomDistance
                ? TaskbarEdge.Top
                : TaskbarEdge.Bottom;
        }

        var leftDistance = Math.Abs(taskbar.Left - monitor.Left);
        var rightDistance = Math.Abs(monitor.Right - taskbar.Right);
        return leftDistance <= rightDistance
            ? TaskbarEdge.Left
            : TaskbarEdge.Right;
    }

    private static int Scale(int logicalPixels, int dpi)
    {
        var effectiveDpi = dpi > 0 ? dpi : 96;
        return (int)Math.Round(
            logicalPixels * effectiveDpi / 96d,
            MidpointRounding.AwayFromZero);
    }

    private static TaskbarPlacement Hidden(TaskbarEdge edge) =>
        new(Rectangle.Empty, edge, IsVisible: false);
}
