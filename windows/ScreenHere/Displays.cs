using System.Runtime.InteropServices;
using System.Windows;

namespace ScreenHere;

/// One display, in real pixels of the virtual desktop.
internal sealed record DisplayInfo(IntPtr Handle, string Device, Rect Bounds, Rect Work, bool IsPrimary)
{
    /// How many pixels one WPF unit takes on this display.
    public double Scale
    {
        get
        {
            try { return Native.GetDpiForMonitor(Handle, 0, out var dpi, out _) == 0 ? dpi / 96.0 : 1; }
            catch { return 1; }
        }
    }
}

internal static class Displays
{
    /// The displays as Windows lists them. Worked out again on every call, so
    /// plugging in or unplugging a display never confuses a capture.
    public static List<DisplayInfo> All()
    {
        var found = new List<DisplayInfo>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (monitor, _, _, _) =>
        {
            var info = new Native.MONITORINFOEX { cbSize = Marshal.SizeOf<Native.MONITORINFOEX>() };
            if (Native.GetMonitorInfo(monitor, ref info))
            {
                found.Add(new DisplayInfo(monitor, info.szDevice, ToRect(info.rcMonitor), ToRect(info.rcWork),
                                          (info.dwFlags & 1) != 0));
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static Point Pointer()
    {
        Native.GetCursorPos(out var p);
        return new Point(p.X, p.Y);
    }

    /// The display under the pointer, or the primary one when the pointer is
    /// somehow on none, so a key press is never wasted.
    public static DisplayInfo? UnderPointer()
    {
        var all = All();
        return all.Count == 0 ? null : all[IndexAt(Pointer(), all.Select(d => d.Bounds).ToList(), all.FindIndex(d => d.IsPrimary))];
    }

    /// Index of the display containing `point`. The right and bottom edges
    /// belong to the next display, as Windows has it.
    public static int IndexAt(Point point, IReadOnlyList<Rect> displays, int fallback)
    {
        for (var i = 0; i < displays.Count; i++)
        {
            var d = displays[i];
            if (point.X >= d.Left && point.X < d.Right && point.Y >= d.Top && point.Y < d.Bottom) return i;
        }
        return Math.Clamp(fallback, 0, Math.Max(0, displays.Count - 1));
    }

    private static Rect ToRect(Native.RECT r) => new(r.Left, r.Top, r.Width, r.Height);

    // MARK: - Names

    private static Dictionary<string, string>? names;

    /// Forget the names, for when the set of displays changed.
    public static void ForgetNames() => names = null;

    /// "DELL U2720Q", as Settings shows it; "Built-in" for a laptop's own
    /// panel; "Display 2" when the monitor does not say.
    public static string Name(DisplayInfo display, int index)
    {
        names ??= QueryNames();
        return names.TryGetValue(display.Device, out var name) && name.Length > 0 ? name : $"Display {index + 1}";
    }

    private static Dictionary<string, string> QueryNames()
    {
        var result = new Dictionary<string, string>();
        try
        {
            if (Native.GetDisplayConfigBufferSizes(Native.QDC_ONLY_ACTIVE_PATHS, out var pathCount, out var modeCount) != 0) return result;
            var paths = new Native.DISPLAYCONFIG_PATH_INFO[pathCount];
            var modes = new Native.DISPLAYCONFIG_MODE_INFO[modeCount];
            if (Native.QueryDisplayConfig(Native.QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero) != 0) return result;

            for (var i = 0; i < pathCount; i++)
            {
                var source = new Native.DISPLAYCONFIG_SOURCE_DEVICE_NAME();
                source.header.type = 1;
                source.header.size = (uint)Marshal.SizeOf<Native.DISPLAYCONFIG_SOURCE_DEVICE_NAME>();
                source.header.adapterId = paths[i].sourceInfo.adapterId;
                source.header.id = paths[i].sourceInfo.id;
                if (Native.DisplayConfigGetDeviceInfo(ref source) != 0) continue;

                var target = new Native.DISPLAYCONFIG_TARGET_DEVICE_NAME();
                target.header.type = 2;
                target.header.size = (uint)Marshal.SizeOf<Native.DISPLAYCONFIG_TARGET_DEVICE_NAME>();
                target.header.adapterId = paths[i].targetInfo.adapterId;
                target.header.id = paths[i].targetInfo.id;
                if (Native.DisplayConfigGetDeviceInfo(ref target) != 0) continue;

                // Internal, embedded DisplayPort and embedded UDI: a laptop's panel.
                var builtIn = target.outputTechnology is 0x80000000 or 11 or 13;
                var name = target.monitorFriendlyDeviceName?.Trim() ?? "";
                result[source.viewGdiDeviceName] = name.Length > 0 ? name : builtIn ? "Built-in" : "";
            }
        }
        catch
        {
            // Names are a nicety: "Display 1" does the job.
        }
        return result;
    }
}

/// Squeezes the real display arrangement into the small map the panel draws.
///
/// Pure geometry, so the map can be trusted: same relative positions, same
/// aspect ratio, and a pointer that lands inside the display it is really on.
internal static class DisplayMapLayout
{
    public sealed record Fitted(IReadOnlyList<Rect> Rects, Point? Pointer);

    public static Fitted Fit(IReadOnlyList<Rect> displays, Point? pointer, Size canvas, double padding)
    {
        if (displays.Count == 0) return new Fitted([], null);

        var union = displays[0];
        foreach (var d in displays.Skip(1)) union.Union(d);
        if (union.Width <= 0 || union.Height <= 0) return new Fitted(displays.Select(_ => new Rect()).ToList(), null);

        var boxWidth = Math.Max(0, canvas.Width - padding * 2);
        var boxHeight = Math.Max(0, canvas.Height - padding * 2);
        // One shared scale for both axes: scaling them independently would
        // stretch the displays and misrepresent the arrangement.
        var scale = Math.Min(boxWidth / union.Width, boxHeight / union.Height);
        // Centre the scaled arrangement in whatever space is left over.
        var offsetX = padding + (boxWidth - union.Width * scale) / 2;
        var offsetY = padding + (boxHeight - union.Height * scale) / 2;

        Point Map(Point p) => new(offsetX + (p.X - union.Left) * scale, offsetY + (p.Y - union.Top) * scale);

        var rects = displays.Select(d => new Rect(Map(d.TopLeft), new Size(d.Width * scale, d.Height * scale))).ToList();
        return new Fitted(rects, pointer is { } p ? Map(p) : null);
    }
}
