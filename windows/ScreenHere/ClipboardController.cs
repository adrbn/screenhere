using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace ScreenHere;

/// Which copies belong in the history, and as what.
internal static class ClipboardFilter
{
    public enum Kind { Text, Image, Files }

    /// Markers password managers and similar apps put on copies that must not
    /// be kept: Windows' own convention, and the one that predates it.
    public static readonly string[] PrivateMarkers =
    [
        "ExcludeClipboardContentFromMonitorProcessing",
        "Clipboard Viewer Ignore",
    ];

    /// Set to zero by apps that keep a copy out of Windows' own history.
    public const string HistoryMarker = "CanIncludeInClipboardHistory";

    public static readonly string[] ImageFormats = ["PNG", "Bitmap", "DeviceIndependentBitmap", "System.Drawing.Bitmap"];

    /// Files before text: a copy from Explorer can carry the paths as text as
    /// well, and the files are what the user copied. Then text, since a
    /// spreadsheet range or a rich-text selection carries a picture of itself
    /// and the words are what the user copied.
    public static Kind? KindOf(IReadOnlyCollection<string> formats, bool excludedFromHistory = false)
    {
        if (excludedFromHistory || formats.Any(PrivateMarkers.Contains)) return null;
        if (formats.Contains("FileDrop")) return Kind.Files;
        if (formats.Contains("UnicodeText") || formats.Contains("Text")) return Kind.Text;
        return HasImage(formats) ? Kind.Image : null;
    }

    public static bool HasImage(IReadOnlyCollection<string> formats) =>
        !formats.Contains("FileDrop") && formats.Any(ImageFormats.Contains);

    /// A single web or file address and nothing else.
    public static bool IsLink(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Any(char.IsWhiteSpace) || !Uri.TryCreate(trimmed, UriKind.Absolute, out var uri)) return false;
        return uri.Scheme is "http" or "https" or "file";
    }
}

/// The clipboard, which other apps hold open for a moment now and then.
internal static class ClipboardAccess
{
    public static bool Try(Action action)
    {
        for (var attempt = 0; attempt < 12; attempt++)
        {
            try
            {
                action();
                return true;
            }
            catch (COMException)
            {
                Thread.Sleep(25);
            }
            catch (ExternalException)
            {
                Thread.Sleep(25);
            }
        }
        return false;
    }

    public static byte[] Png(BitmapSource image)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    public static BitmapSource? Decode(byte[] png)
    {
        try
        {
            using var stream = new MemoryStream(png);
            var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
            frame.Freeze();
            return frame;
        }
        catch
        {
            return null;
        }
    }

    /// A picture in its own format, and as a plain bitmap for the apps that
    /// only take that.
    public static bool SetImage(byte[] png)
    {
        var bitmap = Decode(png);
        if (bitmap == null) return false;
        var data = new DataObject();
        data.SetData("PNG", new MemoryStream(png));
        data.SetImage(bitmap);
        return Try(() => Clipboard.SetDataObject(data, true));
    }
}

/// The clipboard history as the app sees it: whether it is on, what it holds,
/// and the one door through which ScreenHere writes to the clipboard.
internal sealed class ClipboardController
{
    public static ClipboardController Shared { get; } = new();

    public ClipboardHistory History { get; private set; } = ClipboardHistory.Empty;
    public bool IsEnabled { get; private set; }
    /// Anything the panel or the list shows has changed.
    public event Action? Changed;

    private readonly ClipboardHistoryStore store = new();
    private readonly ClipboardImageStore images = new();
    private readonly Dictionary<string, BitmapSource> thumbnails = new();
    private readonly DispatcherTimer saveTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    private readonly DispatcherTimer readTimer = new() { Interval = TimeSpan.FromMilliseconds(90) };
    private HwndSource? listener;
    private uint ignoredSequence;
    /// Bumped by every clear, so a picture still being written when the
    /// history was cleared does not come back into it.
    private int generation;
    private bool posed;
    /// Pictures still to be read, the digests already asked for, and whether
    /// one is being read: one at a time, so a list full of old screenshots
    /// does not read them all at once.
    private readonly Queue<ClipImage> captionQueue = new();
    private readonly HashSet<string> captionsAsked = [];
    private bool readingCaption;

    private ClipboardController()
    {
        // Copies come in bursts; one write a couple of seconds after the last
        // is plenty.
        saveTimer.Tick += (_, _) => Flush();
        // A copy arrives as several changes, one per format; read it once they
        // have settled.
        readTimer.Tick += (_, _) =>
        {
            readTimer.Stop();
            Read();
        };
    }

    public void Activate()
    {
        IsEnabled = Settings.Current.HistoryEnabled;
        if (IsEnabled) LoadHistory();
        Watch();
    }

    /// Listens to the clipboard while something needs it: the history, or the
    /// clipboard shared with another device.
    public void Watch()
    {
        if (posed) return;
        if (IsEnabled || SyncController.Shared.IsEnabled) Start();
        else Stop();
    }

    public void SetEnabled(bool on)
    {
        Settings.Current.HistoryEnabled = on;
        Settings.Current.Save();
        IsEnabled = on;
        if (on) LoadHistory();
        else Flush();
        Watch();
        Changed?.Invoke();
    }

    // MARK: - Watching

    private void Start()
    {
        if (listener != null) return;
        // A window that only exists to be told about the clipboard. Windows
        // sends a message on every copy, so nothing is polled.
        // Message-only, with no style at all: left to its defaults it is a
        // real, if unseen, window, and takes the keyboard from the app in front.
        listener = new HwndSource(new HwndSourceParameters("ScreenHere.Clipboard")
        {
            ParentWindow = Native.HWND_MESSAGE,
            WindowStyle = 0,
            ExtendedWindowStyle = Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW,
            Width = 0,
            Height = 0,
        });
        listener.AddHook(OnMessage);
        Native.AddClipboardFormatListener(listener.Handle);
    }

    private void Stop()
    {
        if (listener == null) return;
        Native.RemoveClipboardFormatListener(listener.Handle);
        listener.Dispose();
        listener = null;
    }

    private IntPtr OnMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == Native.WM_CLIPBOARDUPDATE)
        {
            readTimer.Stop();
            readTimer.Start();
        }
        return IntPtr.Zero;
    }

    private void Read()
    {
        // ScreenHere's own writes are added to the history directly.
        if (listener == null || Native.GetClipboardSequenceNumber() == ignoredSequence) return;
        var source = FrontmostApp();
        ClipboardAccess.Try(() =>
        {
            var data = Clipboard.GetDataObject();
            if (data == null) return;
            var formats = data.GetFormats(false);
            var excluded = data.GetDataPresent(ClipboardFilter.HistoryMarker)
                && data.GetData(ClipboardFilter.HistoryMarker) is MemoryStream marker
                && marker.Length >= 4 && BitConverter.ToInt32(marker.ToArray(), 0) == 0;

            switch (ClipboardFilter.KindOf(formats, excluded))
            {
                case ClipboardFilter.Kind.Files:
                    if (IsEnabled && data.GetData(DataFormats.FileDrop) is string[] { Length: > 0 } paths)
                    {
                        Apply(History.Adding(paths.Select(p => new ClipFile(p)).ToList(), source, DateTime.Now));
                    }
                    break;
                case ClipboardFilter.Kind.Text:
                    if (data.GetData(DataFormats.UnicodeText) is not string text) break;
                    // A browser's "Copy image" can add the picture's address as text.
                    if (ClipboardFilter.IsLink(text) && ClipboardFilter.HasImage(formats))
                    {
                        TakeImage(data, source);
                        break;
                    }
                    if (IsEnabled) Apply(History.Adding(text, source, DateTime.Now));
                    SyncController.Shared.LocalCopy(text);
                    break;
                case ClipboardFilter.Kind.Image:
                    TakeImage(data, source);
                    break;
            }
        });
    }

    /// Pictures are encoded, hashed and written off the main thread: a
    /// full-screen capture takes a noticeable moment.
    private void TakeImage(IDataObject data, string? source)
    {
        byte[]? png = null;
        BitmapSource? bitmap = null;
        if (data.GetDataPresent("PNG") && data.GetData("PNG") is MemoryStream stream)
        {
            png = stream.ToArray();
        }
        else if (Clipboard.GetImage() is { } copied)
        {
            // A plain bitmap's fourth channel is usually padding, and reading
            // it as transparency turns the whole picture invisible.
            bitmap = new FormatConvertedBitmap(copied, PixelFormats.Bgr24, null, 0);
            bitmap.Freeze();
        }
        if (png == null && bitmap == null) return;

        var started = generation;
        Task.Run(() =>
        {
            try
            {
                png ??= ClipboardAccess.Png(bitmap!);
                var image = IsEnabled ? images.Ingest(png) : null;
                Application.Current?.Dispatcher.BeginInvoke(() =>
                {
                    // Turned off or cleared meanwhile: a file left behind is
                    // swept at the next load.
                    if (image != null && IsEnabled && generation == started)
                    {
                        Apply(History.Adding(image, source, DateTime.Now));
                        WantCaption(image);
                    }
                    SyncController.Shared.LocalCopy(png);
                });
            }
            catch
            {
                // Not a picture after all.
            }
        });
    }

    /// The app in front, by the name it gives itself.
    private static string? FrontmostApp()
    {
        try
        {
            Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out var pid);
            if (pid == 0 || pid == Environment.ProcessId) return pid == 0 ? null : "ScreenHere";
            using var process = Process.GetProcessById((int)pid);
            try
            {
                var description = process.MainModule?.FileVersionInfo.FileDescription;
                if (!string.IsNullOrWhiteSpace(description)) return description.Trim();
            }
            catch
            {
                // An elevated app does not let itself be asked.
            }
            return process.ProcessName;
        }
        catch
        {
            return null;
        }
    }

    // MARK: - Writing

    /// Puts text on the clipboard and, when history is on, at its top.
    public void Write(string text, string? source)
    {
        if (!ClipboardAccess.Try(() => Clipboard.SetDataObject(text, true))) return;
        ignoredSequence = Native.GetClipboardSequenceNumber();
        if (IsEnabled) Apply(History.Adding(text, source, DateTime.Now));
    }

    /// Puts a capture on the clipboard and, when history is on, at its top.
    public void WriteImage(byte[] png, string? source)
    {
        if (!ClipboardAccess.SetImage(png)) return;
        ignoredSequence = Native.GetClipboardSequenceNumber();
        if (!IsEnabled) return;
        var started = generation;
        Task.Run(() =>
        {
            var image = images.Ingest(png);
            Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                if (IsEnabled && generation == started)
                {
                    Apply(History.Adding(image, source, DateTime.Now));
                    WantCaption(image);
                }
            });
        });
    }

    /// Adds a capture that went to a file to the history, without touching
    /// the clipboard: it is something the user just took, and the list is
    /// where they will look for it.
    public void Keep(byte[] png, string? source)
    {
        if (!IsEnabled) return;
        var started = generation;
        Task.Run(() =>
        {
            var image = images.Ingest(png);
            Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                if (IsEnabled && generation == started)
                {
                    Apply(History.Adding(image, source, DateTime.Now));
                    WantCaption(image);
                }
            });
        });
    }

    /// Puts an item back on the clipboard. False when what it points at is
    /// gone from disk: a missing picture takes its item with it, a missing
    /// file does not — an unplugged disk comes back, and its row says so.
    public bool Copy(ClipItem item)
    {
        if (item.Text is { } text)
        {
            Write(text, item.Source);
            return true;
        }
        if (item.Image is { } image)
        {
            var data = images.Data(image);
            if (data == null || !ClipboardAccess.SetImage(data))
            {
                if (data == null) Remove(item);
                return false;
            }
            ignoredSequence = Native.GetClipboardSequenceNumber();
            if (IsEnabled) Apply(History.Adding(image, item.Source, DateTime.Now));
            return true;
        }
        // Whatever is still there: two files copied, one deleted since, and
        // the one left is better than nothing.
        var present = new StringCollection();
        foreach (var file in item.Files!.Where(f => f.Exists)) present.Add(file.Path);
        if (present.Count == 0) return false;
        if (!ClipboardAccess.Try(() => Clipboard.SetFileDropList(present))) return false;
        ignoredSequence = Native.GetClipboardSequenceNumber();
        if (IsEnabled) Apply(History.Adding(item.Files!, item.Source, DateTime.Now));
        return true;
    }

    /// Reads the words in a picture, for its row's title and for the search.
    /// Asked for by a new copy and by the list as rows appear, so pictures
    /// copied before this existed get their words too. Once per picture.
    public void WantCaption(ClipImage image)
    {
        if (!IsEnabled || posed || image.Caption != null || !captionsAsked.Add(image.Digest)) return;
        captionQueue.Enqueue(image);
        ReadNextCaption();
    }

    private void ReadNextCaption()
    {
        if (readingCaption || captionQueue.Count == 0) return;
        var image = captionQueue.Dequeue();
        readingCaption = true;
        var started = generation;
        Task.Run(async () =>
        {
            var png = images.Data(image);
            var words = png == null ? null : await TextRecognizer.Read(png);
            Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                readingCaption = false;
                // Nothing read is recorded as empty, so the picture is not
                // looked at again on every launch; a recogniser that could not
                // run at all records nothing.
                if (words != null && generation == started) Apply(History.Captioning(image.Digest, words.Trim()));
                ReadNextCaption();
            });
        });
    }

    public BitmapSource? Thumbnail(ClipImage image)
    {
        if (thumbnails.TryGetValue(image.Digest, out var cached)) return cached;
        var small = images.Thumbnail(image);
        if (small != null) thumbnails[image.Digest] = small;
        return small;
    }

    /// Where the picture sits on disk, so a row can be dragged into any app.
    public string FilePath(ClipImage image) => images.FilePath(image);

    /// A copy of the picture in the Downloads folder. Null when the picture is
    /// gone or the copy fails.
    public string? SaveToDownloads(ClipImage image)
    {
        var downloads = Native.KnownFolder(Native.Downloads);
        return downloads == null ? null : images.Copy(image, downloads, DateTime.Now);
    }

    public void Remove(ClipItem item) => Apply(History.Removing(item.Id));

    public void Clear()
    {
        generation++;
        saveTimer.Stop();
        History = ClipboardHistory.Empty;
        captionQueue.Clear();
        captionsAsked.Clear();
        store.Delete();
        thumbnails.Clear();
        FileThumbnails.Shared.Clear();
        LinkPreviews.Shared.Clear();
        Task.Run(images.DeleteAll);
        Changed?.Invoke();
    }

    /// Writes any pending change now — at quit and sign-out.
    public void Flush()
    {
        if (!saveTimer.IsEnabled) return;
        saveTimer.Stop();
        try { store.Save(History); } catch { }
    }

    /// Loads the list without entries whose picture went missing, and sweeps
    /// pictures nothing points at any more.
    private void LoadHistory()
    {
        if (posed) return;
        History = store.Load().Filtering(item => item.Image == null || File.Exists(images.FilePath(item.Image)));
        var keep = History.ImageDigests;
        Task.Run(() => images.Prune(keep));
        LinkPreviews.Shared.Prune(History.Links());
    }

    /// Publishes a new history, schedules its save, and deletes the pictures
    /// and link previews it no longer holds.
    private void Apply(ClipboardHistory next)
    {
        var dropped = History.ImageDigests;
        dropped.ExceptWith(next.ImageDigests);
        var links = next.Links();
        LinkPreviews.Shared.Forget(History.Links().Except(links).ToList());
        History = next;
        if (!posed)
        {
            saveTimer.Stop();
            saveTimer.Start();
        }
        foreach (var digest in dropped) thumbnails.Remove(digest);
        if (dropped.Count > 0 && !posed) Task.Run(() => images.Remove(dropped));
        Changed?.Invoke();
    }

    /// Documentation shots only: show a history without watching or writing
    /// anything.
    public void Pose(ClipboardHistory history, bool enabled, Dictionary<string, BitmapSource>? pictures = null)
    {
        posed = true;
        Stop();
        History = history;
        IsEnabled = enabled;
        foreach (var (digest, picture) in pictures ?? []) thumbnails[digest] = picture;
    }
}

/// Explorer's picture of a copied file — the first page of a PDF, the photo
/// itself — or its type's icon when there is nothing to preview.
internal sealed class FileThumbnails
{
    public static FileThumbnails Shared { get; } = new();

    private readonly Dictionary<string, BitmapSource?> pictures = new();
    private readonly HashSet<string> wanted = [];
    public event Action? Changed;
    /// Set by documentation shots, whose files exist nowhere.
    public bool Posed { get; private set; }

    public BitmapSource? Thumbnail(ClipFile file) => pictures.GetValueOrDefault(file.Path);

    /// Asks for the picture once; the list redraws when it is there.
    public void Want(ClipFile file)
    {
        if (Posed || !wanted.Add(file.Path)) return;
        var path = file.Path;
        var dispatcher = Dispatcher.CurrentDispatcher;
        var thread = new Thread(() =>
        {
            var picture = Load(path);
            dispatcher.BeginInvoke(() =>
            {
                pictures[path] = picture;
                if (picture != null) Changed?.Invoke();
            });
        });
        // The shell's thumbnail providers expect an apartment of their own.
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
    }

    private static BitmapSource? Load(string path)
    {
        var bitmap = IntPtr.Zero;
        try
        {
            Native.SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(Native.IShellItemImageFactory).GUID, out var factory);
            const int biggerSizeOk = 0x1;
            if (factory.GetImage(new Native.SIZE { cx = 96, cy = 96 }, biggerSizeOk, out bitmap) != 0) return null;
            var source = Imaging.CreateBitmapSourceFromHBitmap(bitmap, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();
            return source;
        }
        catch
        {
            return null;
        }
        finally
        {
            if (bitmap != IntPtr.Zero) Native.DeleteObject(bitmap);
        }
    }

    public void Clear()
    {
        pictures.Clear();
        wanted.Clear();
    }

    public void Pose(Dictionary<string, BitmapSource> posedPictures)
    {
        Posed = true;
        foreach (var (path, picture) in posedPictures) pictures[path] = picture;
    }
}
