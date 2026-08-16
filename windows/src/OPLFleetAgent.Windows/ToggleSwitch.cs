using System.Drawing.Drawing2D;

namespace OPLFleetAgent.WindowsApp;

internal sealed class ToggleSwitch : CheckBox
{
    private static readonly Color TrackOff = Color.FromArgb(224, 224, 226);
    private static readonly Color TrackOn = Color.FromArgb(0, 122, 255);
    private static readonly Color Thumb = Color.White;

    public ToggleSwitch()
    {
        AutoSize = false;
        Cursor = Cursors.Hand;
        Size = new Size(44, 22);
        SetStyle(
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.ResizeRedraw |
            ControlStyles.UserPaint,
            true);
    }

    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        eventArgs.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        eventArgs.Graphics.Clear(Parent?.BackColor ?? BackColor);
        var track = new Rectangle(0, 2, Width - 1, Height - 5);
        using var path = RoundedRectangle(track, track.Height / 2f);
        using var trackBrush = new SolidBrush(Checked ? TrackOn : TrackOff);
        eventArgs.Graphics.FillPath(trackBrush, path);

        var diameter = track.Height - 4;
        var x = Checked ? track.Right - diameter - 2 : track.Left + 2;
        using var thumbBrush = new SolidBrush(Thumb);
        eventArgs.Graphics.FillEllipse(thumbBrush, x, track.Top + 2, diameter, diameter);

        if (Focused)
        {
            using var focusPen = new Pen(Color.FromArgb(0, 95, 184));
            eventArgs.Graphics.DrawRectangle(focusPen, 0, 0, Width - 1, Height - 1);
        }
    }

    protected override void OnCheckedChanged(EventArgs eventArgs)
    {
        base.OnCheckedChanged(eventArgs);
        Invalidate();
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
}
