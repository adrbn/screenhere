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

    public enum Status { Idle, Checking, UpToDate, Installing, Unreachable }

    /// The file a release carries for Windows. Releases without it — a fix
    /// that only concerns the Mac — are passed over.
    public const string AssetName = "ScreenHere-Windows.exe";
    private const string Releases = "https://api.github.com/repos/adrbn/screenhere/releases?per_page=15";
    private const string DownloadPrefix = "https://github.com/adrbn/screenhere/releases/download/";

    public Status State { get; private set; }
    public string? AvailableVersion { get; private set; }
    public event Action? Changed;

    private string? downloadUrl;
    /// Whether the last check reached GitHub at all.
    private bool reached = true;
    private readonly DispatcherTimer daily = new() { Interval = TimeSpan.FromHours(6) };
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(60) };
    /// For the update itself, which takes as long as the line needs — but
    /// not longer than a minute without a single byte arriving.
    private static readonly HttpClient Downloads = new() { Timeout = Timeout.InfiniteTimeSpan };
    private static readonly TimeSpan Stall = TimeSpan.FromSeconds(60);

    public static string CurrentVersion { get; } =
        Assembly.GetExecutingAssembly().GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "0.0.0";

    static Updater()
    {
        Client.DefaultRequestHeaders.UserAgent.ParseAdd($"ScreenHere/{CurrentVersion}");
        Downloads.DefaultRequestHeaders.UserAgent.ParseAdd($"ScreenHere/{CurrentVersion}");
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
        reached = true;
        try
        {
            using var document = JsonDocument.Parse(await Client.GetStringAsync(Releases));
            var found = Newest(document.RootElement, CurrentVersion);
            Settings.Current.LastUpdateCheck = DateTime.UtcNow;
            Settings.Current.Save();
            AvailableVersion = found?.Version;
            downloadUrl = found?.Url;
        }
        catch (Exception error)
        {
            // Offline, or GitHub has had enough questions for one hour. Asked
            // again tomorrow, or when the user asks — but said plainly, since
            // "up to date" from a check that never happened is a lie.
            reached = false;
            Trace("check failed: " + error.Message);
        }
        Set(AvailableVersion != null || !byUser ? Status.Idle
            : reached ? Status.UpToDate : Status.Unreachable, notify: true);
        if (State is not (Status.UpToDate or Status.Unreachable)) return;
        var answered = State;
        await Task.Delay(2500);
        if (State == answered) Set(Status.Idle, notify: true);
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

    /// How far the download is, from 0 to 1, while an update is installing.
    /// It stays at 0 when the server announces no size, which is why how much
    /// has arrived is kept too: a label that never moves cannot be told apart
    /// from an update that has stopped.
    public double Progress { get; private set; }
    public long Downloaded { get; private set; }

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
        Progress = 0;
        Downloaded = 0;
        Set(Status.Installing, notify: true);
        var fresh = running + ".new";
        var old = running + ".old";
        Trace($"install {CurrentVersion} -> {AvailableVersion} at {running}");
        try
        {
            // Off the interface's thread: seventy megabytes written a chunk at
            // a time would otherwise run entirely on it, and a thread that is
            // busy writing paints nothing and answers no button — which is
            // what updating looked like from the outside.
            await Task.Run(async () =>
            {
                // Unless an earlier try already put the new build in place and
                // only failed to start it: then there is nothing left to fetch.
                if (!Swapped(running, old))
                {
                    await Download(downloadUrl, fresh);
                    // A running program cannot be overwritten, but it can be
                    // renamed — once whatever read the new file lets go of it.
                    Atomic.Insist(() => File.Delete(old));
                    Atomic.Insist(() => File.Move(running, old));
                    Atomic.Insist(() => File.Move(fresh, running));
                    Trace("swapped");
                }
                else Trace("already swapped, nothing to fetch");
                await Relaunch(running);
            });
            Trace("quitting");
            ((App)System.Windows.Application.Current).Quit();
            Trace("quit");
        }
        catch (Exception error)
        {
            Trace("failed: " + error);
            // Half an exchange would leave nothing at all where ScreenHere is
            // started from, so the old copy goes back where it was.
            if (!File.Exists(running) && File.Exists(old))
            {
                try { File.Move(old, running); Trace("put the old one back"); } catch { }
            }
            try { File.Delete(fresh); } catch { }
            Set(Status.Idle, notify: true);
            // The new build may be in place all the same: opening ScreenHere
            // again is then all it takes.
            Toast.Show(Swapped(running, old) ? "Quit and reopen ScreenHere to finish updating" : "Couldn't install the update", Glyph.Warning);
        }
    }

    /// The running copy has been renamed aside and a new one sits in its place.
    private static bool Swapped(string running, string old) => File.Exists(old) && File.Exists(running);

    /// To a file, as it comes: 70 MB is more than a slow line carries in the
    /// minute a request is given by default, and more than memory needs to hold.
    private async Task Download(string url, string target)
    {
        // A line that goes quiet for a minute has stopped, and waiting on it
        // for ever is how an update sits on "Updating…" until the app is killed.
        using var stall = new CancellationTokenSource(Stall);
        Trace("fetching " + url);
        using var response = await Downloads.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, stall.Token);
        response.EnsureSuccessStatusCode();
        var total = response.Content.Headers.ContentLength ?? 0;
        Trace($"{(int)response.StatusCode}, {total} bytes announced");
        await using (var source = await response.Content.ReadAsStreamAsync(stall.Token))
        await using (var file = new FileStream(target, FileMode.Create, FileAccess.Write,
                                               FileShare.None, 128 * 1024, useAsync: true))
        {
            var buffer = new byte[128 * 1024];
            long done = 0;
            var shown = 0L;
            int read;
            while ((read = await source.ReadAsync(buffer, stall.Token)) > 0)
            {
                await file.WriteAsync(buffer.AsMemory(0, read), stall.Token);
                stall.CancelAfter(Stall);
                done += read;
                // Either way the label moves: a share of the whole when the
                // whole was announced, megabytes when it was not.
                if (done - shown < (total > 0 ? total / 100 : 1_000_000)) continue;
                shown = done;
                Downloaded = done;
                Progress = total > 0 ? (double)done / total : 0;
                Notify();
            }
            Trace($"{done} bytes written");
        }
        var head = new byte[2];
        await using (var check = File.OpenRead(target))
        {
            if (check.Length < 100_000 || await check.ReadAsync(head) < 2 || head[0] != 'M' || head[1] != 'Z') throw new InvalidDataException($"{check.Length} bytes, not a program");
        }
    }

    /// Starts the new copy, which waits for this one to quit. A file that was
    /// just written is often held for a moment by the antivirus reading it,
    /// and cannot be started until it lets go: tried again for a while.
    private static async Task Relaunch(string running)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                Process.Start(new ProcessStartInfo(running, "--updated") { UseShellExecute = false });
                Trace($"started, try {attempt + 1}");
                return;
            }
            catch (Exception error) when (attempt < 20)
            {
                Trace($"try {attempt + 1} refused: {error.Message}");
                await Task.Delay(750);
            }
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

    /// Every step of an update, as it happens, next to the settings. An
    /// update that goes wrong is over by the time anyone can look at it, so
    /// the looking is done afterwards, here.
    private static void Trace(string step)
    {
        try
        {
            Directory.CreateDirectory(Settings.Folder);
            File.AppendAllText(Path.Combine(Settings.Folder, "update.log"), $"{DateTime.Now:HH:mm:ss} {step}\n");
        }
        catch
        {
        }
    }

    private void Set(Status state, bool notify)
    {
        State = state;
        if (notify) Notify();
    }

    /// The panel is built of interface objects, so it is told from the thread
    /// that owns them whoever noticed the change.
    private void Notify()
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess()) Changed?.Invoke();
        else dispatcher.BeginInvoke(() => Changed?.Invoke());
    }
}
