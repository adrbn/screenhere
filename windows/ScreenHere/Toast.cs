using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;

namespace ScreenHere;

/// A short confirmation pill at the top of the screen under the pointer —
/// "Copied 12 words" — that never takes focus or a click.
internal static class Toast
{
    private static Window? window;
    private static DispatcherTimer? dismissal;
    /// Between the top of the screen and the pill.
    private const double TopGap = 18;
    private const double ShadowRoom = 16;

    public static void Show(string message, string glyph)
    {
        dismissal?.Stop();
        window?.Close();
        if (Displays.UnderPointer() is not { } display) return;

        var toast = new Window { SizeToContent = SizeToContent.WidthAndHeight, Content = Build(message, glyph), IsHitTestVisible = false };
        Ui.Floating(toast, activates: false);
        // Clicks go through to whatever is underneath.
        toast.SourceInitialized += (_, _) => Native.AddExStyle(new WindowInteropHelper(toast).Handle, Native.WS_EX_TRANSPARENT);

        var scale = display.Scale;
        Ui.ShowOn(toast, display, size => new Point(
            display.Work.X + (display.Work.Width - size.Width) / 2,
            display.Work.Y + (TopGap - ShadowRoom) * scale), activate: false);
        window = toast;

        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.4) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (window == toast) window = null;
            Ui.FadeOut(toast, 0.25);
        };
        dismissal = timer;
        timer.Start();
    }

    internal static UIElement Build(string message, string glyph)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(16, 9, 16, 9) };
        content.Children.Add(Ui.Icon(glyph, 14, "Primary"));
        content.Children.Add(Ui.Text(message, 13, FontWeights.Medium).With(t => t.Margin = new Thickness(8, 0, 0, 1)));
        return Ui.Surface(content, radius: 19, background: "Card", margin: ShadowRoom, shadow: 0.22);
    }
}

/// How many words a capture's text holds, in the words the toast uses.
internal static class TextCaptureStrings
{
    public static string Copied(string text)
    {
        var words = System.Text.RegularExpressions.Regex.Matches(text, @"[\p{L}\p{N}]+").Count;
        return words switch
        {
            0 => "No text found",
            1 => "Copied 1 word",
            _ => $"Copied {words} words",
        };
    }
}
