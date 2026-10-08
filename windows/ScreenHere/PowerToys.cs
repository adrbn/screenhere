using System.IO;
using System.Text.Json;

namespace ScreenHere;

/// The shortcuts PowerToys has, so ScreenHere never takes one of them.
///
/// ScreenHere sees the keyboard first, and would win every time. PowerToys was
/// there before it, and is what its user set up on purpose: a shortcut of
/// theirs is refused by the recorder, and one of ScreenHere's that turns out
/// to be theirs as well is left to them.
internal static class PowerToys
{
    private static readonly string Folder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "PowerToys");

    private static HashSet<KeyShortcut> shortcuts = [];

    public static IReadOnlySet<KeyShortcut> Shortcuts => shortcuts;

    /// Reads PowerToys' settings again. True when its shortcuts changed.
    public static bool Refresh()
    {
        var found = Read(Folder);
        var changed = !found.SetEquals(shortcuts);
        shortcuts = found;
        return changed;
    }

    internal static HashSet<KeyShortcut> Read(string folder)
    {
        var found = new HashSet<KeyShortcut>();
        try
        {
            if (!Directory.Exists(folder)) return found;
            // Every module keeps a settings.json, and writes its shortcuts the
            // same way: { win, ctrl, alt, shift, code }.
            foreach (var file in Directory.EnumerateFiles(folder, "settings.json", SearchOption.AllDirectories))
            {
                try
                {
                    using var document = JsonDocument.Parse(File.ReadAllText(file));
                    Collect(document.RootElement, found);
                }
                catch
                {
                }
            }
            var remaps = Path.Combine(folder, "Keyboard Manager", "default.json");
            if (File.Exists(remaps))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(remaps));
                CollectRemaps(document.RootElement, found);
            }
        }
        catch
        {
            // Unreadable settings are no reason to refuse anything.
        }
        return found;
    }

    internal static void Collect(JsonElement element, HashSet<KeyShortcut> found)
    {
        if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray()) Collect(item, found);
            return;
        }
        if (element.ValueKind != JsonValueKind.Object) return;

        if (element.TryGetProperty("code", out var code) && code.ValueKind == JsonValueKind.Number && code.TryGetInt32(out var key) && key > 0
            && element.TryGetProperty("win", out _))
        {
            var modifiers = Modifiers.None;
            if (Flag(element, "win")) modifiers |= Modifiers.Win;
            if (Flag(element, "ctrl")) modifiers |= Modifiers.Control;
            if (Flag(element, "alt")) modifiers |= Modifiers.Alt;
            if (Flag(element, "shift")) modifiers |= Modifiers.Shift;
            if (modifiers != Modifiers.None) found.Add(new KeyShortcut(key, modifiers));
        }
        foreach (var property in element.EnumerateObject()) Collect(property.Value, found);

        static bool Flag(JsonElement owner, string name) =>
            owner.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.True;
    }

    /// Keyboard Manager's shortcut remaps: "162;160;76" is Ctrl+Shift+L.
    internal static void CollectRemaps(JsonElement root, HashSet<KeyShortcut> found)
    {
        if (!root.TryGetProperty("remapShortcuts", out var remaps)) return;
        foreach (var scope in new[] { "global", "appSpecific" })
        {
            if (!remaps.TryGetProperty(scope, out var list) || list.ValueKind != JsonValueKind.Array) continue;
            foreach (var remap in list.EnumerateArray())
            {
                if (!remap.TryGetProperty("originalKeys", out var keys) || keys.GetString() is not { } text) continue;
                var modifiers = Modifiers.None;
                var key = 0;
                foreach (var part in text.Split(';', StringSplitOptions.RemoveEmptyEntries))
                {
                    if (!int.TryParse(part, out var code)) continue;
                    // 260 is Keyboard Manager's own "either Win key".
                    var modifier = code == 260 ? Modifiers.Win : KeyShortcut.ModifierOf(code);
                    if (modifier != Modifiers.None) modifiers |= modifier;
                    else key = code;
                }
                if (key != 0 && modifiers != Modifiers.None) found.Add(new KeyShortcut(key, modifiers));
            }
        }
    }
}
