using System.Runtime.InteropServices;
using Drawing = System.Drawing;
using Forms = System.Windows.Forms;

namespace ScreenHere;

/// The icon in the notification area: a screen with a pointer in it — the
/// app's whole idea at 16 pixels. Drawn in code so it is white on a dark
/// taskbar and black on a light one, at whatever size the display asks for.
internal sealed class Tray
{
    public static Tray Shared { get; } = new();

    private Forms.NotifyIcon? icon;
    private IntPtr iconHandle;
    /// When the panel last closed because something else was clicked. A click
    /// on the icon closes the panel before it reaches the icon; without this
    /// the same click would open it again.
    public DateTime PanelClosedAt { get; set; }

    public void Start()
    {
        if (!Settings.Current.TrayIconHidden) Show();
    }

    /// The app keeps running and the shortcuts keep working; opening
    /// ScreenHere again brings the icon back.
    public void SetHidden(bool hidden)
    {
        Settings.Current.TrayIconHidden = hidden;
        Settings.Current.Save();
        if (hidden) Hide();
        else Show();
    }

    private void Show()
    {
        if (icon != null) return;
        icon = new Forms.NotifyIcon { Text = "ScreenHere", Icon = Draw(), Visible = true };
        icon.MouseUp += (_, e) =>
        {
            if (e.Button is not (Forms.MouseButtons.Left or Forms.MouseButtons.Right)) return;
            if (!PanelWindow.IsOpen && (DateTime.Now - PanelClosedAt).TotalMilliseconds < 250) return;
            PanelWindow.Toggle();
        };
    }

    private void Hide()
    {
        if (icon == null) return;
        icon.Visible = false;
        icon.Dispose();
        icon = null;
        Release();
    }

    /// Redrawn when Windows switches between light and dark.
    public void Refresh()
    {
        if (icon == null) return;
        var old = iconHandle;
        iconHandle = IntPtr.Zero;
        icon.Icon = Draw();
        if (old != IntPtr.Zero) DestroyIcon(old);
    }

    public void Dispose() => Hide();

    private Drawing.Icon Draw()
    {
        var side = Forms.SystemInformation.SmallIconSize.Width;
        using var bitmap = DrawGlyph(side, Theme.TaskbarIsDark ? Drawing.Color.White : Drawing.Color.Black);
        iconHandle = bitmap.GetHicon();
        return Drawing.Icon.FromHandle(iconHandle);
    }

    /// Deliberately minimal: a hairline frame and a small solid pointer.
    internal static Drawing.Bitmap DrawGlyph(int side, Drawing.Color color)
    {
        var bitmap = new Drawing.Bitmap(side, side, Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        graphics.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
        graphics.PixelOffsetMode = Drawing.Drawing2D.PixelOffsetMode.HighQuality;
        var unit = side / 16f;

        using var pen = new Drawing.Pen(color, 1.25f * unit);
        using var frame = Rounded(new Drawing.RectangleF(1.1f * unit, 2.9f * unit, 13.8f * unit, 10.2f * unit), 2.2f * unit);
        graphics.DrawPath(pen, frame);

        var height = 7.2f * unit;
        var scale = height / (float)Glyph.PointerSize.Height;
        var origin = new Drawing.PointF(6.3f * unit, 4.4f * unit);
        var points = Glyph.PointerOutline
            .Select(p => new Drawing.PointF(origin.X + (float)p.X * scale, origin.Y + (float)p.Y * scale)).ToArray();
        using var brush = new Drawing.SolidBrush(color);
        graphics.FillPolygon(brush, points);
        return bitmap;
    }

    private static Drawing.Drawing2D.GraphicsPath Rounded(Drawing.RectangleF r, float radius)
    {
        var d = radius * 2;
        var path = new Drawing.Drawing2D.GraphicsPath();
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    private void Release()
    {
        if (iconHandle != IntPtr.Zero) DestroyIcon(iconHandle);
        iconHandle = IntPtr.Zero;
    }

    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr handle);
}
