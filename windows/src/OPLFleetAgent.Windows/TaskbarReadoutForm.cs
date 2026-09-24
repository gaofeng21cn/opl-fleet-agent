using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace OPLFleetAgent.WindowsApp;

internal sealed class TaskbarReadoutForm : Form
{
    private const int WsExNoActivate = 0x08000000;
    private const int WsExLayered = 0x00080000;
    private const int WsExToolWindow = 0x00000080;
    private const uint AbmGetState = 0x00000004;
    private const uint AbsAutoHide = 0x00000001;
    private const uint MonitorDefaultToNearest = 0x00000002;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;
    private static readonly IntPtr HwndTopmost = new(-1);

    private readonly System.Windows.Forms.Timer placementTimer = new()
    {
        Interval = 1_000,
    };
    private TaskbarEdge edge = TaskbarEdge.Bottom;
    private Rectangle readoutBounds;
    private int taskbarDpi = 96;
    private string rateText = "-- t/s";

    public TaskbarReadoutForm(ContextMenuStrip contextMenu)
    {
        AccessibleName = "OPL Fleet Agent 任务栏读数";
        ContextMenuStrip = contextMenu;
        Cursor = Cursors.Hand;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;

        placementTimer.Tick += (_, _) => RefreshPlacement();
    }

    public event EventHandler? OpenRequested;

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ExStyle |= WsExLayered | WsExNoActivate | WsExToolWindow;
            return parameters;
        }
    }

    public void Start()
    {
        RefreshPlacement();
        placementTimer.Start();
    }

    public void SetRate(double? tokensPerSecond)
    {
        var next = tokensPerSecond.HasValue && double.IsFinite(tokensPerSecond.Value)
            ? $"{Compact(Math.Max(0, tokensPerSecond.Value))} t/s"
            : "-- t/s";
        if (next == rateText)
        {
            return;
        }

        rateText = next;
        AccessibleDescription = $"当前吞吐率 {next}";
        RenderReadout();
    }

    protected override void OnMouseClick(MouseEventArgs eventArgs)
    {
        base.OnMouseClick(eventArgs);
        if (eventArgs.Button == MouseButtons.Left)
        {
            OpenRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            placementTimer.Stop();
            placementTimer.Dispose();
            ContextMenuStrip = null;
        }
        base.Dispose(disposing);
    }

    private void RefreshPlacement()
    {
        if (!TaskbarNative.TryGetGeometry(out var geometry))
        {
            Hide();
            return;
        }

        var placement = TaskbarPlacement.Calculate(geometry);
        edge = placement.Edge;
        taskbarDpi = geometry.Dpi > 0 ? geometry.Dpi : 96;
        if (!placement.IsVisible)
        {
            Hide();
            return;
        }

        if (!Visible)
        {
            Show();
        }

        SetWindowPos(
            Handle,
            HwndTopmost,
            placement.Bounds.X,
            placement.Bounds.Y,
            placement.Bounds.Width,
            placement.Bounds.Height,
            SwpNoActivate | SwpShowWindow);
        readoutBounds = placement.Bounds;
        RenderReadout();
    }

    private void RenderReadout()
    {
        if (!IsHandleCreated || !Visible || readoutBounds.Width <= 0 || readoutBounds.Height <= 0)
        {
            return;
        }

        var textColor = SystemInformation.HighContrast
            ? SystemColors.WindowText
            : TaskbarReadoutAppearance.TextColor(TaskbarTheme.UsesLightTheme());
        using var bitmap = TaskbarReadoutAppearance.Render(
            readoutBounds.Size,
            rateText,
            edge,
            taskbarDpi,
            textColor,
            SystemInformation.HighContrast);
        LayeredWindow.Update(Handle, readoutBounds, bitmap);
    }

    private static string Compact(double value) => value switch
    {
        >= 1_000_000 => $"{value / 1_000_000:0.0}M",
        >= 1_000 => $"{value / 1_000:0.0}K",
        _ => $"{value:0.0}",
    };

    private static class TaskbarTheme
    {
        private const string PersonalizeKey =
            @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

        public static bool UsesLightTheme()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(PersonalizeKey);
                return key?.GetValue("SystemUsesLightTheme") is not int value || value != 0;
            }
            catch (Exception error) when (
                error is System.Security.SecurityException or UnauthorizedAccessException or IOException)
            {
                return true;
            }
        }
    }

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(
        IntPtr window,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    private static class TaskbarNative
    {
        public static bool TryGetGeometry(out TaskbarGeometry geometry)
        {
            geometry = default;
            var taskbar = FindWindow("Shell_TrayWnd", null);
            if (taskbar == IntPtr.Zero ||
                !IsWindowVisible(taskbar) ||
                !GetWindowRect(taskbar, out var taskbarRectangle))
            {
                return false;
            }

            var monitor = MonitorFromWindow(taskbar, MonitorDefaultToNearest);
            var monitorInfo = new MonitorInfo
            {
                Size = Marshal.SizeOf<MonitorInfo>(),
            };
            if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref monitorInfo))
            {
                return false;
            }

            var dpi = GetWindowDpi(taskbar);
            Rectangle? notificationBounds = null;
            var notification = FindWindowEx(taskbar, IntPtr.Zero, "TrayNotifyWnd", null);
            if (notification != IntPtr.Zero &&
                IsWindowVisible(notification) &&
                GetWindowRect(notification, out var notificationRectangle))
            {
                notificationBounds = TaskbarPlacement.IncludeAdjacentTaskbarContent(
                    taskbarRectangle.ToRectangle(),
                    notificationRectangle.ToRectangle(),
                    ChildWindowBounds(taskbar),
                    dpi);
            }

            var appBarData = new AppBarData
            {
                Size = (uint)Marshal.SizeOf<AppBarData>(),
                Window = taskbar,
            };
            var appBarState = SHAppBarMessage(AbmGetState, ref appBarData);
            geometry = new TaskbarGeometry(
                taskbarRectangle.ToRectangle(),
                monitorInfo.Monitor.ToRectangle(),
                notificationBounds,
                dpi,
                AutoHide: (appBarState & AbsAutoHide) != 0);
            return true;
        }

        private static IReadOnlyList<Rectangle> ChildWindowBounds(IntPtr parent)
        {
            var bounds = new List<Rectangle>();
            EnumChildWindows(parent, (window, _) =>
            {
                if (IsWindowVisible(window) &&
                    GetWindowRect(window, out var rectangle))
                {
                    bounds.Add(rectangle.ToRectangle());
                }
                return true;
            }, IntPtr.Zero);
            return bounds;
        }

        private static int GetWindowDpi(IntPtr window)
        {
            try
            {
                var dpi = GetDpiForWindow(window);
                return dpi > 0 ? (int)dpi : 96;
            }
            catch (EntryPointNotFoundException)
            {
                return 96;
            }
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string className, string? windowName);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindowEx(
            IntPtr parent,
            IntPtr childAfter,
            string className,
            string? windowName);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetWindowRect(IntPtr window, out NativeRectangle rectangle);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWindowVisible(IntPtr window);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumChildWindows(
            IntPtr parent,
            EnumWindowCallback callback,
            IntPtr parameter);

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo monitorInfo);

        [DllImport("user32.dll")]
        private static extern uint GetDpiForWindow(IntPtr window);

        [DllImport("shell32.dll")]
        private static extern uint SHAppBarMessage(uint message, ref AppBarData data);

        private delegate bool EnumWindowCallback(IntPtr window, IntPtr parameter);

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRectangle
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;

            public readonly Rectangle ToRectangle() => Rectangle.FromLTRB(
                Left,
                Top,
                Right,
                Bottom);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MonitorInfo
        {
            public int Size;
            public NativeRectangle Monitor;
            public NativeRectangle WorkArea;
            public uint Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct AppBarData
        {
            public uint Size;
            public IntPtr Window;
            public uint CallbackMessage;
            public uint Edge;
            public NativeRectangle Rectangle;
            public IntPtr Parameter;
        }
    }
}

internal static class TaskbarReadoutAppearance
{
    internal const byte TransparentHitTestAlpha = 1;
    private const float HorizontalFontLogicalPixels = 13f;
    private const float VerticalFontLogicalPixels = 10.5f;
    private const float UnitFontScale = 0.74f;
    private const float TextGapLogicalPixels = 4f;

    public static FontStyle TextFontStyle => FontStyle.Bold;

    public static string TextFontFamily => "Segoe UI Variable Text";

    public static float FontPixelSize(TaskbarEdge edge, int dpi)
    {
        var logicalPixels = edge is TaskbarEdge.Left or TaskbarEdge.Right
            ? VerticalFontLogicalPixels
            : HorizontalFontLogicalPixels;
        var effectiveDpi = dpi > 0 ? dpi : 96;
        return logicalPixels * effectiveDpi / 96f;
    }

    public static Color TextColor(bool lightTheme) => lightTheme
        ? Color.FromArgb(36, 36, 38)
        : Color.FromArgb(248, 248, 250);

    public static string DisplayText(string rateText, TaskbarEdge edge)
    {
        if (edge is TaskbarEdge.Left or TaskbarEdge.Right)
        {
            return rateText.Replace(
                " ",
                Environment.NewLine,
                StringComparison.Ordinal);
        }

        return rateText;
    }

    public static Bitmap Render(
        Size size,
        string rateText,
        TaskbarEdge edge,
        int dpi,
        Color textColor,
        bool highContrast = false)
    {
        var bitmap = new Bitmap(
            Math.Max(1, size.Width),
            Math.Max(1, size.Height),
            PixelFormat.Format32bppPArgb);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.CompositingMode = CompositingMode.SourceCopy;
        graphics.Clear(Color.FromArgb(TransparentHitTestAlpha, 0, 0, 0));
        graphics.CompositingMode = CompositingMode.SourceOver;
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;

        var vertical = edge is TaskbarEdge.Left or TaskbarEdge.Right;
        var inset = Math.Max(2, (int)Math.Round(dpi / 48d));
        var badge = new Rectangle(
            inset,
            inset,
            Math.Max(1, bitmap.Width - inset * 2 - 1),
            Math.Max(1, bitmap.Height - inset * 2 - 1));
        var lightSurface = textColor.GetBrightness() < 0.5f;
        var surfaceColor = lightSurface ? Color.White : Color.Black;
        var background = highContrast
            ? SystemColors.Window
            : Color.FromArgb(lightSurface ? 48 : 64, surfaceColor);
        var border = highContrast
            ? SystemColors.WindowText
            : Color.FromArgb(lightSurface ? 64 : 80, surfaceColor);
        using var badgePath = RoundedPopupForm.RoundedRectangle(
            badge,
            Math.Min(vertical ? 7 : 9, badge.Height / 3f));
        using var backgroundBrush = new SolidBrush(background);
        using var borderPen = new Pen(border);
        graphics.FillPath(backgroundBrush, badgePath);
        graphics.DrawPath(borderPen, badgePath);

        if (!highContrast)
        {
            using var accentBrush = new SolidBrush(Color.FromArgb(230, 38, 183, 168));
            var accentSize = Math.Max(3, (int)Math.Round(dpi / 36d));
            graphics.FillEllipse(
                accentBrush,
                badge.Left + (vertical ? (badge.Width - accentSize) / 2 : accentSize + 3),
                badge.Top + (vertical ? accentSize : (badge.Height - accentSize) / 2),
                accentSize,
                accentSize);
        }

        var displayText = DisplayText(rateText, edge);
        var textBounds = vertical
            ? new Rectangle(badge.Left + 2, badge.Top + 4, badge.Width - 4, badge.Height - 6)
            : new Rectangle(badge.Left + 14, badge.Top + 1, badge.Width - 18, badge.Height - 2);
        var fontSize = FontPixelSize(edge, dpi);
        if (vertical)
        {
            using var font = new Font(TextFontFamily, fontSize, TextFontStyle, GraphicsUnit.Pixel);
            using var textBrush = new SolidBrush(textColor);
            using var format = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center,
                FormatFlags = StringFormatFlags.NoWrap,
            };
            DrawTextWithShadow(graphics, displayText, font, textBrush, textBounds, format, textColor);
        }
        else
        {
            var valueText = rateText;
            var unitText = string.Empty;
            var separator = rateText.IndexOf(' ');
            if (separator > 0)
            {
                valueText = rateText[..separator];
                unitText = rateText[(separator + 1)..];
            }

            var unitSize = Math.Max(8f, fontSize * UnitFontScale);
            Font mainFont;
            Font unitFont;
            SizeF valueMeasurement;
            SizeF unitMeasurement;
            do
            {
                mainFont = new Font(TextFontFamily, fontSize, TextFontStyle, GraphicsUnit.Pixel);
                unitFont = new Font(TextFontFamily, unitSize, FontStyle.Regular, GraphicsUnit.Pixel);
                valueMeasurement = graphics.MeasureString(valueText, mainFont);
                unitMeasurement = graphics.MeasureString(unitText, unitFont);
                var totalWidth = valueMeasurement.Width + (unitText.Length > 0 ?
                    Scale(TextGapLogicalPixels, dpi) + unitMeasurement.Width : 0);
                if (totalWidth <= textBounds.Width &&
                    Math.Max(valueMeasurement.Height, unitMeasurement.Height) <= textBounds.Height ||
                    fontSize <= 8f)
                {
                    break;
                }
                mainFont.Dispose();
                unitFont.Dispose();
                fontSize -= 0.5f;
                unitSize = Math.Max(8f, fontSize * UnitFontScale);
            } while (true);

            using (mainFont)
            using (unitFont)
            using (var mainBrush = new SolidBrush(textColor))
            using (var unitBrush = new SolidBrush(Color.FromArgb(
                Math.Min(220, (int)textColor.A),
                textColor.R,
                textColor.G,
                textColor.B)))
            {
                var gap = unitText.Length > 0 ? Scale(TextGapLogicalPixels, dpi) : 0;
                var totalWidth = valueMeasurement.Width + gap + unitMeasurement.Width;
                var x = textBounds.Left + Math.Max(0, (textBounds.Width - totalWidth) / 2f);
                var y = textBounds.Top + (textBounds.Height - Math.Max(
                    valueMeasurement.Height,
                    unitMeasurement.Height)) / 2f - 1f;
                DrawTextWithShadow(graphics, valueText, mainFont, mainBrush, new PointF(x, y), textColor);
                if (unitText.Length > 0)
                {
                    DrawTextWithShadow(
                        graphics,
                        unitText,
                        unitFont,
                        unitBrush,
                        new PointF(x + valueMeasurement.Width + gap, y + 1f),
                        textColor);
                }
            }
        }
        return bitmap;
    }

    private static int Scale(float logicalPixels, int dpi)
    {
        var effectiveDpi = dpi > 0 ? dpi : 96;
        return (int)Math.Round(logicalPixels * effectiveDpi / 96d, MidpointRounding.AwayFromZero);
    }

    private static void DrawTextWithShadow(
        Graphics graphics,
        string text,
        Font font,
        Brush brush,
        Rectangle bounds,
        StringFormat format,
        Color textColor)
    {
        var shadow = textColor.GetBrightness() < 0.5f
            ? Color.FromArgb(34, 255, 255, 255)
            : Color.FromArgb(44, 0, 0, 0);
        using var shadowBrush = new SolidBrush(shadow);
        graphics.DrawString(text, font, shadowBrush, new Rectangle(
            bounds.Left,
            bounds.Top + 1,
            bounds.Width,
            bounds.Height), format);
        graphics.DrawString(text, font, brush, bounds, format);
    }

    private static void DrawTextWithShadow(
        Graphics graphics,
        string text,
        Font font,
        Brush brush,
        PointF point,
        Color textColor)
    {
        var shadow = textColor.GetBrightness() < 0.5f
            ? Color.FromArgb(34, 255, 255, 255)
            : Color.FromArgb(44, 0, 0, 0);
        using var shadowBrush = new SolidBrush(shadow);
        graphics.DrawString(text, font, shadowBrush, new PointF(point.X, point.Y + 1f));
        graphics.DrawString(text, font, brush, point);
    }
}

internal static class LayeredWindow
{
    private const byte AcSrcOver = 0;
    private const byte AcSrcAlpha = 1;
    private const uint UlwAlpha = 0x00000002;

    public static bool Update(IntPtr window, Rectangle bounds, Bitmap bitmap)
    {
        var screenDc = GetDC(IntPtr.Zero);
        if (screenDc == IntPtr.Zero)
        {
            return false;
        }

        var memoryDc = CreateCompatibleDC(screenDc);
        if (memoryDc == IntPtr.Zero)
        {
            ReleaseDC(IntPtr.Zero, screenDc);
            return false;
        }

        var bitmapHandle = bitmap.GetHbitmap(Color.FromArgb(0));
        var previousBitmap = SelectObject(memoryDc, bitmapHandle);
        try
        {
            var destination = new NativePoint(bounds.X, bounds.Y);
            var source = new NativePoint(0, 0);
            var size = new NativeSize(bounds.Width, bounds.Height);
            var blend = new BlendFunction
            {
                BlendOp = AcSrcOver,
                SourceConstantAlpha = byte.MaxValue,
                AlphaFormat = AcSrcAlpha,
            };
            return UpdateLayeredWindow(
                window,
                screenDc,
                ref destination,
                ref size,
                memoryDc,
                ref source,
                0,
                ref blend,
                UlwAlpha);
        }
        finally
        {
            SelectObject(memoryDc, previousBitmap);
            DeleteObject(bitmapHandle);
            DeleteDC(memoryDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr window, IntPtr deviceContext);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr deviceContext);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteDC(IntPtr deviceContext);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr deviceContext, IntPtr value);

    [DllImport("gdi32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObject(IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateLayeredWindow(
        IntPtr window,
        IntPtr destinationDc,
        ref NativePoint destination,
        ref NativeSize size,
        IntPtr sourceDc,
        ref NativePoint source,
        uint colorKey,
        ref BlendFunction blend,
        uint flags);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint(int x, int y)
    {
        public int X = x;
        public int Y = y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSize(int width, int height)
    {
        public int Width = width;
        public int Height = height;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct BlendFunction
    {
        public byte BlendOp;
        public byte BlendFlags;
        public byte SourceConstantAlpha;
        public byte AlphaFormat;
    }
}
