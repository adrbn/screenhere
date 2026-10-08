using System.IO;
using System.Security.Cryptography;
using System.Windows.Media.Imaging;

namespace ScreenHere;

/// The copied pictures on disk, one PNG each, named by the digest of its bytes.
internal sealed class ClipboardImageStore(string? folder = null)
{
    private readonly string folder = folder ?? Path.Combine(Settings.Folder, "images");

    public string FilePath(ClipImage image) => Path.Combine(folder, image.Digest + ".png");

    /// Keeps `png` and describes it. Copying the same picture twice writes it once.
    public ClipImage Ingest(byte[] png)
    {
        var digest = Convert.ToHexString(SHA256.HashData(png)).ToLowerInvariant();
        using var stream = new MemoryStream(png);
        var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None).Frames[0];
        var image = new ClipImage(digest, frame.PixelWidth, frame.PixelHeight, png.LongLength);
        if (png.LongLength > ClipboardHistory.MaxImageBytes) return image;   // the history refuses it; keep nothing
        Directory.CreateDirectory(folder);
        var path = FilePath(image);
        if (!File.Exists(path)) Atomic.Write(path, png);
        return image;
    }

    public byte[]? Data(ClipImage image)
    {
        try { return File.ReadAllBytes(FilePath(image)); }
        catch { return null; }
    }

    /// Small enough for a row, decoded at that size rather than scaled down
    /// from a full capture.
    public BitmapSource? Thumbnail(ClipImage image, int side = 132)
    {
        try
        {
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.UriSource = new Uri(FilePath(image));
            // The tile is filled, so the shorter side is the one that counts.
            if (image.Width >= image.Height) bitmap.DecodePixelHeight = Math.Min(side, image.Height);
            else bitmap.DecodePixelWidth = Math.Min(side, image.Width);
            bitmap.EndInit();
            bitmap.Freeze();
            return bitmap;
        }
        catch
        {
            return null;
        }
    }

    /// A copy under a name of its own, never over an existing file.
    public string? Copy(ClipImage image, string into, DateTime now)
    {
        try
        {
            var name = $"Image {now:yyyy-MM-dd HHmmss}";
            var target = Path.Combine(into, name + ".png");
            for (var n = 2; File.Exists(target); n++) target = Path.Combine(into, $"{name} ({n}).png");
            File.Copy(FilePath(image), target);
            return target;
        }
        catch
        {
            return null;
        }
    }

    public void Remove(IEnumerable<string> digests)
    {
        foreach (var digest in digests)
        {
            try { File.Delete(Path.Combine(folder, digest + ".png")); } catch { }
        }
    }

    /// Sweeps pictures nothing points at any more.
    public void Prune(HashSet<string> keeping)
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(folder))
            {
                if (!keeping.Contains(Path.GetFileNameWithoutExtension(file))) File.Delete(file);
            }
        }
        catch
        {
        }
    }

    public void DeleteAll()
    {
        try { Directory.Delete(folder, recursive: true); } catch { }
    }
}
