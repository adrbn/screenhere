using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ScreenHere;

/// The pictures in the README, drawn by the app itself from posed data:
/// `ScreenHere.exe --shots <folder>`. Nothing real is shown — no display
/// arrangement, no clipboard — and nothing is read or written besides the
/// pictures.
internal static class Shots
{
    public static bool IsRunning { get; private set; }

    public static void Run(string folder)
    {
        IsRunning = true;
        Directory.CreateDirectory(folder);
        Pose();
        foreach (var dark in new[] { true, false })
        {
            Theme.Apply(dark);
            var suffix = dark ? "dark" : "light";
            Render(new PanelWindow(new PanelPose(
                [new Rect(0, 0, 2560, 1440), new Rect(2560, 400, 1920, 1080)], ["Studio", "Built-in"], new Point(3400, 880))),
                Path.Combine(folder, $"panel-{suffix}.png"));
            Render(new HistoryWindow(), Path.Combine(folder, $"history-{suffix}.png"));
            Render(new Window { SizeToContent = SizeToContent.WidthAndHeight, Content = Toast.Build("Copied 7 words", Glyph.Paste) }
                .With(w => Ui.Floating(w, activates: false)), Path.Combine(folder, $"toast-{suffix}.png"));
        }
    }

    private static void Pose()
    {
        var settings = Settings.Current;
        settings.ScreenEnabled = settings.WindowEnabled = settings.TextEnabled = true;
        settings.PreviewOnCapturedScreen = false;
        settings.CapturesToClipboard = false;

        var now = DateTime.Now;
        var downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        var contract = Path.Combine(downloads, "Harbor contract.pdf");
        var capture = new ClipImage("capture", 1920, 1080, 1);
        var page = new ClipImage("page", 1200, 1600, 1);
        var items = new List<ClipItem>
        {
            new() { Image = capture, Source = "ScreenHere", Date = now.AddSeconds(-16) },
            new() { Files = [new ClipFile(contract), new ClipFile(Path.Combine(downloads, "Annex A.pdf")), new ClipFile(Path.Combine(downloads, "Annex B.pdf"))], Source = "File Explorer", Date = now.AddSeconds(-29) },
            new() { Text = "Network: Harbor Guest Password: blue-harbor-72", Source = "ScreenHere", Date = now.AddSeconds(-44) },
            new() { Text = "Sync moved to Thursday 10:00, room 4B.", Source = "Outlook", Date = now.AddMinutes(-5) },
            new() { Text = "https://github.com/adrbn/screenhere", Source = "Microsoft Edge", Date = now.AddMinutes(-15) },
            new() { Image = page, Source = "Microsoft Edge", Date = now.AddMinutes(-25) },
            new() { Text = "4 rue des Archives, 75004 Paris", Source = "Maps", Date = now.AddHours(-1) },
            new() { Text = "SELECT name, total FROM invoices WHERE paid = 0", Source = "Terminal", Date = now.AddHours(-2) },
        };
        ClipboardController.Shared.Pose(new ClipboardHistory(items), enabled: true, new()
        {
            ["capture"] = Sketch(Color.FromRgb(125, 79, 240), Color.FromRgb(246, 243, 255)),
            ["page"] = Sketch(Color.FromRgb(200, 120, 50), Color.FromRgb(255, 247, 236)),
        });
        FileThumbnails.Shared.Pose(new() { [contract] = Sketch(Color.FromRgb(150, 150, 155), Colors.White) });
        LinkPreviews.Shared.Pose(enabled: false, []);
    }

    /// A stand-in for a copied picture: a page of coloured lines.
    private static BitmapSource Sketch(Color ink, Color paper)
    {
        var visual = new DrawingVisual();
        using (var context = visual.RenderOpen())
        {
            context.DrawRectangle(new SolidColorBrush(paper), null, new Rect(0, 0, 88, 88));
            context.DrawRectangle(new SolidColorBrush(Color.FromArgb(120, ink.R, ink.G, ink.B)), null, new Rect(0, 0, 88, 18));
            var brush = new SolidColorBrush(ink);
            var widths = new[] { 62.0, 52, 66, 40, 58 };
            for (var line = 0; line < widths.Length; line++)
            {
                context.DrawRoundedRectangle(brush, null, new Rect(12, 30 + line * 10, widths[line], 4), 2, 2);
            }
        }
        var bitmap = new RenderTargetBitmap(88, 88, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        bitmap.Freeze();
        return bitmap;
    }

    /// Lays the window out off screen and saves what it draws, at twice the size.
    private static void Render(Window window, string path)
    {
        window.ShowActivated = false;
        window.Left = -30_000;
        window.Top = 0;
        window.Show();
        window.UpdateLayout();
        window.Dispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);

        const double scale = 2;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth * scale), (int)Math.Ceiling(window.ActualHeight * scale),
                                            96 * scale, 96 * scale, PixelFormats.Pbgra32);
        bitmap.Render((Visual)window.Content);
        File.WriteAllBytes(path, ClipboardAccess.Png(bitmap));
        window.Close();
    }
}
