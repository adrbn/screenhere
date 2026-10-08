using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;
using Drawing = System.Drawing;

namespace ScreenHere;

/// Win+Shift+3 and Win+Shift+2: the display, or the window, under the pointer.
internal static class Capture
{
    /// Captures only the display the pointer is on. With Ctrl, straight to the
    /// clipboard, whatever the destination is set to.
    public static void Screen(bool toClipboard)
    {
        if (Displays.UnderPointer() is not { } display) return;
        Deliver(Grab(display.Bounds), toClipboard, display);
    }

    /// Captures the window under the pointer, or its display when the pointer
    /// is on no window, so the key press is never wasted.
    public static void Window(bool toClipboard)
    {
        if (Displays.UnderPointer() is not { } display) return;
        var window = WindowUnderPointer.Current();
        var bitmap = (window != IntPtr.Zero ? GrabWindow(window, display.Bounds) : null) ?? Grab(display.Bounds);
        Deliver(bitmap, toClipboard, display);
    }

    // MARK: - Destination

    /// Where captures go unless Ctrl says the clipboard: Windows' own
    /// Screenshots folder, the one Win+PrtScn fills.
    public static string Folder =>
        Settings.Profile is { } profile ? Path.Combine(profile, "Screenshots")
        : Native.KnownFolder(Native.Screenshots)
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "Screenshots");

    /// The destination as the panel names it.
    public static string DestinationName =>
        Settings.Current.CapturesToClipboard ? "Clipboard" : Path.GetFileName(Folder.TrimEnd('\\')) is { Length: > 0 } name ? name : "Screenshots";

    /// Files this run wrote, so the folder's watcher does not announce them twice.
    public static HashSet<string> Written { get; } = new(StringComparer.OrdinalIgnoreCase);

    private static void Deliver(Drawing.Bitmap bitmap, bool forceClipboard, DisplayInfo display)
    {
        var toClipboard = forceClipboard || Settings.Current.CapturesToClipboard;
        var dispatcher = Application.Current.Dispatcher;
        // Encoding a full display takes a moment the keyboard should not wait for.
        Task.Run(() =>
        {
            byte[] png;
            using (bitmap) png = Png(bitmap);
            var file = toClipboard ? null : Save(png);
            dispatcher.BeginInvoke(() =>
            {
                if (toClipboard) ClipboardController.Shared.WriteImage(png, "ScreenHere");
                Announce(png, file, toClipboard, display);
            });
            _ = dispatcher.BeginInvoke(() => Memory.SettleSoon());
        });
    }

    private static void Announce(byte[] png, string? file, bool toClipboard, DisplayInfo display)
    {
        if (!toClipboard && file == null)
        {
            Toast.Show("Couldn't save the capture", Glyph.Warning);
            return;
        }
        if (Settings.Current.PreviewOnCapturedScreen && Thumbnail(png) is { } thumbnail)
        {
            CapturePreview.Shared.Show(thumbnail, file, display);
        }
        else
        {
            // Windows has no shutter sound: without the preview, this is the
            // only sign that the capture worked.
            Toast.Show(toClipboard ? "Copied to clipboard" : $"Saved to {DestinationName}", toClipboard ? Glyph.Paste : Glyph.Picture);
        }
    }

    /// Named the way Windows names its own, so they sort together.
    private static string? Save(byte[] png)
    {
        try
        {
            var folder = Folder;
            Directory.CreateDirectory(folder);
            var name = $"Screenshot {DateTime.Now:yyyy-MM-dd HHmmss}";
            var path = Path.Combine(folder, name + ".png");
            for (var n = 2; File.Exists(path); n++) path = Path.Combine(folder, $"{name} ({n}).png");
            lock (Written) Written.Add(path);
            File.WriteAllBytes(path, png);
            return path;
        }
        catch
        {
            return null;
        }
    }

    /// The capture at the size the preview shows it.
    public static BitmapSource? Thumbnail(byte[] png)
    {
        try
        {
            using var stream = new MemoryStream(png);
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.StreamSource = stream;
            bitmap.DecodePixelWidth = 480;
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch
        {
            return null;
        }
    }

    // MARK: - Pixels

    /// What is on screen inside `area`, in real pixels.
    public static Drawing.Bitmap Grab(Rect area)
    {
        var bitmap = new Drawing.Bitmap(Math.Max(1, (int)area.Width), Math.Max(1, (int)area.Height),
                                        Drawing.Imaging.PixelFormat.Format24bppRgb);
        using var graphics = Drawing.Graphics.FromImage(bitmap);
        graphics.CopyFromScreen((int)area.X, (int)area.Y, 0, 0, bitmap.Size, Drawing.CopyPixelOperation.SourceCopy);
        return bitmap;
    }

    /// The window as it draws itself, so one partly covered by another still
    /// comes out whole. Null when the window would not draw; what is on screen
    /// where it stands is taken instead.
    private static Drawing.Bitmap? GrabWindow(IntPtr window, Rect display)
    {
        if (!Native.GetWindowRect(window, out var outer) || WindowUnderPointer.Frame(window) is not { } drawn) return null;
        var frame = WindowUnderPointer.Trimmed(drawn, display);
        try
        {
            using var whole = new Drawing.Bitmap(Math.Max(1, outer.Width), Math.Max(1, outer.Height),
                                                 Drawing.Imaging.PixelFormat.Format32bppArgb);
            bool printed;
            using (var graphics = Drawing.Graphics.FromImage(whole))
            {
                var hdc = graphics.GetHdc();
                printed = Native.PrintWindow(window, hdc, Native.PW_RENDERFULLCONTENT);
                graphics.ReleaseHdc(hdc);
            }
            // The window's rectangle includes the invisible border it is
            // resized by; the frame is what the eye sees.
            var visible = Drawing.Rectangle.Intersect(
                new Drawing.Rectangle(frame.Left - outer.Left, frame.Top - outer.Top, frame.Width, frame.Height),
                new Drawing.Rectangle(0, 0, whole.Width, whole.Height));
            if (printed && visible.Width > 0 && visible.Height > 0 && !IsBlank(whole, visible))
            {
                return whole.Clone(visible, Drawing.Imaging.PixelFormat.Format24bppRgb);
            }
        }
        catch
        {
        }
        return Grab(new Rect(frame.Left, frame.Top, frame.Width, frame.Height));
    }

    /// A window that refused to draw comes back black all over.
    private static bool IsBlank(Drawing.Bitmap bitmap, Drawing.Rectangle area)
    {
        for (var row = 1; row < 9; row++)
        {
            for (var column = 1; column < 9; column++)
            {
                var pixel = bitmap.GetPixel(area.Left + area.Width * column / 9, area.Top + area.Height * row / 9);
                if (pixel.R != 0 || pixel.G != 0 || pixel.B != 0) return false;
            }
        }
        return true;
    }

    public static byte[] Png(Drawing.Bitmap bitmap)
    {
        using var stream = new MemoryStream();
        bitmap.Save(stream, Drawing.Imaging.ImageFormat.Png);
        return stream.ToArray();
    }
}

/// Finds the window the pointer is on, for capturing just that window.
internal static class WindowUnderPointer
{
    /// Below this, it is a tooltip or a handle rather than a window anyone
    /// means to capture.
    public const int MinimumSide = 40;

    /// The system's own surfaces: the desktop, the taskbar, the Start menu, an
    /// open menu. Nothing here is a window anyone is on.
    private static readonly HashSet<string> SystemClasses =
    [
        "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow",
        "TopLevelWindowForOverflowXamlIsland", "XamlExplorerHostIslandWindow", "Windows.UI.Core.CoreWindow",
        "#32768", "#32769",
    ];

    /// Zero when the pointer is on no window.
    public static IntPtr Current()
    {
        Native.GetCursorPos(out var point);
        var under = Native.WindowFromPoint(point);
        if (under == IntPtr.Zero) return IntPtr.Zero;
        var window = Native.GetAncestor(under, Native.GA_ROOT);
        Native.GetWindowThreadProcessId(window, out var pid);
        return Qualifies(Native.ClassName(window), pid == Environment.ProcessId, Native.IsWindowVisible(window), Frame(window))
            ? window : IntPtr.Zero;
    }

    internal static bool Qualifies(string className, bool isOwn, bool isVisible, Native.RECT? frame) =>
        !isOwn && isVisible && !SystemClasses.Contains(className)
        && frame is { } f && f.Width >= MinimumSide && f.Height >= MinimumSide;

    /// A maximised window hangs a pixel or so over the edges of its display.
    /// That overhang is not part of what anyone sees, and on the side of a
    /// second display it would be a sliver of the wrong screen.
    internal static Native.RECT Trimmed(Native.RECT frame, Rect display)
    {
        const int overhang = 16;
        if (frame.Left < display.Left && display.Left - frame.Left <= overhang) frame.Left = (int)display.Left;
        if (frame.Top < display.Top && display.Top - frame.Top <= overhang) frame.Top = (int)display.Top;
        if (frame.Right > display.Right && frame.Right - display.Right <= overhang) frame.Right = (int)display.Right;
        if (frame.Bottom > display.Bottom && frame.Bottom - display.Bottom <= overhang) frame.Bottom = (int)display.Bottom;
        return frame;
    }

    /// The window as drawn, without the invisible border around it.
    public static Native.RECT? Frame(IntPtr window)
    {
        if (Native.DwmGetWindowAttribute(window, Native.DWMWA_EXTENDED_FRAME_BOUNDS, out var frame, Marshal.SizeOf<Native.RECT>()) == 0) return frame;
        return Native.GetWindowRect(window, out var rect) ? rect : null;
    }
}

/// Shows the preview for captures other tools make — Win+PrtScn, the Snipping
/// Tool's saved snips — so every capture gets one, on the display the pointer
/// is on, not only the ones ScreenHere takes.
internal static class ScreenshotWatcher
{
    private static FileSystemWatcher? watcher;

    public static void Start()
    {
        Stop();
        try
        {
            var folder = Capture.Folder;
            Directory.CreateDirectory(folder);
            watcher = new FileSystemWatcher(folder, "*.png") { EnableRaisingEvents = true };
            var dispatcher = Application.Current.Dispatcher;
            watcher.Created += async (_, e) =>
            {
                lock (Capture.Written)
                {
                    if (Capture.Written.Contains(e.FullPath)) return;
                }
                // The file appears before it is written.
                for (var attempt = 0; attempt < 10; attempt++)
                {
                    await Task.Delay(150);
                    try
                    {
                        var png = File.ReadAllBytes(e.FullPath);
                        if (png.Length == 0 || Capture.Thumbnail(png) is not { } thumbnail) continue;
                        _ = dispatcher.BeginInvoke(() =>
                        {
                            if (Displays.UnderPointer() is { } display) CapturePreview.Shared.Show(thumbnail, e.FullPath, display);
                        });
                        return;
                    }
                    catch (IOException)
                    {
                    }
                }
            };
        }
        catch
        {
            watcher = null;
        }
    }

    public static void Stop()
    {
        watcher?.Dispose();
        watcher = null;
    }
}
