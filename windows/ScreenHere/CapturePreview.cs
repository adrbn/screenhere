using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ScreenHere;

/// The preview that slides into the corner after a capture — on the display
/// that was captured, not wherever the system would have put it.
///
/// A borderless floating window rather than anything in the panel: it has to
/// sit above every app, on a screen the user may not have focused, and never
/// take focus from what they are doing.
internal sealed class CapturePreview
{
    public static CapturePreview Shared { get; } = new();

    private Window? window;
    private DispatcherTimer? dismissal;
    private IntPtr handle;
    /// Where the card sits when no gesture is moving it, in real pixels.
    private Point resting;
    private double scale = 1;

    /// How long it stays before fading out.
    private const double Lifetime = 6;
    private const double CornerRadius = 10;
    /// The card's own margin around the image.
    private const double Inset = 4;
    private const double ShadowRoom = 16;
    /// From the corner of the screen to the card.
    private const double Margin = 20;
    /// Past this much rightward travel the card is considered thrown.
    private const double ThrowDistance = 55;
    /// Movement below this is still a click, not a gesture.
    private const double Slop = 5;
    /// How far a thrown card travels before it is gone.
    private const double Travel = 620;

    /// Show `image` in the corner of `display`. `file` backs dragging and the
    /// click-through to Explorer; without one the preview is display-only.
    public void Show(BitmapSource image, string? file, DisplayInfo display)
    {
        Dismiss(animated: false);

        var size = SizeFor(image.PixelWidth, image.PixelHeight);
        var preview = new Window
        {
            Width = size.Width + ShadowRoom * 2,
            Height = size.Height + ShadowRoom * 2,
            Content = Build(image, file, size),
        };
        Ui.Floating(preview, activates: false);

        scale = display.Scale;
        // Bottom right of the captured screen, clear of the taskbar.
        Ui.ShowOn(preview, display, window => resting = new Point(
            display.Work.Right - window.Width + (ShadowRoom - Margin) * scale,
            display.Work.Bottom - window.Height + (ShadowRoom - Margin) * scale), activate: false);
        handle = new WindowInteropHelper(preview).Handle;
        window = preview;
        StartTimer();
    }

    public void Dismiss(bool animated)
    {
        dismissal?.Stop();
        dismissal = null;
        if (window is not { } closing) return;
        window = null;
        if (animated) Ui.FadeOut(closing, 0.22);
        else closing.Close();
    }

    private void StartTimer()
    {
        dismissal?.Stop();
        dismissal = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Lifetime) };
        dismissal.Tick += (_, _) => Dismiss(animated: true);
        dismissal.Start();
    }

    // MARK: - Geometry

    /// Keeps the capture's aspect ratio inside a sensible box — a portrait
    /// display should not produce a wide card.
    internal static Size SizeFor(double width, double height)
    {
        var maximum = new Size(232, 150);
        if (width <= 0 || height <= 0) return maximum;
        var fit = Math.Min(maximum.Width / width, maximum.Height / height);
        return new Size(Math.Max(80, width * fit) + Inset * 2, Math.Max(56, height * fit) + Inset * 2);
    }

    // MARK: - The card

    private enum Intent { Undecided, ThrowAway, CarryFile }

    /// The card itself: the capture, and its gestures — throw it to the right
    /// to dismiss, drag it anywhere else to carry the file out. A click shows
    /// it in Explorer.
    private UIElement Build(BitmapSource image, string? file, Size size)
    {
        var picture = new Border
        {
            CornerRadius = new CornerRadius(5),
            Margin = new Thickness(Inset - 1),
            Background = new ImageBrush(image) { Stretch = Stretch.UniformToFill },
            BorderBrush = new SolidColorBrush(Color.FromArgb(31, 0, 0, 0)),
            BorderThickness = new Thickness(0.5),
        };

        var close = new Border
        {
            Width = 16, Height = 16, CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Color.FromArgb(150, 0, 0, 0)),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 7, 7, 0), Opacity = 0, Cursor = Cursors.Hand,
            Child = Ui.Icon(Glyph.Close, 7, null).With(i => i.Foreground = Brushes.White),
        };
        close.MouseLeftButtonDown += (_, e) =>
        {
            e.Handled = true;
            Dismiss(animated: true);
        };

        var content = new Grid { Background = Brushes.Transparent };
        content.Children.Add(picture);
        content.Children.Add(close);
        var card = Ui.Surface(content, CornerRadius, margin: ShadowRoom, shadow: 0.3);

        card.MouseEnter += (_, _) => close.Opacity = 1;
        card.MouseLeave += (_, _) => close.Opacity = 0;

        var intent = Intent.Undecided;
        var start = new Point();
        var pressed = false;

        card.MouseLeftButtonDown += (_, _) =>
        {
            intent = Intent.Undecided;
            start = Displays.Pointer();
            pressed = true;
            dismissal?.Stop();
            card.CaptureMouse();
        };
        card.MouseMove += (_, _) =>
        {
            if (!pressed) return;
            // In screen pixels: the window itself is what moves.
            var now = Displays.Pointer();
            var (dx, dy) = ((now.X - start.X) / scale, (now.Y - start.Y) / scale);
            if (intent == Intent.Undecided)
            {
                if (Math.Abs(dx) <= Slop && Math.Abs(dy) <= Slop) return;
                // Rightward and mostly horizontal is a throw; anything else is
                // someone taking the file somewhere.
                intent = dx > 0 && Math.Abs(dx) > Math.Abs(dy) * 1.5 ? Intent.ThrowAway : Intent.CarryFile;
                if (intent == Intent.CarryFile)
                {
                    pressed = false;
                    card.ReleaseMouseCapture();
                    CarryOut(card, file);
                    return;
                }
            }
            if (intent == Intent.ThrowAway) Drift(Math.Max(0, dx));
        };
        card.MouseLeftButtonUp += (_, _) =>
        {
            if (!pressed) return;
            pressed = false;
            card.ReleaseMouseCapture();
            var dx = (Displays.Pointer().X - start.X) / scale;
            switch (intent)
            {
                case Intent.Undecided:
                    Open(file);
                    break;
                case Intent.ThrowAway when dx > ThrowDistance:
                    ThrowOff(dx);
                    break;
                case Intent.ThrowAway:
                    Settle(dx);
                    break;
            }
            intent = Intent.Undecided;
        };
        return card;
    }

    private void Open(string? file)
    {
        if (file != null)
        {
            try { Process.Start("explorer.exe", $"/select,\"{file}\""); } catch { }
        }
        Dismiss(animated: true);
    }

    private void CarryOut(UIElement source, string? file)
    {
        if (file == null)
        {
            StartTimer();
            return;
        }
        var result = DragDrop.DoDragDrop(source, new DataObject(DataFormats.FileDrop, new[] { file }), DragDropEffects.Copy);
        if (result == DragDropEffects.None) StartTimer();
        else Dismiss(animated: true);
    }

    /// Follow the gesture, fading as it goes, so a throw reads as the card
    /// leaving rather than sliding under something.
    private void Drift(double dx)
    {
        if (window == null) return;
        Native.SetWindowPos(handle, IntPtr.Zero, (int)Math.Round(resting.X + dx * scale), (int)Math.Round(resting.Y), 0, 0,
                            Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
        window.BeginAnimation(UIElement.OpacityProperty, null);
        window.Opacity = 1 - Math.Min(1, dx / 260) * 0.7;
    }

    private void Settle(double from)
    {
        Animate(from, 0, 0.28, t => 1 - Math.Pow(1 - t, 3), Drift, StartTimer);
    }

    /// Send it off to the right and out of existence.
    private void ThrowOff(double from)
    {
        Animate(from, Travel, 0.26, t => t * t, Drift, () => Dismiss(animated: false));
    }

    private void Animate(double from, double to, double seconds, Func<double, double> ease, Action<double> apply, Action done)
    {
        var animated = window;
        var clock = Stopwatch.StartNew();
        EventHandler? step = null;
        step = (_, _) =>
        {
            var t = Math.Min(1, clock.Elapsed.TotalSeconds / seconds);
            if (window == animated) apply(from + (to - from) * ease(t));
            if (t < 1 && window == animated) return;
            CompositionTarget.Rendering -= step;
            if (window == animated) done();
        };
        CompositionTarget.Rendering += step;
    }
}
