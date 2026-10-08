namespace ScreenHere;

/// What is switched on, and the shortcuts that follow from it.
internal static class Features
{
    /// Anything the panel shows about the features has changed.
    public static event Action? Changed;

    private static readonly Dictionary<Feature, KeyShortcut> Shortcuts = new();

    /// The feature whose shortcut is being typed, if any. The recorder follows
    /// this rather than a state of its own, so whatever ends the recording
    /// ends it everywhere.
    public static Feature? Recording { get; private set; }

    private static Settings Settings => Settings.Current;

    public static void Activate()
    {
        foreach (var feature in Enum.GetValues<Feature>()) Shortcuts[feature] = KeyShortcut.Default(feature);
        // Stored one by one, each checked against those already in place: a
        // file edited by hand cannot give two features the same keys.
        foreach (var feature in Enum.GetValues<Feature>())
        {
            if (!Settings.Shortcuts.TryGetValue(feature.ToString(), out var stored) || stored.Length != 2) continue;
            var shortcut = new KeyShortcut(stored[0], (Modifiers)stored[1]);
            if (shortcut.Problem(feature, Others()) == null) Shortcuts[feature] = shortcut;
        }
        PowerToys.Refresh();
        ClipboardController.Shared.Activate();
        LinkPreviews.Shared.Activate();
        SyncController.Shared.Activate();
        ClipboardController.Shared.Watch();
        Rebind();
        if (Settings.PreviewOnCapturedScreen) ScreenshotWatcher.Start();
    }

    public static KeyShortcut Shortcut(Feature feature) => Shortcuts.GetValueOrDefault(feature, KeyShortcut.Default(feature));

    public static bool IsOn(Feature feature) => feature switch
    {
        Feature.Screen => Settings.ScreenEnabled,
        Feature.Window => Settings.WindowEnabled,
        Feature.Text => Settings.TextEnabled,
        _ => ClipboardController.Shared.IsEnabled,
    };

    public static void Set(Feature feature, bool on)
    {
        switch (feature)
        {
            case Feature.Screen: Settings.ScreenEnabled = on; break;
            case Feature.Window: Settings.WindowEnabled = on; break;
            case Feature.Text: Settings.TextEnabled = on; break;
            case Feature.History: ClipboardController.Shared.SetEnabled(on); break;
        }
        Change();
    }

    /// Turning this on also covers the captures other tools save, so every
    /// capture gets its preview.
    public static void SetPreview(bool on)
    {
        Settings.PreviewOnCapturedScreen = on;
        Change();
        if (on) ScreenshotWatcher.Start();
        else ScreenshotWatcher.Stop();
    }

    public static void SetCapturesToClipboard(bool on)
    {
        Settings.CapturesToClipboard = on;
        Change();
    }

    private static IEnumerable<(Feature, KeyShortcut)> Others() => Shortcuts.Select(pair => (pair.Key, pair.Value));

    /// Saves and takes over `shortcut`, unless the rules refuse it. A shortcut
    /// that goes through ends the recording.
    public static string? SetShortcut(Feature feature, KeyShortcut shortcut)
    {
        PowerToys.Refresh();
        if (shortcut.Problem(feature, Others(), PowerToys.Shortcuts) is { } problem) return problem;
        Shortcuts[feature] = shortcut;
        if (shortcut == KeyShortcut.Default(feature)) Settings.Shortcuts.Remove(feature.ToString());
        else Settings.Shortcuts[feature.ToString()] = [shortcut.Key, (int)shortcut.Modifiers];
        Recording = null;
        Hotkeys.Recorder = null;
        Change();
        return null;
    }

    /// Back to the default — unless another feature has been given it since.
    public static string? ResetShortcut(Feature feature) => SetShortcut(feature, KeyShortcut.Default(feature));

    /// The shortcuts stay taken while a new one is typed: the recorder only
    /// ever adds state that something else can clear, so a panel that closes
    /// mid-recording leaves nothing switched off.
    public static void BeginRecording(Feature feature, Action<int, Modifiers> onKey)
    {
        Recording = feature;
        Hotkeys.Recorder = onKey;
        Changed?.Invoke();
    }

    public static void EndRecording()
    {
        if (Recording == null) return;
        Recording = null;
        Hotkeys.Recorder = null;
        Changed?.Invoke();
    }

    private static void Change()
    {
        Settings.Save();
        Rebind();
        Changed?.Invoke();
    }

    /// Who else has this feature's shortcut, if anyone. ScreenHere sees the
    /// keyboard first and would win; it leaves the shortcut to them instead,
    /// and the tile says so.
    public static string? Conflict(Feature feature)
    {
        var shortcut = Shortcut(feature);
        var captures = feature is Feature.Screen or Feature.Window;
        return PowerToys.Shortcuts.Contains(shortcut) || (captures && PowerToys.Shortcuts.Contains(shortcut.ToClipboard)) ? "PowerToys" : null;
    }

    /// PowerToys' settings may have changed since they were last read: the
    /// panel asks when it opens.
    public static void RefreshConflicts()
    {
        if (!PowerToys.Refresh()) return;
        Rebind();
        Changed?.Invoke();
    }

    private static bool Takes(Feature feature) => IsOn(feature) && Conflict(feature) == null;

    private static void Rebind()
    {
        var shortcuts = new Dictionary<KeyShortcut, Action>();
        if (Takes(Feature.Screen))
        {
            shortcuts[Shortcut(Feature.Screen)] = () => Capture.Screen(toClipboard: false);
            shortcuts[Shortcut(Feature.Screen).ToClipboard] = () => Capture.Screen(toClipboard: true);
        }
        if (Takes(Feature.Window))
        {
            shortcuts[Shortcut(Feature.Window)] = () => Capture.Window(toClipboard: false);
            shortcuts[Shortcut(Feature.Window).ToClipboard] = () => Capture.Window(toClipboard: true);
        }
        if (Takes(Feature.Text)) shortcuts[Shortcut(Feature.Text)] = TextCapture.Run;
        if (Takes(Feature.History)) shortcuts[Shortcut(Feature.History)] = HistoryWindow.Toggle;
        Hotkeys.Rebind(shortcuts);
    }
}
