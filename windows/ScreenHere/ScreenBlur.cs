using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace ScreenHere;

/// Frosts every display the pointer is not on, so what sits on the screens
/// beside you cannot be read from across the desk. The frost is the desktop
/// manager's own blur of what is behind a window: nothing is captured,
/// nothing is recorded, and what is behind it stays live and in place.
internal static class ScreenBlur
{
    /// A screen stays clear for a moment after the pointer leaves it:
    /// glancing at the other screen must not frost it in your face.
    public const double Delay = 1.5;
    /// How often the pointer is looked at. Reading it costs nothing, and the
    /// work only happens when the answer changed.
    private const double Tick = 0.2;
    /// The shade the blur is tinted with, 0xAABBGGRR: dark enough that a
    /// window behind it is a shape, not a sentence.
    private const uint Tint = 0x99181414;

    private static readonly Dictionary<string, Window> Covers = new();
    /// When the pointer was last on each display, by device name.
    private static readonly Dictionary<string, DateTime> LastSeen = new();
    private static HashSet<string> covered = [];
    private static DispatcherTimer? timer;

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

    public static void Update()
    {
        if (!Settings.Current.BlurOtherScreens)
        {
            Stop();
            LastSeen.Clear();
            return;
        }
        if (timer != null) return;
        timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Tick) };
        timer.Tick += (_, _) => Sample();
        timer.Start();
        Sample();
    }

    /// Takes the frost off every screen — at quit, so no overlay outlives the
    /// app that owns it.
    public static void Stop()
    {
        timer?.Stop();
        timer = null;
        foreach (var cover in Covers.Values) cover.Close();
        Covers.Clear();
        covered = [];
    }

    private static void Sample()
    {
        var displays = Displays.All();
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
            cover.Close();
        }
        foreach (var display in displays.Where(d => wanted.Contains(d.Device) && !Covers.ContainsKey(d.Device)))
        {
            Covers[display.Device] = Cover(display);
        }
    }

    /// A window over the whole display, above everything, that no click can
    /// reach. Placed before it is shown: a cover must never be seen arriving
    /// somewhere else first.
    private static Window Cover(DisplayInfo display)
    {
        var window = new Window
        {
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            ShowActivated = false,
            Topmost = true,
            IsHitTestVisible = false,
            WindowStartupLocation = WindowStartupLocation.Manual,
            // The blur is the desktop manager's, behind the window: anything
            // WPF paints here would hide it.
            Background = Brushes.Transparent,
        };
        var handle = new WindowInteropHelper(window).EnsureHandle();
        Native.AddExStyle(handle, Native.WS_EX_TRANSPARENT | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
        // Windows too old to blur behind a window gets a flat shade, which
        // hides as much and is the point of the feature.
        if (!Native.SetAcrylic(handle, Tint)) window.Background = new SolidColorBrush(Color.FromRgb(16, 16, 20));
        Native.SetWindowPos(handle, IntPtr.Zero, (int)display.Bounds.X, (int)display.Bounds.Y,
                            (int)display.Bounds.Width, (int)display.Bounds.Height,
                            Native.SWP_NOACTIVATE | Native.SWP_NOZORDER);
        window.Show();
        return window;
    }
}
