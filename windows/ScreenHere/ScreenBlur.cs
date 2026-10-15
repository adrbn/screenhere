using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace ScreenHere;

/// Frosts the screen, so what is on it cannot be read from across the desk.
/// Win+Shift+9 pulls the frost over every display at once, and an option
/// frosts the displays the pointer is not on by itself. The frost is the
/// desktop manager's own blur of what is behind a window: nothing is
/// captured, nothing is recorded, and what is behind it stays live.
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
    /// Windows too old to blur behind a window gets this instead, which hides
    /// as much and is the point of the feature.
    private static readonly Color Flat = Color.FromArgb(0xF2, 0x10, 0x10, 0x14);

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

    /// The shade fades; the blur behind it is the desktop manager's and has
    /// no in-between, so it arrives with the shade and leaves after it.
    private static void Fade(Window window, double to, Duration over, Action? then = null)
    {
        if (window.Content is not UIElement shade) return;
        var fade = new DoubleAnimation(to, over) { EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut } };
        if (then != null) fade.Completed += (_, _) => then();
        shade.BeginAnimation(UIElement.OpacityProperty, fade);
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
            // painted here would hide it. The shade is a child, so it can
            // fade without taking the blur's own transparency with it.
            Background = Brushes.Transparent,
        };
        var handle = new WindowInteropHelper(window).EnsureHandle();
        Native.AddExStyle(handle, Native.WS_EX_TRANSPARENT | Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE);
        var blurred = Native.SetBlurBehind(handle, 0);
        window.Content = new Border { Background = new SolidColorBrush(blurred ? Shade : Flat), Opacity = 0 };
        Native.SetWindowPos(handle, IntPtr.Zero, (int)display.Bounds.X, (int)display.Bounds.Y,
                            (int)display.Bounds.Width, (int)display.Bounds.Height,
                            Native.SWP_NOACTIVATE | Native.SWP_NOZORDER);
        window.Show();
        Fade(window, 1, FadeIn);
        return window;
    }
}
