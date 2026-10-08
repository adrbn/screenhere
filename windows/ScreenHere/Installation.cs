using System.Diagnostics;
using System.IO;

namespace ScreenHere;

/// ScreenHere is one file, and the first time it is opened it moves in: a copy
/// under the user's own Programs folder, where it stays put for the login
/// item and the Start menu to point at. No administrator, nothing outside the
/// user's profile.
internal static class Installation
{
    public static string Home { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "ScreenHere");

    public static string Target { get; } = Path.Combine(Home, "ScreenHere.exe");

    private static string StartMenuShortcut => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.Programs), "ScreenHere.lnk");

    /// True when this copy is the downloaded file rather than the installed
    /// one, and the installed one has been started in its place. Called while
    /// holding the instance lock, so no other copy is running.
    public static bool HandOver(string[] arguments)
    {
        var running = Environment.ProcessPath;
        // A build run from its build folder, or tried out under a profile of
        // its own, stays where it is.
        if (running == null || Settings.Profile != null || File.Exists(Path.ChangeExtension(running, ".dll"))) return false;
        try
        {
            if (string.Equals(Path.GetFullPath(running), Path.GetFullPath(Target), StringComparison.OrdinalIgnoreCase))
            {
                if (!File.Exists(StartMenuShortcut)) AddToStartMenu();
                return false;
            }
            Directory.CreateDirectory(Home);
            File.Copy(running, Target, overwrite: true);
            AddToStartMenu();
            Process.Start(new ProcessStartInfo(Target, string.Join(" ", arguments.Append("--moved-in"))) { UseShellExecute = false });
            return true;
        }
        catch
        {
            // Could not move in: run from here, as a portable app would.
            return false;
        }
    }

    /// So ScreenHere can be found again from Start — which is also how a
    /// hidden tray icon is brought back.
    private static void AddToStartMenu()
    {
        try
        {
            if (Type.GetTypeFromProgID("WScript.Shell") is not { } type || Activator.CreateInstance(type) is not { } shell) return;
            dynamic link = ((dynamic)shell).CreateShortcut(StartMenuShortcut);
            link.TargetPath = Target;
            link.WorkingDirectory = Home;
            link.Description = "Capture the screen under your pointer, copy text off the screen, and bring back what you copied.";
            link.Save();
        }
        catch
        {
            // A missing shortcut costs a search result, nothing else.
        }
    }
}
