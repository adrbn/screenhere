using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Drawing = System.Drawing;

namespace ScreenHere;

/// Win+Shift+7: select a region, recognise its text on this PC, put it on the
/// clipboard.
internal static class TextCapture
{
    private static bool busy;

    public static void Run()
    {
        if (busy) return;
        busy = true;
        var overlay = new SelectionOverlay();
        overlay.Finished += area =>
        {
            // Escape leaves nothing to recognise, and nothing to say.
            if (area is not { } selected)
            {
                busy = false;
                return;
            }
            // One beat for the selection itself to leave the screen, or it
            // would be in the picture.
            var wait = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(70) };
            wait.Tick += async (_, _) =>
            {
                wait.Stop();
                try
                {
                    using var capture = Capture.Grab(selected);
                    Deliver(await TextRecognizer.Recognize(capture));
                }
                catch
                {
                    Toast.Show("Text recognition isn't available", Glyph.Warning);
                }
                finally
                {
                    busy = false;
                    Memory.SettleSoon();
                }
            };
            wait.Start();
        };
        overlay.Begin();
    }

    private static void Deliver(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0)
        {
            Toast.Show(TextCaptureStrings.Copied(""), Glyph.NoResults);
            return;
        }
        ClipboardController.Shared.Write(trimmed, "ScreenHere");
        Toast.Show(TextCaptureStrings.Copied(trimmed), Glyph.Paste);
    }
}

/// Reads text with Windows' own recogniser: on this PC, nothing uploaded, and
/// no network needed.
internal static class TextRecognizer
{
    public static async Task<string> Recognize(Drawing.Bitmap capture)
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages()
            ?? OcrEngine.AvailableRecognizerLanguages.Select(OcrEngine.TryCreateFromLanguage).FirstOrDefault(e => e != null)
            ?? throw new InvalidOperationException("No recognition language installed");

        using var enlarged = Enlarge(capture);
        using var stream = new MemoryStream(Capture.Png(enlarged));
        var decoder = await BitmapDecoder.CreateAsync(stream.AsRandomAccessStream());
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        var result = await engine.RecognizeAsync(bitmap);
        return string.Join("\n", result.Lines.Select(line => line.Text));
    }

    /// How much to enlarge a capture before reading it. The recogniser was
    /// made for scanned pages: interface text at its real size is too small
    /// for it, and comes out with letters missing.
    internal static int Factor(int width, int height)
    {
        var factor = height < 80 ? 3 : 2;
        var limit = Math.Min(4_000, (int)OcrEngine.MaxImageDimension);
        while (factor > 1 && Math.Max(width, height) * factor > limit) factor--;
        return factor;
    }

    private static Drawing.Bitmap Enlarge(Drawing.Bitmap capture)
    {
        var factor = Factor(capture.Width, capture.Height);
        var enlarged = new Drawing.Bitmap(capture.Width * factor, capture.Height * factor, Drawing.Imaging.PixelFormat.Format24bppRgb);
        using var graphics = Drawing.Graphics.FromImage(enlarged);
        graphics.InterpolationMode = Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
        graphics.PixelOffsetMode = Drawing.Drawing2D.PixelOffsetMode.HighQuality;
        graphics.DrawImage(capture, new Drawing.Rectangle(0, 0, enlarged.Width, enlarged.Height));
        return enlarged;
    }
}

/// The crosshair: drag over the text, Esc or a right click cancels. It lies
/// over every display at once and never takes focus, so the menu or the
/// tooltip being read stays open under it.
internal sealed class SelectionOverlay : Window
{
    /// The selection in real pixels, or null when it was cancelled.
    public event Action<Rect?>? Finished;

    private readonly Rectangle selection = new()
    {
        Fill = new SolidColorBrush(Color.FromArgb(56, 150, 150, 150)),
        Stroke = new SolidColorBrush(Color.FromArgb(215, 140, 140, 140)),
        StrokeThickness = 1,
        Visibility = Visibility.Collapsed,
        SnapsToDevicePixels = true,
    };
    private Point? anchor;
    private bool done;

    /// Smaller than this is a click that slipped, not a selection.
    private const double MinimumSide = 4;

    public SelectionOverlay()
    {
        Ui.Floating(this, activates: false);
        // Almost, but not quite, see-through: a window that is fully
        // transparent lets the mouse through to what is behind it.
        Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0));
        Cursor = Cursors.Cross;
        var canvas = new Canvas();
        canvas.Children.Add(selection);
        Content = canvas;

        MouseLeftButtonDown += (_, _) =>
        {
            anchor = Displays.Pointer();
            CaptureMouse();
        };
        MouseMove += (_, _) => Draw();
        MouseLeftButtonUp += (_, _) =>
        {
            if (anchor is not { } from) return;
            var area = new Rect(from, Displays.Pointer());
            Finish(area.Width >= MinimumSide && area.Height >= MinimumSide ? area : null);
        };
        MouseRightButtonDown += (_, _) => Finish(null);
    }

    public void Begin()
    {
        var all = Displays.All();
        if (all.Count == 0)
        {
            Finished?.Invoke(null);
            return;
        }
        var desktop = all[0].Bounds;
        foreach (var display in all.Skip(1)) desktop.Union(display.Bounds);

        var handle = new WindowInteropHelper(this).EnsureHandle();
        Native.SetWindowPos(handle, IntPtr.Zero, (int)desktop.X, (int)desktop.Y, (int)desktop.Width, (int)desktop.Height,
                            Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
        Show();
        // Windows may have resized it on the way to a display at another scale.
        Native.SetWindowPos(handle, IntPtr.Zero, (int)desktop.X, (int)desktop.Y, (int)desktop.Width, (int)desktop.Height,
                            Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
        Hotkeys.OnEscape = () => Finish(null);
    }

    private void Draw()
    {
        if (anchor is not { } from) return;
        // The pointer is read in screen pixels and drawn in the window's own
        // units, whatever scale the displays under it have.
        var a = PointFromScreen(from);
        var b = PointFromScreen(Displays.Pointer());
        var area = new Rect(a, b);
        Canvas.SetLeft(selection, area.X);
        Canvas.SetTop(selection, area.Y);
        selection.Width = area.Width;
        selection.Height = area.Height;
        selection.Visibility = Visibility.Visible;
    }

    private void Finish(Rect? area)
    {
        if (done) return;
        done = true;
        Hotkeys.OnEscape = null;
        ReleaseMouseCapture();
        Close();
        Finished?.Invoke(area);
    }
}
