using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ScreenHere;

/// A copied picture. The bytes live in `ClipboardImageStore`, in a file named
/// by the digest; the history only describes them.
internal sealed record ClipImage(string Digest, int Width, int Height, long ByteCount);

/// A copied file, kept as a reference: its bytes stay where they are, so an
/// entry can outlive the file it points at — and point at it again when an
/// unplugged disk comes back.
internal sealed record ClipFile(string Path)
{
    [JsonIgnore] public string Name => System.IO.Path.GetFileName(Path.TrimEnd('\\', '/')) is { Length: > 0 } name ? name : Path;

    /// The folder it sits in, the home folder written as "~".
    [JsonIgnore]
    public string Folder
    {
        get
        {
            var folder = System.IO.Path.GetDirectoryName(Path) ?? Path;
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (home.Length == 0) return folder;
            if (folder.Equals(home, StringComparison.OrdinalIgnoreCase)) return "~";
            return folder.StartsWith(home + "\\", StringComparison.OrdinalIgnoreCase) ? "~" + folder[home.Length..] : folder;
        }
    }

    [JsonIgnore] public bool Exists => File.Exists(Path) || Directory.Exists(Path);
}

/// One thing the user copied: a text, a picture, or everything one copy took
/// from Explorer, in the order it gave them.
internal sealed record ClipItem
{
    public Guid Id { get; init; } = Guid.NewGuid();
    public string? Text { get; init; }
    public ClipImage? Image { get; init; }
    public IReadOnlyList<ClipFile>? Files { get; init; }
    public DateTime Date { get; init; }
    /// The app that was in front when it was copied, for the list's subtitle.
    public string? Source { get; init; }

    [JsonIgnore] public bool IsValid => Text != null || Image != null || Files is { Count: > 0 };
}

/// Everything copied while history is on, newest first. Immutable: every
/// change returns a new history, so the controller can publish it whole and the
/// store can write it without anyone mutating it underneath.
internal sealed class ClipboardHistory
{
    /// Enough to find "that thing I copied this morning" without the list
    /// turning into an archive.
    public const int Capacity = 200;
    /// Characters. Bigger copies are skipped, never truncated: pasting back a
    /// silently shortened copy would lose data.
    public const int MaxLength = 100_000;
    /// Disk space all pictures together may take. A full-screen capture is a
    /// few megabytes, so this keeps a few dozen.
    public const long ImageBudget = 100 * 1024 * 1024;
    /// One picture may not take a quarter of the budget on its own.
    public const long MaxImageBytes = 25 * 1024 * 1024;

    public IReadOnlyList<ClipItem> Items { get; }

    public static readonly ClipboardHistory Empty = new([]);

    public ClipboardHistory(IEnumerable<ClipItem> items) => Items = items.ToList();

    public ClipboardHistory Adding(string text, string? source, DateTime date)
    {
        if (string.IsNullOrWhiteSpace(text) || text.Length > MaxLength) return this;
        var item = new ClipItem { Text = text, Date = date, Source = source };
        return new ClipboardHistory(Items.Where(i => i.Text != text).Prepend(item)).Trimmed();
    }

    public ClipboardHistory Adding(ClipImage image, string? source, DateTime date)
    {
        if (image.ByteCount > MaxImageBytes) return this;
        var item = new ClipItem { Image = image, Date = date, Source = source };
        return new ClipboardHistory(Items.Where(i => i.Image?.Digest != image.Digest).Prepend(item)).Trimmed();
    }

    /// Files cost nothing but their addresses: no budget, no size limit.
    public ClipboardHistory Adding(IReadOnlyList<ClipFile> files, string? source, DateTime date)
    {
        if (files.Count == 0) return this;
        var item = new ClipItem { Files = files, Date = date, Source = source };
        return new ClipboardHistory(Items.Where(i => i.Files == null || !i.Files.SequenceEqual(files)).Prepend(item)).Trimmed();
    }

    public ClipboardHistory Removing(Guid id) => Filtering(i => i.Id != id);

    public ClipboardHistory Filtering(Func<ClipItem, bool> isIncluded) => new(Items.Where(isIncluded));

    /// The pictures this history still points at; any other file can go.
    public HashSet<string> ImageDigests => Items.Where(i => i.Image != null).Select(i => i.Image!.Digest).ToHashSet();

    /// Items containing every word of `query`, ignoring case and accents.
    public IReadOnlyList<ClipItem> Matching(string query)
    {
        var words = query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Select(Fold).ToList();
        if (words.Count == 0) return Items;
        return Items.Where(item =>
        {
            var haystack = Fold(SearchableText(item));
            return words.All(haystack.Contains);
        }).ToList();
    }

    /// Newest first, the capacity and the image budget both applied: past the
    /// budget the oldest pictures go — all of them, even one small enough to
    /// fit what is left — and the text around them stays.
    private ClipboardHistory Trimmed()
    {
        var kept = new List<ClipItem>();
        long imageBytes = 0;
        var overBudget = false;
        foreach (var item in Items)
        {
            if (kept.Count >= Capacity) break;
            if (item.Image is { } image)
            {
                overBudget = overBudget || imageBytes + image.ByteCount > ImageBudget;
                if (overBudget) continue;
                imageBytes += image.ByteCount;
            }
            kept.Add(item);
        }
        return new ClipboardHistory(kept);
    }

    /// Pictures have no words of their own: they are found as "image" or by
    /// the app they came from. Files are found by their whole path, so a
    /// folder's name finds everything copied out of it.
    private static string SearchableText(ClipItem item)
    {
        if (item.Text != null) return item.Text;
        if (item.Image is { } image) return $"image {image.Width}×{image.Height} {item.Source}";
        return $"{string.Join(" ", item.Files!.Select(f => f.Path))} {item.Source}";
    }

    internal static string Fold(string text)
    {
        var builder = new StringBuilder(text.Length);
        foreach (var c in text.Normalize(NormalizationForm.FormD))
        {
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) builder.Append(char.ToLowerInvariant(c));
        }
        return builder.ToString();
    }
}

/// The history on disk: one JSON file, readable by this account only, as
/// everything under AppData is.
internal sealed class ClipboardHistoryStore(string? folder = null)
{
    private readonly string file = Path.Combine(folder ?? Settings.Folder, "history.json");
    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    /// One unreadable entry — a torn write, a newer version's format — costs
    /// that entry, not the whole history, which the next save would overwrite.
    public ClipboardHistory Load()
    {
        try
        {
            // Read as text: an editor that saved the file may have marked its encoding.
            using var document = JsonDocument.Parse(File.ReadAllText(file));
            var items = new List<ClipItem>();
            foreach (var entry in document.RootElement.GetProperty("items").EnumerateArray())
            {
                try
                {
                    if (entry.Deserialize<ClipItem>(Json) is { IsValid: true } item) items.Add(item);
                }
                catch (Exception error) when (error is JsonException or FormatException or InvalidOperationException)
                {
                }
            }
            return new ClipboardHistory(items);
        }
        catch
        {
            return ClipboardHistory.Empty;
        }
    }

    public void Save(ClipboardHistory history)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        Atomic.Write(file, JsonSerializer.SerializeToUtf8Bytes(new { items = history.Items }, Json));
    }

    public void Delete()
    {
        try { File.Delete(file); } catch { }
    }
}

/// When something was copied, in the short English the list uses.
internal static class RelativeTime
{
    public static string Describe(DateTime date, DateTime now)
    {
        var seconds = Math.Max(0, (long)(now - date).TotalSeconds);
        return seconds switch
        {
            < 60 => $"{seconds} sec. ago",
            < 3_600 => $"{seconds / 60} min. ago",
            < 86_400 => $"{seconds / 3_600} hr. ago",
            < 86_400 * 2 => "1 day ago",
            < 86_400 * 7 => $"{seconds / 86_400} days ago",
            < 86_400 * 30 => $"{seconds / (86_400 * 7)} wk. ago",
            < 86_400 * 365 => $"{seconds / (86_400 * 30)} mo. ago",
            _ => $"{seconds / (86_400 * 365)} yr. ago",
        };
    }
}
