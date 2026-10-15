using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Drawing = System.Drawing;

namespace ScreenHere;

/// Frosts the screen, so what is on it cannot be read from across the desk.
/// Win+Shift+9 pulls the frost over every display at once, and an option
/// frosts the displays the pointer is not on by itself. The frost is a
/// blurred picture of the display, taken as the cover comes down, kept in
/// memory and thrown away with it — the same as the Mac does.
///
/// Not the desktop manager's blur behind the window, which is what this used
/// to be: recent Windows builds ignore that call, and a cover that asked for
/// it and did not get it is an opaque window — every screen went black
/// instead of frosting.
internal static class ScreenBlur
{
    /// A screen stays clear for a moment after the pointer leaves it:
    /// glancing at the other screen must not frost it in your face.
    public const double Delay = 1.5;
    /// How often the pointer is looked at. Reading it costs nothing, and the
    /// work only happens when the answer changed.
    private const double Tick = 0.2;
    private static readonly Duration FadeIn = TimeSpan.FromSeconds(0.35);
    private static readonly Duration FadeOut = TimeSpan.FromSeconds(0.18);
    /// The shade over the blur, dark enough that a window behind it is a
    /// shape, not a sentence.
    private static readonly Color Shade = Color.FromArgb(0x99, 0x14, 0x14, 0x18);
    /// When the screen cannot be pictured at all — a locked session, a driver
    /// that refuses — the cover is a flat veil instead, which hides as much.
    private static readonly Color Flat = Color.FromArgb(0xF2, 0x10, 0x10, 0x14);
    /// The blur is pixels thrown away and put back smoothly: an eighth of the
    /// width, drawn over the whole of it.
    private const int Grain = 8;

    private static readonly Dictionary<string, Window> Covers = new();
    /// When the pointer was last on each display, by device name.
    private static readonly Dictionary<string, DateTime> LastSeen = new();
    private static HashSet<string> covered = [];
    private static DispatcherTimer? timer;

    /// The frost is down over everything, until the shortcut again.
    public static bool IsCurtain { get; private set; }

    /// The displays to cover: every one the pointer has been away from for
    /// `delay`. Nothing with a single display — there is no other screen —
    /// and nothing while the pointer is on none of them, which is no reason
    /// to frost the one being used.
    public static HashSet<string> Covered(IReadOnlyList<DisplayInfo> displays, Point pointer,
                                          IReadOnlyDictionary<string, DateTime> lastSeen,
                                          DateTime now, double delay)
    {
        if (displays.Count < 2) return [];
        var under = displays.FirstOrDefault(d => Holds(d.Bounds, pointer));
        if (under == null) return [];
        return displays
            .Where(d => d.Device != under.Device
                        && (now - lastSeen.GetValueOrDefault(d.Device, DateTime.MinValue)).TotalSeconds >= delay)
            .Select(d => d.Device)
            .ToHashSet();
    }

    /// The right and bottom edges belong to the next display, as Windows has
    /// it — the same rule the captures follow.
    private static bool Holds(Rect bounds, Point point) =>
        point.X >= bounds.X && point.X < bounds.Right && point.Y >= bounds.Y && point.Y < bounds.Bottom;

    /// Win+Shift+9: the frost over every display, and off again.
    public static void ToggleCurtain()
    {
        if (!Settings.Current.BlurEnabled) return;
        IsCurtain = !IsCurtain;
        Update();
    }

    /// Brings the pointer timer and the covers in line with what is switched
    /// on.
    public static void Update()
    {
        var settings = Settings.Current;
        if (!settings.BlurEnabled) IsCurtain = false;

        if (settings is { BlurEnabled: true, BlurOtherScreens: true })
        {
            if (timer == null)
            {
                timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Tick) };
                timer.Tick += (_, _) => Sample();
                timer.Start();
            }
        }
        else
        {
            timer?.Stop();
            timer = null;
            LastSeen.Clear();
        }
        Sample();
    }

    /// Takes the frost off every screen — at quit, so no cover outlives the
    /// app that owns it.
    public static void Stop()
    {
        timer?.Stop();
        timer = null;
        IsCurtain = false;
        foreach (var cover in Covers.Values) cover.Close();
        Covers.Clear();
        covered = [];
    }

    private static void Sample()
    {
        var displays = Displays.All();
        var settings = Settings.Current;
        if (!settings.BlurEnabled) { Apply([], displays); return; }
        if (IsCurtain) { Apply(displays.Select(d => d.Device).ToHashSet(), displays); return; }
        if (!settings.BlurOtherScreens) { Apply([], displays); return; }

        var pointer = Displays.Pointer();
        var now = DateTime.UtcNow;
        if (displays.FirstOrDefault(d => Holds(d.Bounds, pointer)) is { } under) LastSeen[under.Device] = now;
        Apply(Covered(displays, pointer, LastSeen, now, Delay), displays);
    }

    private static void Apply(HashSet<string> wanted, IReadOnlyList<DisplayInfo> displays)
    {
        if (wanted.SetEquals(covered)) return;
        covered = wanted;
        foreach (var (device, cover) in Covers.Where(c => !wanted.Contains(c.Key)).ToList())
        {
            Covers.Remove(device);
            Fade(cover, 0, FadeOut, cover.Close);
        }
        foreach (var display in displays.Where(d => wanted.Contains(d.Device) && !Covers.ContainsKey(d.Device)))
        {
            Covers[display.Device] = Cover(display);
        }
    }

    /// The frost fades, the sharp picture underneath does not: fading the
    /// whole cover would fade it to the opaque window behind it, which is
    /// black. What fades is kept on the window's own Tag.
    private static void Fade(Window window, double to, Duration over, Action? then = null)
    {
        if (window.Tag is not UIElement shade) return;
        var fade = new DoubleAnimation(to, over) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } };
        if (then != null) fade.Completed += (_, _) => then();
        shade.BeginAnimation(UIElement.OpacityProperty, fade);
    }

    /// A window over the whole display, above everything, that no click can
    /// reach. Placed before it is shown: a cover must never be seen arriving
    /// somewhere else first.
    ///
    /// The picture is taken first, because the window is opaque when there is
    /// one to show and see-through when there is not, and that cannot be
    /// changed once the window has a handle.
    private static Window Cover(DisplayInfo display)
    {
        var shot = Shot(display.Bounds);
        var window = new Window
        {
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            ShowActivated = false,
            Topmost = true,
            IsHitTestVisible = false,
            WindowStartupLocation = WindowStartupLocation.Manual,
            AllowsTransparency = shot == null,
            Background = shot == null ? Brushes.Transparent : Brushes.Black,
        };
        var handle = new WindowInteropHelper(window).EnsureHandle();
        Native.AddExStyle(handle, Native.WS_EX_TRANSPARENT | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);

        var layers = new Grid();
        if (shot is { } pictures)
        {
            // The sharp picture goes up at once, so the cover appearing cannot
            // be seen: it is what the screen already shows. The frost fades in
            // over it.
            layers.Children.Add(new Image { Source = pictures.Sharp, Stretch = Stretch.Fill });
            var frost = new Grid { Opacity = 0 };
            var blurred = new Image { Source = pictures.Frosted, Stretch = Stretch.Fill };
            RenderOptions.SetBitmapScalingMode(blurred, BitmapScalingMode.HighQuality);
            frost.Children.Add(blurred);
            frost.Children.Add(new Border { Background = new SolidColorBrush(Shade) });
            layers.Children.Add(frost);
            window.Tag = frost;
        }
        else
        {
            var flat = new Border { Background = new SolidColorBrush(Flat), Opacity = 0 };
            layers.Children.Add(flat);
            window.Tag = flat;
        }
        window.Content = layers;

        Native.SetWindowPos(handle, IntPtr.Zero, (int)display.Bounds.X, (int)display.Bounds.Y,
                            (int)display.Bounds.Width, (int)display.Bounds.Height,
                            Native.SWP_NOACTIVATE | Native.SWP_NOZORDER);
        window.Show();
        Fade(window, 1, FadeIn);
        return window;
    }

    /// The display as it is, and the same thing with the detail thrown away.
    /// Null when the screen cannot be read at all.
    private static (ImageSource Sharp, ImageSource Frosted)? Shot(Rect bounds)
    {
        try
        {
            using var whole = Capture.Grab(bounds);
            using var small = new Drawing.Bitmap(Math.Max(1, whole.Width / Grain),
                                                 Math.Max(1, whole.Height / Grain));
            using (var graphics = Drawing.Graphics.FromImage(small))
            {
                graphics.InterpolationMode = Drawing.Drawing2D.InterpolationMode.HighQualityBilinear;
                graphics.DrawImage(whole, 0, 0, small.Width, small.Height);
            }
            return (Source(whole), Source(small));
        }
        catch
        {
            return null;
        }
    }

    /// A GDI bitmap as something the interface can draw. The copy is frozen,
    /// so the handle it came from can go straight back.
    private static ImageSource Source(Drawing.Bitmap bitmap)
    {
        var handle = bitmap.GetHbitmap();
        try
        {
            var source = Imaging.CreateBitmapSourceFromHBitmap(handle, IntPtr.Zero, Int32Rect.Empty,
                                                               BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();
            return source;
        }
        finally
        {
            Native.DeleteObject(handle);
        }
    }
}
