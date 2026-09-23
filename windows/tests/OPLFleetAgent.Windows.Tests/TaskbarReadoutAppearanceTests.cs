using OPLFleetAgent.WindowsApp;

namespace OPLFleetAgent.Windows.Tests;

public sealed class TaskbarReadoutAppearanceTests
{
    [Theory]
    [InlineData((int)TaskbarEdge.Bottom, 96, 14)]
    [InlineData((int)TaskbarEdge.Bottom, 144, 21)]
    [InlineData((int)TaskbarEdge.Top, 192, 28)]
    [InlineData((int)TaskbarEdge.Left, 96, 11)]
    [InlineData((int)TaskbarEdge.Right, 192, 22)]
    public void FontPixelSizeScalesWithTaskbarDpi(
        int edgeValue,
        int dpi,
        float expectedPixels)
    {
        Assert.Equal(
            expectedPixels,
            TaskbarReadoutAppearance.FontPixelSize((TaskbarEdge)edgeValue, dpi));
    }

    [Fact]
    public void InvalidDpiFallsBackToNinetySix()
    {
        Assert.Equal(
            14,
            TaskbarReadoutAppearance.FontPixelSize(TaskbarEdge.Bottom, 0));
    }

    [Fact]
    public void UsesSemiboldFamilyForNativeTaskbarText()
    {
        Assert.Equal(FontStyle.Regular, TaskbarReadoutAppearance.TextFontStyle);
        Assert.Equal("Segoe UI Semibold", TaskbarReadoutAppearance.TextFontFamily);
    }

    [Theory]
    [InlineData(true, 0, 0, 0)]
    [InlineData(false, 255, 255, 255)]
    public void TextColorTracksTaskbarTheme(
        bool lightTheme,
        int red,
        int green,
        int blue)
    {
        var color = TaskbarReadoutAppearance.TextColor(lightTheme);

        Assert.Equal(red, color.R);
        Assert.Equal(green, color.G);
        Assert.Equal(blue, color.B);
    }

    [Theory]
    [InlineData((int)TaskbarEdge.Bottom, "12.5K t/s")]
    [InlineData((int)TaskbarEdge.Left, "12.5K\nt/s")]
    public void DisplayTextKeepsReadoutCompact(int edgeValue, string expected)
    {
        Assert.Equal(
            expected.Replace("\n", Environment.NewLine, StringComparison.Ordinal),
            TaskbarReadoutAppearance.DisplayText(
                "12.5K t/s",
                (TaskbarEdge)edgeValue));
    }

    [Fact]
    public void RenderHasTransparentCornersAndReadableBadge()
    {
        using var bitmap = TaskbarReadoutAppearance.Render(
            new Size(128, 32),
            "12.5K t/s",
            TaskbarEdge.Bottom,
            96,
            Color.Black);

        Assert.Equal(
            TaskbarReadoutAppearance.TransparentHitTestAlpha,
            bitmap.GetPixel(0, 0).A);
        Assert.Equal(255, bitmap.GetPixel(bitmap.Width / 2, bitmap.Height / 2).A);

        var alphaValues = Enumerable.Range(0, bitmap.Height)
            .SelectMany(y => Enumerable.Range(0, bitmap.Width)
                .Select(x => bitmap.GetPixel(x, y).A))
            .ToArray();
        Assert.Contains(alphaValues, alpha => alpha > 128);
        Assert.True(alphaValues.Count(alpha => alpha > 128) > alphaValues.Length / 2);
    }

    [Theory]
    [InlineData(128, 32, (int)TaskbarEdge.Bottom, 96)]
    [InlineData(192, 48, (int)TaskbarEdge.Bottom, 144)]
    [InlineData(256, 64, (int)TaskbarEdge.Top, 192)]
    [InlineData(40, 52, (int)TaskbarEdge.Left, 96)]
    public void MaximumReadoutKeepsClearSpaceAtSupportedDpi(
        int width,
        int height,
        int edgeValue,
        int dpi)
    {
        using var bitmap = TaskbarReadoutAppearance.Render(
            new Size(width, height),
            "99.9M t/s",
            (TaskbarEdge)edgeValue,
            dpi,
            Color.Black);

        var ink = Enumerable.Range(0, bitmap.Height)
            .SelectMany(y => Enumerable.Range(0, bitmap.Width)
                .Where(x => bitmap.GetPixel(x, y).A >
                    TaskbarReadoutAppearance.TransparentHitTestAlpha)
                .Select(x => new Point(x, y)))
            .ToArray();

        Assert.NotEmpty(ink);
        Assert.InRange(ink.Min(point => point.X), 1, bitmap.Width - 2);
        Assert.InRange(ink.Max(point => point.X), 1, bitmap.Width - 2);
        Assert.InRange(ink.Min(point => point.Y), 1, bitmap.Height - 2);
        Assert.InRange(ink.Max(point => point.Y), 1, bitmap.Height - 2);
    }
}
