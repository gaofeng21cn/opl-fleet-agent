using CodexTPS.Core;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace CodexTPS.WindowsApp;

internal abstract class RoundedPopupForm : Form
{
    private const int CsDropShadow = 0x00020000;
    private const int WmNcLButtonDown = 0x00A1;
    private const int HtCaption = 0x0002;

    protected RoundedPopupForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        Padding = new Padding(1);
        DoubleBuffered = true;
        AutoScaleMode = AutoScaleMode.None;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ClassStyle |= CsDropShadow;
            return parameters;
        }
    }

    protected void EnableWindowDrag(Control control)
    {
        control.MouseDown += (_, eventArgs) =>
        {
            if (eventArgs.Button != MouseButtons.Left)
            {
                return;
            }
            ReleaseCapture();
            SendMessage(Handle, WmNcLButtonDown, HtCaption, 0);
        };
    }

    protected float ApplyInitialDpiScale(float maximumScale = float.PositiveInfinity)
    {
        _ = Handle;
        var nativeScale = DeviceDpi / 96f;
        var scale = Math.Min(nativeScale, maximumScale);
        if (scale == 1f)
        {
            return 1f;
        }

        SuspendLayout();
        try
        {
            var logicalClientSize = ClientSize;
            ScaleLayoutTree(
                this,
                scale,
                fontScale: scale / nativeScale,
                scaleBounds: false);
            ClientSize = ScaleSize(logicalClientSize, scale);
        }
        finally
        {
            ResumeLayout(performLayout: true);
        }

        return scale;
    }

    private static void ScaleLayoutTree(
        Control control,
        float scale,
        float fontScale,
        bool scaleBounds)
    {
        control.Padding = ScalePadding(control.Padding, scale);
        control.Margin = ScalePadding(control.Margin, scale);
        if (scaleBounds && !control.AutoSize && control.Dock == DockStyle.None)
        {
            control.Size = ScaleSize(control.Size, scale);
        }
        if (!control.MinimumSize.IsEmpty)
        {
            control.MinimumSize = ScaleSize(control.MinimumSize, scale);
        }
        if (!control.MaximumSize.IsEmpty)
        {
            control.MaximumSize = ScaleSize(control.MaximumSize, scale);
        }

        if (control is TableLayoutPanel table)
        {
            foreach (RowStyle row in table.RowStyles)
            {
                if (row.SizeType == SizeType.Absolute)
                {
                    row.Height = ScaleValue(row.Height, scale);
                }
            }
            foreach (ColumnStyle column in table.ColumnStyles)
            {
                if (column.SizeType == SizeType.Absolute)
                {
                    column.Width = ScaleValue(column.Width, scale);
                }
            }
        }

        foreach (Control child in control.Controls)
        {
            ScaleLayoutTree(child, scale, fontScale, scaleBounds: true);
        }

        // Walk children before changing an inherited font so every control is
        // compacted exactly once when the screen cannot fit native DPI scaling.
        if (Math.Abs(fontScale - 1f) >= 0.01f)
        {
            control.Font = new Font(
                control.Font.FontFamily,
                Math.Max(1f, control.Font.Size * fontScale),
                control.Font.Style,
                control.Font.Unit,
                control.Font.GdiCharSet,
                control.Font.GdiVerticalFont);
        }
    }

    private static Padding ScalePadding(Padding padding, float factor) => new(
        ScaleValue(padding.Left, factor),
        ScaleValue(padding.Top, factor),
        ScaleValue(padding.Right, factor),
        ScaleValue(padding.Bottom, factor));

    private static Size ScaleSize(Size size, float factor) => new(
        ScaleValue(size.Width, factor),
        ScaleValue(size.Height, factor));

    private static float ScaleValue(float value, float factor) => value * factor;

    private static int ScaleValue(int value, float factor) =>
        (int)Math.Round(value * factor, MidpointRounding.AwayFromZero);

    protected override void OnSizeChanged(EventArgs eventArgs)
    {
        base.OnSizeChanged(eventArgs);
        if (Width <= 0 || Height <= 0)
        {
            return;
        }
        var radius = Math.Max(10, 12 * DeviceDpi / 96);
        using var path = RoundedRectangle(
            new Rectangle(0, 0, Width, Height),
            radius);
        var previous = Region;
        Region = new Region(path);
        previous?.Dispose();
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var pen = new Pen(Color.FromArgb(218, 218, 220));
        var radius = Math.Max(10, 12 * DeviceDpi / 96);
        using var path = RoundedRectangle(
            new Rectangle(0, 0, Width - 1, Height - 1),
            radius);
        eventArgs.Graphics.DrawPath(pen, path);
    }

    internal static GraphicsPath RoundedRectangle(Rectangle rectangle, float radius)
    {
        var diameter = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
        path.AddArc(
            rectangle.Right - diameter,
            rectangle.Bottom - diameter,
            diameter,
            diameter,
            0,
            90);
        path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(
        IntPtr window,
        int message,
        int parameter,
        int data);
}

internal sealed class MacIconButton : Button
{
    protected override bool ShowFocusCues => false;
}

internal sealed class HeroMetricsControl : Control
{
    private string rateText = "--";
    private string requestsText = "0.0";

    public HeroMetricsControl()
    {
        AccessibleName = "吞吐量与每分钟请求";
        DoubleBuffered = true;
    }

    public void SetValues(string rate, string requests)
    {
        rateText = rate;
        requestsText = requests;
        AccessibleDescription = $"{rate} token/s，{requests} 请求/分钟";
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        eventArgs.Graphics.Clear(Color.White);
        var primary = Color.FromArgb(36, 36, 38);
        var secondary = Color.FromArgb(128, 128, 132);
        var leftWidth = Width * 72 / 100;
        var mainSize = rateText.Length switch
        {
            >= 9 => Height * 0.42f,
            >= 7 => Height * 0.48f,
            _ => Height * 0.55f,
        };
        using var mainFont = new Font("Segoe UI Semibold", mainSize, GraphicsUnit.Pixel);
        using var unitFont = new Font("Microsoft YaHei UI", Height * 0.17f, GraphicsUnit.Pixel);
        using var requestFont = new Font("Segoe UI Semibold", Height * 0.30f, GraphicsUnit.Pixel);
        using var captionFont = new Font("Microsoft YaHei UI", Height * 0.18f, GraphicsUnit.Pixel);

        var mainSizeMeasured = TextRenderer.MeasureText(
            rateText,
            mainFont,
            Size.Empty,
            TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
        TextRenderer.DrawText(
            eventArgs.Graphics,
            rateText,
            mainFont,
            new Rectangle(0, 0, leftWidth, Height),
            primary,
            TextFormatFlags.Left |
            TextFormatFlags.VerticalCenter |
            TextFormatFlags.NoPadding |
            TextFormatFlags.SingleLine);
        TextRenderer.DrawText(
            eventArgs.Graphics,
            "token/s",
            unitFont,
            new Rectangle(
                Math.Min(leftWidth - 60, mainSizeMeasured.Width + Math.Max(7, Height / 9)),
                Height / 8,
                Math.Max(60, leftWidth - mainSizeMeasured.Width),
                Height * 3 / 4),
            secondary,
            TextFormatFlags.Left |
            TextFormatFlags.VerticalCenter |
            TextFormatFlags.NoPadding |
            TextFormatFlags.SingleLine);

        TextRenderer.DrawText(
            eventArgs.Graphics,
            requestsText,
            requestFont,
            new Rectangle(leftWidth, 0, Width - leftWidth, Height * 3 / 5),
            primary,
            TextFormatFlags.Right |
            TextFormatFlags.Bottom |
            TextFormatFlags.NoPadding |
            TextFormatFlags.SingleLine);
        TextRenderer.DrawText(
            eventArgs.Graphics,
            "请求/分钟",
            captionFont,
            new Rectangle(leftWidth, Height * 3 / 5, Width - leftWidth, Height * 2 / 5),
            secondary,
            TextFormatFlags.Right |
            TextFormatFlags.Top |
            TextFormatFlags.NoPadding |
            TextFormatFlags.SingleLine);
    }
}

internal sealed class AmbientStatusControl : Control
{
    private readonly Color secondary = Color.FromArgb(128, 128, 132);
    private string message = "正在连接";
    private Color statusColor = Color.FromArgb(255, 149, 0);

    public AmbientStatusControl()
    {
        AccessibleName = $"{OplFleetAgentProtocol.GatewayShortName} 高级连接设置";
        AccessibleRole = AccessibleRole.PushButton;
        Cursor = Cursors.Hand;
        DoubleBuffered = true;
        TabStop = true;
    }

    public Uri? Endpoint { get; private set; }

    public void SetConnection(AmbientOpsConnectionStatus connection)
    {
        message = connection.Message;
        Endpoint = connection.Endpoint;
        statusColor = connection.Kind switch
        {
            AmbientOpsConnectionKind.Live => Color.FromArgb(52, 199, 89),
            AmbientOpsConnectionKind.Ready or AmbientOpsConnectionKind.NeedsToken or
                AmbientOpsConnectionKind.Pairing or AmbientOpsConnectionKind.Discovering or
                AmbientOpsConnectionKind.Pushing =>
                Color.FromArgb(255, 149, 0),
            AmbientOpsConnectionKind.Disabled => secondary,
            _ => Color.FromArgb(255, 59, 48),
        };
        AccessibleDescription = message;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        eventArgs.Graphics.Clear(Color.White);
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var scale = Height / 50f;
        using var iconFont = new Font("Segoe MDL2 Assets", 13 * scale, GraphicsUnit.Pixel);
        using var titleFont = new Font("Segoe UI Semibold", 13 * scale, GraphicsUnit.Pixel);
        using var statusFont = new Font("Microsoft YaHei UI", 12 * scale, GraphicsUnit.Pixel);
        using var chevronFont = new Font("Segoe MDL2 Assets", 11 * scale, GraphicsUnit.Pixel);
        var centerFlags = TextFormatFlags.VerticalCenter |
            TextFormatFlags.NoPadding |
            TextFormatFlags.SingleLine;
        TextRenderer.DrawText(
            eventArgs.Graphics,
            "\uE7F4",
            iconFont,
            new Rectangle((int)(16 * scale), 0, (int)(22 * scale), Height),
            secondary,
            centerFlags | TextFormatFlags.Left);
        TextRenderer.DrawText(
            eventArgs.Graphics,
            OplFleetAgentProtocol.GatewayShortName,
            titleFont,
            new Rectangle((int)(40 * scale), 0, (int)(90 * scale), Height),
            Color.FromArgb(36, 36, 38),
            centerFlags | TextFormatFlags.Left);

        var dotSize = Math.Max(6, (int)(7 * scale));
        var dotX = (int)(132 * scale);
        var dotY = (Height - dotSize) / 2;
        using var dotBrush = new SolidBrush(statusColor);
        eventArgs.Graphics.FillEllipse(dotBrush, dotX, dotY, dotSize, dotSize);
        var statusLeft = dotX + dotSize + Math.Max(6, (int)(6 * scale));
        var chevronWidth = Math.Max(24, (int)(28 * scale));
        TextRenderer.DrawText(
            eventArgs.Graphics,
            message,
            statusFont,
            new Rectangle(statusLeft, 0, Width - statusLeft - chevronWidth, Height),
            secondary,
            centerFlags | TextFormatFlags.Left | TextFormatFlags.EndEllipsis);
        TextRenderer.DrawText(
            eventArgs.Graphics,
            "\uE76C",
            chevronFont,
            new Rectangle(Width - chevronWidth, 0, chevronWidth, Height),
            secondary,
            centerFlags | TextFormatFlags.HorizontalCenter);

        if (Focused)
        {
            using var focusPen = new Pen(Color.FromArgb(0, 95, 184));
            eventArgs.Graphics.DrawRectangle(focusPen, 1, 1, Width - 3, Height - 3);
        }
    }

    protected override void OnMouseUp(MouseEventArgs eventArgs)
    {
        base.OnMouseUp(eventArgs);
        if (eventArgs.Button == MouseButtons.Left && ClientRectangle.Contains(eventArgs.Location))
        {
            OnClick(EventArgs.Empty);
        }
    }

    protected override void OnKeyDown(KeyEventArgs eventArgs)
    {
        base.OnKeyDown(eventArgs);
        if (eventArgs.KeyCode is Keys.Enter or Keys.Space)
        {
            OnClick(EventArgs.Empty);
            eventArgs.Handled = true;
        }
    }
}

internal sealed class MetricWindowSelector : Control
{
    private static readonly (string Label, int Seconds)[] Choices =
    [
        ("1 分钟", 60),
        ("5 分钟", 300),
        ("30 分钟", 1_800),
        ("1 小时", 3_600),
    ];

    private readonly Color surface = Color.FromArgb(238, 238, 240);
    private readonly Color selected = Color.FromArgb(0, 122, 255);
    private readonly Color primary = Color.FromArgb(36, 36, 38);
    private readonly Color separator = Color.FromArgb(210, 210, 212);
    private int selectedSeconds = 60;

    public MetricWindowSelector()
    {
        AccessibleName = "统计窗口";
        AccessibleRole = AccessibleRole.PageTabList;
        Cursor = Cursors.Hand;
        DoubleBuffered = true;
        Font = new Font("Microsoft YaHei UI", 9.5f);
        Height = 26;
        MinimumSize = new Size(260, 26);
        TabStop = true;
    }

    public event Action<int>? SelectedSecondsChanged;

    public int SelectedSeconds
    {
        get => selectedSeconds;
        set
        {
            if (!Choices.Any(choice => choice.Seconds == value) || selectedSeconds == value)
            {
                return;
            }
            selectedSeconds = value;
            Invalidate();
        }
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        eventArgs.Graphics.TextRenderingHint =
            System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        using var backgroundPath = RoundedPopupForm.RoundedRectangle(
            new Rectangle(0, 0, Width - 1, Height - 1),
            Math.Max(7, Height * 0.27f));
        using var backgroundBrush = new SolidBrush(surface);
        eventArgs.Graphics.FillPath(backgroundBrush, backgroundPath);

        var itemWidth = Width / Choices.Length;
        for (var index = 0; index < Choices.Length; index++)
        {
            var choice = Choices[index];
            var left = index * itemWidth;
            var right = index == Choices.Length - 1 ? Width : (index + 1) * itemWidth;
            var itemRectangle = new Rectangle(left, 0, right - left, Height);
            if (choice.Seconds == selectedSeconds)
            {
                using var selectedPath = RoundedPopupForm.RoundedRectangle(
                    new Rectangle(left, 0, right - left, Height - 1),
                    Math.Max(7, Height * 0.27f));
                using var selectedBrush = new SolidBrush(selected);
                eventArgs.Graphics.FillPath(selectedBrush, selectedPath);
            }
            else if (index > 0 && Choices[index - 1].Seconds != selectedSeconds)
            {
                using var separatorPen = new Pen(separator);
                eventArgs.Graphics.DrawLine(
                    separatorPen,
                    left,
                    Math.Max(4, Height * 0.23f),
                    left,
                    Height - Math.Max(5, Height * 0.27f));
            }

            TextRenderer.DrawText(
                eventArgs.Graphics,
                choice.Label,
                Font,
                itemRectangle,
                choice.Seconds == selectedSeconds ? Color.White : primary,
                TextFormatFlags.HorizontalCenter |
                TextFormatFlags.VerticalCenter |
                TextFormatFlags.NoPadding |
                TextFormatFlags.SingleLine);
        }

        if (Focused)
        {
            using var focusPen = new Pen(Color.FromArgb(0, 95, 184));
            eventArgs.Graphics.DrawPath(focusPen, backgroundPath);
        }
    }

    protected override void OnMouseUp(MouseEventArgs eventArgs)
    {
        base.OnMouseUp(eventArgs);
        if (eventArgs.Button != MouseButtons.Left || !ClientRectangle.Contains(eventArgs.Location))
        {
            return;
        }
        var index = Math.Min(Choices.Length - 1, eventArgs.X * Choices.Length / Width);
        SelectChoice(index);
    }

    protected override bool IsInputKey(Keys keyData) =>
        keyData is Keys.Left or Keys.Right || base.IsInputKey(keyData);

    protected override void OnKeyDown(KeyEventArgs eventArgs)
    {
        base.OnKeyDown(eventArgs);
        var current = Array.FindIndex(Choices, choice => choice.Seconds == selectedSeconds);
        if (eventArgs.KeyCode == Keys.Left)
        {
            SelectChoice(Math.Max(0, current - 1));
            eventArgs.Handled = true;
        }
        else if (eventArgs.KeyCode == Keys.Right)
        {
            SelectChoice(Math.Min(Choices.Length - 1, current + 1));
            eventArgs.Handled = true;
        }
    }

    private void SelectChoice(int index)
    {
        var next = Choices[index].Seconds;
        if (next == selectedSeconds)
        {
            return;
        }
        selectedSeconds = next;
        Invalidate();
        SelectedSecondsChanged?.Invoke(next);
    }
}

internal sealed class RefreshCadenceButton : Control
{
    private static readonly (string Label, int Seconds)[] Choices =
    [
        ("5 秒", 5),
        ("15 秒", 15),
        ("30 秒", 30),
        ("1 分钟", 60),
    ];

    private readonly ContextMenuStrip menu = new();
    private int seconds = 5;

    public RefreshCadenceButton()
    {
        AccessibleName = "自动刷新间隔";
        AccessibleRole = AccessibleRole.ComboBox;
        Cursor = Cursors.Hand;
        DoubleBuffered = true;
        Font = new Font("Microsoft YaHei UI", 9f);
        Size = new Size(72, 28);
        TabStop = true;
        foreach (var choice in Choices)
        {
            var item = menu.Items.Add(choice.Label);
            item.Tag = choice.Seconds;
            item.Click += (_, _) => SetSeconds((int)item.Tag, notify: true);
        }
    }

    public event Action<int>? SecondsChanged;

    public void SetSeconds(int value, bool notify = false)
    {
        if (!Choices.Any(choice => choice.Seconds == value))
        {
            value = 5;
        }
        if (seconds == value)
        {
            return;
        }
        seconds = value;
        Invalidate();
        if (notify)
        {
            SecondsChanged?.Invoke(value);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            menu.Dispose();
        }
        base.Dispose(disposing);
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var path = RoundedPopupForm.RoundedRectangle(
            new Rectangle(0, 0, Width - 1, Height - 1),
            Math.Max(7, Height * 0.25f));
        using var brush = new SolidBrush(Color.FromArgb(238, 238, 240));
        eventArgs.Graphics.FillPath(brush, path);

        var label = Choices.First(choice => choice.Seconds == seconds).Label;
        TextRenderer.DrawText(
            eventArgs.Graphics,
            label,
            Font,
            new Rectangle(
                Math.Max(10, Height * 5 / 14),
                0,
                Width - Math.Max(30, Height),
                Height),
            Color.FromArgb(36, 36, 38),
            TextFormatFlags.Left |
            TextFormatFlags.VerticalCenter |
            TextFormatFlags.NoPadding |
            TextFormatFlags.SingleLine);

        using var pen = new Pen(Color.FromArgb(70, 70, 72), 1.25f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
        };
        var centerX = Width - Math.Max(13, Height * 13 / 28);
        var centerY = Height / 2;
        var chevronWidth = Math.Max(3, Height * 3 / 28);
        var chevronGap = Math.Max(3, Height * 3 / 28);
        eventArgs.Graphics.DrawLines(
            pen,
            new Point[]
            {
                new Point(centerX - chevronWidth, centerY - chevronGap),
                new Point(centerX, centerY - chevronGap - chevronWidth),
                new Point(centerX + chevronWidth, centerY - chevronGap),
            });
        eventArgs.Graphics.DrawLines(
            pen,
            new Point[]
            {
                new Point(centerX - chevronWidth, centerY + chevronGap),
                new Point(centerX, centerY + chevronGap + chevronWidth),
                new Point(centerX + chevronWidth, centerY + chevronGap),
            });

        if (Focused)
        {
            using var focusPen = new Pen(Color.FromArgb(0, 95, 184));
            eventArgs.Graphics.DrawPath(focusPen, path);
        }
    }

    protected override void OnMouseUp(MouseEventArgs eventArgs)
    {
        base.OnMouseUp(eventArgs);
        if (eventArgs.Button == MouseButtons.Left && ClientRectangle.Contains(eventArgs.Location))
        {
            menu.Show(this, new Point(0, Height));
        }
    }

    protected override void OnKeyDown(KeyEventArgs eventArgs)
    {
        base.OnKeyDown(eventArgs);
        if (eventArgs.KeyCode is Keys.Enter or Keys.Space)
        {
            menu.Show(this, new Point(0, Height));
            eventArgs.Handled = true;
        }
    }
}
