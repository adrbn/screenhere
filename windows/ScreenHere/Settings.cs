using System.IO;
using System.Text.Json;
using Microsoft.Win32;

namespace ScreenHere;

/// The app's preferences, in one small file next to the history.
internal sealed class Settings
{
    public bool ScreenEnabled { get; set; } = true;
    /// Capturing a window is a beta: off until turned on.
    public bool WindowEnabled { get; set; }
    /// The shortcuts that are not the default ones, by feature: key, modifiers.
    public Dictionary<string, int[]> Shortcuts { get; set; } = new();
    public bool TextEnabled { get; set; } = true;
    /// Off unless the user turns it on: an update must never start recording
    /// everything someone copies without them asking for it.
    public bool HistoryEnabled { get; set; }
    public bool LinkPreviews { get; set; }
    public bool PreviewOnCapturedScreen { get; set; } = true;
    /// Where Win+Shift+3 sends a capture: the Screenshots folder, or the clipboard.
    public bool CapturesToClipboard { get; set; }
    /// The shared clipboard: off until turned on, and nothing to share with
    /// until a device has been connected.
    public bool SyncEnabled { get; set; }
    public string? SyncDeviceId { get; set; }
    public string? SyncPeerId { get; set; }
    public string? SyncPeerName { get; set; }
    /// The key shared with the other device, under Windows' protection.
    public string? SyncPeerKey { get; set; }
    public string? SyncPeerAddress { get; set; }
    public bool TrayIconHidden { get; set; }
    public bool Greeted { get; set; }
    public DateTime? LastUpdateCheck { get; set; }

    // MARK: - Storage

    /// Set to try a build without touching the installed copy: its settings,
    /// history and captures all go under this folder instead.
    public static string? Profile { get; } = Environment.GetEnvironmentVariable("SCREENHERE_PROFILE") is { Length: > 0 } profile ? profile : null;

    public static string Folder { get; } = Profile ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ScreenHere");

    private static string FilePath => Path.Combine(Folder, "settings.json");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public static Settings Current { get; private set; } = Load();

    private static Settings Load()
    {
        try
        {
            return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
        }
        catch
        {
            return new Settings();
        }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Folder);
            Atomic.Write(FilePath, JsonSerializer.SerializeToUtf8Bytes(this, Json));
        }
        catch
        {
            // A preference that did not stick is asked for again next time.
        }
    }
}

internal static class Atomic
{
    /// Writes beside the file and swaps it in, so a crash mid-write leaves the
    /// old file rather than half of the new one.
    public static void Write(string path, byte[] bytes)
    {
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, path, overwrite: true);
    }
}

/// Launch at sign-in, the way Windows shows it under Settings › Apps › Startup.
internal static class LoginItem
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "ScreenHere";

    public static bool IsEnabled
    {
        get
        {
            if (Shots.IsRunning) return true;
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string command
                && command.Contains(Environment.ProcessPath ?? "\0", StringComparison.OrdinalIgnoreCase);
        }
    }

    public static void SetEnabled(bool on)
    {
        // A build being tried out must not put itself in the way of the real one.
        if (Settings.Profile != null) return;
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) key.SetValue(Name, $"\"{Environment.ProcessPath}\" --login");
            else key.DeleteValue(Name, throwOnMissingValue: false);
        }
        catch
        {
            // Left as it was; the switch shows the real state.
        }
    }
}
