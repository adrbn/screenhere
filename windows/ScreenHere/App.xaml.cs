using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;

namespace ScreenHere;

public partial class App : Application
{
    private Mutex? instance;
    private bool quitting;

    /// What a second launch can ask of the one already running: nothing opens
    /// its panel, `--do screen` and the others press a shortcut for it — for a
    /// macro pad, a script, or a keyboard with keys to spare.
    private static readonly (string Name, Action Run)[] Commands =
    [
        ("open", () => ((App)Current).Reopen()),
        ("screen", () => Capture.Screen(toClipboard: false)),
        ("window", () => Capture.Window(toClipboard: false)),
        ("text", TextCapture.Run),
        ("history", HistoryWindow.Open),
        // The shared clipboard, driven without its panel — only for a build
        // being tried out under a profile of its own.
        ("sync-on", () => Trying(() => SyncController.Shared.SetEnabled(true))),
        ("sync-ask", () => Trying(SyncController.Shared.BeginPairing)),
        ("sync-pick", () => Trying(() =>
        {
            SyncController.Shared.BeginPairing();
            if (SyncController.Shared.Nearby.FirstOrDefault() is { } device) SyncController.Shared.Pair(device);
        })),
        ("sync-confirm", () => Trying(SyncController.Shared.Confirm)),
        // Opens the panel, then makes it grow and shrink while it is up.
        ("panel-grow", () => Trying(() =>
        {
            PanelWindow.Open();
            ((App)Current).Later(1500, () => SyncController.Shared.SetEnabled(true));
            ((App)Current).Later(3000, SyncController.Shared.BeginPairing);
            ((App)Current).Later(4500, () => SyncController.Shared.SetEnabled(false));
        })),
        ("sync-status", () => Trying(() => File.WriteAllText(Path.Combine(Settings.Folder, "sync-status.txt"), SyncController.Shared.Describe()))),
    ];

    private static void Trying(Action action)
    {
        if (Settings.Profile != null) action();
    }

    /// A build tried out under its own profile runs beside the installed copy.
    private static string Scope => @"Local\ScreenHere" + (Settings.Profile is { } profile
        ? "." + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(profile.ToLowerInvariant())))[..12]
        : "");

    private static EventWaitHandle Signal(string command) => new(false, EventResetMode.AutoReset, $"{Scope}.{command}");

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        // Pages still declare windows-1252 and its cousins.
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        DispatcherUnhandledException += (_, error) =>
        {
            // A tray app that dies takes the shortcuts with it: note it, carry on.
            Log(error.Exception);
            error.Handled = true;
        };

        var shots = Array.IndexOf(e.Args, "--shots");
        if (shots >= 0 && shots + 1 < e.Args.Length)
        {
            Shots.Run(e.Args[shots + 1]);
            Shutdown();
            return;
        }

        var read = Array.IndexOf(e.Args, "--read");
        if (read >= 0 && read + 2 < e.Args.Length)
        {
            ReadText(e.Args[read + 1], e.Args[read + 2]);
            return;
        }

        // One ScreenHere at a time. Opening it again shows the first one's
        // panel, and brings its tray icon back if it was hidden.
        var updated = e.Args.Contains("--updated") || e.Args.Contains("--moved-in");
        var asked = Array.IndexOf(e.Args, "--do") is var at and >= 0 && at + 1 < e.Args.Length ? e.Args[at + 1] : null;
        instance = new Mutex(false, Scope + ".Instance");
        var signals = Commands.Select(c => Signal(c.Name)).ToArray();
        if (!Acquire(instance, updated ? 8_000 : 0))
        {
            signals[Math.Max(0, Array.FindIndex(Commands, c => c.Name == asked))].Set();
            instance = null;
            Shutdown();
            return;
        }
        if (Installation.HandOver(e.Args))
        {
            try { instance.ReleaseMutex(); } catch { }
            instance = null;
            Shutdown();
            return;
        }

        Theme.Apply();
        Hotkeys.Install();
        if (!Hotkeys.IsInstalled) Log(new InvalidOperationException($"Keyboard hook refused: error {Hotkeys.InstallError}"));
        Features.Activate();
        Tray.Shared.Start();
        Updater.Shared.Start();

        SystemEvents.UserPreferenceChanged += (_, _) => Dispatcher.BeginInvoke(() =>
        {
            Theme.Apply();
            Tray.Shared.Refresh();
        });
        SystemEvents.DisplaySettingsChanged += (_, _) => Displays.ForgetNames();
        // Sign-out and shutdown do not reliably run the normal exit.
        SessionEnding += (_, _) => ClipboardController.Shared.Flush();

        var listener = new Thread(() =>
        {
            while (!quitting)
            {
                var command = Commands[WaitHandle.WaitAny(signals)];
                if (!quitting) Dispatcher.BeginInvoke(command.Run);
            }
        }) { IsBackground = true };
        listener.Start();

        Memory.SettleSoon(6);
        var atLogin = e.Args.Contains("--login");
        if (!Settings.Current.Greeted)
        {
            // Launching at login is what keeps the shortcuts working after a
            // restart; it is on unless the user turns it off.
            Settings.Current.Greeted = true;
            Settings.Current.Save();
            LoginItem.SetEnabled(true);
            Later(600, PanelWindow.Open);
        }
        else if (!atLogin && !updated && Settings.Current.TrayIconHidden)
        {
            Reopen();
        }
    }

    private static bool Acquire(Mutex mutex, int milliseconds)
    {
        try
        {
            return mutex.WaitOne(milliseconds);
        }
        catch (AbandonedMutexException)
        {
            // The previous run died holding it; it is ours now.
            return true;
        }
    }

    private void Reopen()
    {
        if (Settings.Current.TrayIconHidden) Tray.Shared.SetHidden(false);
        PanelWindow.Open();
    }

    private void Later(int milliseconds, Action action)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(milliseconds) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            action();
        };
        timer.Start();
    }

    /// Gives everything back: the shortcuts are Windows' again the moment the
    /// hook is gone.
    public void Quit()
    {
        if (quitting) return;
        quitting = true;
        ClipboardController.Shared.Flush();
        Hotkeys.Uninstall();
        ScreenshotWatcher.Stop();
        Tray.Shared.Dispose();
        try { instance?.ReleaseMutex(); } catch { }
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Hotkeys.Uninstall();
        base.OnExit(e);
    }

    /// `--read <picture> <text file>`: what the recogniser makes of a picture,
    /// for checking it without selecting anything on screen.
    private async void ReadText(string picture, string output)
    {
        try
        {
            using var bitmap = new System.Drawing.Bitmap(picture);
            File.WriteAllText(output, await TextRecognizer.Recognize(bitmap));
        }
        catch (Exception error)
        {
            File.WriteAllText(output, "error: " + error.Message);
        }
        Shutdown();
    }

    private static void Log(Exception error)
    {
        try
        {
            Directory.CreateDirectory(Settings.Folder);
            File.AppendAllText(Path.Combine(Settings.Folder, "errors.log"), $"{DateTime.Now:s} {error}\n\n");
        }
        catch
        {
        }
    }
}
