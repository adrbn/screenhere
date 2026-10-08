using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Windows.Threading;

namespace ScreenHere;

/// Keeps ScreenHere up to date from its GitHub releases: checked once a day,
/// installed in place when the user says so.
internal sealed class Updater
{
    public static Updater Shared { get; } = new();

    public enum Status { Idle, Checking, UpToDate, Installing }

    /// The file a release carries for Windows. Releases without it — a fix
    /// that only concerns the Mac — are passed over.
    public const string AssetName = "ScreenHere-Windows.exe";
    private const string Releases = "https://api.github.com/repos/adrbn/screenhere/releases?per_page=15";
    private const string DownloadPrefix = "https://github.com/adrbn/screenhere/releases/download/";

    public Status State { get; private set; }
    public string? AvailableVersion { get; private set; }
    public event Action? Changed;

    private string? downloadUrl;
    private readonly DispatcherTimer daily = new() { Interval = TimeSpan.FromHours(6) };
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(60) };

    public static string CurrentVersion { get; } =
        Assembly.GetExecutingAssembly().GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0.0.0";

    static Updater()
    {
        Client.DefaultRequestHeaders.UserAgent.ParseAdd($"ScreenHere/{CurrentVersion}");
        Client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
    }

    public void Start()
    {
        CleanUp();
        daily.Tick += (_, _) => CheckIfDue();
        daily.Start();
        CheckIfDue();
    }

    private void CheckIfDue()
    {
        var last = Settings.Current.LastUpdateCheck;
        if (last == null || DateTime.UtcNow - last.Value > TimeSpan.FromHours(24)) Check(byUser: false);
    }

    public async void Check(bool byUser)
    {
        if (State is Status.Checking or Status.Installing) return;
        Set(Status.Checking, byUser);
        try
        {
            using var document = JsonDocument.Parse(await Client.GetStringAsync(Releases));
            var found = Newest(document.RootElement, CurrentVersion);
            Settings.Current.LastUpdateCheck = DateTime.UtcNow;
            Settings.Current.Save();
            AvailableVersion = found?.Version;
            downloadUrl = found?.Url;
        }
        catch
        {
            // Offline: asked again tomorrow, or when the user asks.
        }
        Set(AvailableVersion == null && byUser ? Status.UpToDate : Status.Idle, notify: true);
        if (State != Status.UpToDate) return;
        await Task.Delay(2500);
        if (State == Status.UpToDate) Set(Status.Idle, notify: true);
    }

    /// The newest release above `current` that has a Windows build, and where
    /// to get it.
    internal static (string Version, string Url)? Newest(JsonElement releases, string current)
    {
        (Version Version, string Url)? best = null;
        var installed = Version.TryParse(current, out var parsed) ? parsed : new Version(0, 0, 0);
        foreach (var release in releases.EnumerateArray())
        {
            if (release.TryGetProperty("draft", out var draft) && draft.GetBoolean()) continue;
            if (release.TryGetProperty("prerelease", out var pre) && pre.GetBoolean()) continue;
            if (!Version.TryParse(release.GetProperty("tag_name").GetString()?.TrimStart('v'), out var version)) continue;
            if (version <= installed || (best != null && version <= best.Value.Version)) continue;
            foreach (var asset in release.GetProperty("assets").EnumerateArray())
            {
                var url = asset.GetProperty("browser_download_url").GetString() ?? "";
                if (asset.GetProperty("name").GetString() == AssetName && url.StartsWith(DownloadPrefix)) best = (version, url);
            }
        }
        return best is { } b ? ($"{b.Version.Major}.{b.Version.Minor}.{Math.Max(0, b.Version.Build)}", b.Url) : null;
    }

    /// Downloads the new build next to the running one, swaps them and
    /// restarts. The shortcuts are back as soon as the new copy is up.
    public async void Install()
    {
        if (downloadUrl == null || State == Status.Installing) return;
        var running = Environment.ProcessPath;
        // A build run from its build folder is several files; only the
        // published single file can replace itself.
        if (running == null || File.Exists(Path.ChangeExtension(running, ".dll")))
        {
            try { Process.Start(new ProcessStartInfo("https://github.com/adrbn/screenhere/releases/latest") { UseShellExecute = true }); } catch { }
            return;
        }
        Set(Status.Installing, notify: true);
        var fresh = running + ".new";
        var old = running + ".old";
        try
        {
            var bytes = await Client.GetByteArrayAsync(downloadUrl);
            if (bytes.Length < 100_000 || bytes[0] != 'M' || bytes[1] != 'Z') throw new InvalidDataException();
            await File.WriteAllBytesAsync(fresh, bytes);
            // A running program cannot be overwritten, but it can be renamed.
            File.Delete(old);
            File.Move(running, old);
            File.Move(fresh, running);
            Process.Start(new ProcessStartInfo(running, "--updated") { UseShellExecute = false });
            ((App)System.Windows.Application.Current).Quit();
        }
        catch
        {
            try { File.Delete(fresh); } catch { }
            Set(Status.Idle, notify: true);
            Toast.Show("Couldn't install the update", Glyph.Warning);
        }
    }

    /// What the last update left behind.
    private static void CleanUp()
    {
        try
        {
            if (Environment.ProcessPath is { } running) File.Delete(running + ".old");
        }
        catch
        {
        }
    }

    private void Set(Status state, bool notify)
    {
        State = state;
        if (notify) Changed?.Invoke();
    }
}
