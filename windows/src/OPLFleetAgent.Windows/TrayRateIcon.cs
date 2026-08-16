using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace OPLFleetAgent.WindowsApp;

internal static class TrayRateIcon
{
    private const int IconSize = 32;

    public static Icon Create(double tokensPerSecond)
    {
        var label = Format(tokensPerSecond);
        using var bitmap = new Bitmap(IconSize, IconSize);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.Transparent);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;

        using var background = RoundedRectangle(
            new Rectangle(1, 1, IconSize - 2, IconSize - 2),
            7f);
        using var backgroundBrush = new SolidBrush(Color.FromArgb(0, 122, 255));
        graphics.FillPath(backgroundBrush, background);

        var fontSize = label.Length switch
        {
            >= 3 => 11f,
            2 => 13f,
            _ => 15f,
        };
        using var font = new Font("Segoe UI Semibold", fontSize, FontStyle.Bold, GraphicsUnit.Pixel);
        using var textBrush = new SolidBrush(Color.White);
        using var format = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
            FormatFlags = StringFormatFlags.NoWrap,
        };
        graphics.DrawString(label, font, textBrush, new RectangleF(0, 0, IconSize, IconSize), format);

        var handle = bitmap.GetHicon();
        try
        {
            return (Icon)Icon.FromHandle(handle).Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    internal static string Format(double value)
    {
        var rate = double.IsFinite(value) ? Math.Max(0, value) : 0;
        if (rate >= 99_500_000)
        {
            return "99+";
        }
        if (rate >= 999_500)
        {
            return $"{Math.Round(rate / 1_000_000):0}M";
        }
        if (rate >= 99_500)
        {
            return "99+";
        }
        if (rate >= 999.5)
        {
            return $"{Math.Round(rate / 1_000):0}K";
        }
        return $"{Math.Min(999, Math.Round(rate)):0}";
    }

    private static GraphicsPath RoundedRectangle(Rectangle rectangle, float radius)
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
    private static extern bool DestroyIcon(IntPtr icon);
}
