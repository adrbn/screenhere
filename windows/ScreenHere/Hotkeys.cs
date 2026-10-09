using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace ScreenHere;

[Flags]
internal enum Modifiers
{
    None = 0,
    Win = 1,
    Control = 2,
    Alt = 4,
    Shift = 8,
}

/// What a shortcut can be for.
internal enum Feature { Screen, Window, Text, History }

/// A key and its modifiers, as the user records it.
internal readonly record struct KeyShortcut(int Key, Modifiers Modifiers)
{
    /// Where every feature starts: the Mac's ⇧⌘ shortcuts, with Win for ⌘.
    public static KeyShortcut Default(Feature feature) => new(feature switch
    {
        Feature.Screen => '3',
        Feature.Window => '2',
        Feature.Text => '7',
        _ => '8',
    }, Modifiers.Win | Modifiers.Shift);

    /// The same capture, sent to the clipboard: the shortcut with the other
    /// of Win and Ctrl added. Some keyboards have the two swapped, to put
    /// Ctrl under the thumb like the Mac's ⌘ — whichever of them the shortcut
    /// uses, the one left over is the clipboard's.
    public KeyShortcut ToClipboard =>
        this with { Modifiers = Modifiers | (Modifiers.HasFlag(Modifiers.Control) ? Modifiers.Win : Modifiers.Control) };

    /// "Ctrl", or "Win": what to add for the clipboard.
    public string ClipboardKey => Modifiers.HasFlag(Modifiers.Control) ? "Win" : "Ctrl";

    /// Why a shortcut cannot be used for `feature`, in the words the recorder
    /// shows. `others` are the shortcuts the other features have.
    public string? Problem(Feature feature, IEnumerable<(Feature Feature, KeyShortcut Shortcut)> others,
                           IReadOnlySet<KeyShortcut>? powerToys = null)
    {
        if (powerToys != null && (powerToys.Contains(this) || powerToys.Contains(ToClipboard))) return "Used by PowerToys";
        var both = Modifiers.Win | Modifiers.Control;
        if ((Modifiers & both) == both) return "Win+Ctrl is for the clipboard";
        if ((Modifiers & (both | Modifiers.Alt)) == 0) return "Add Win, Ctrl or Alt";
        // Ctrl+C or Alt+F4 taken by a capture would be a trap.
        if (System.Numerics.BitOperations.PopCount((uint)Modifiers) < 2) return "Add Shift";
        if (this == new KeyShortcut('S', Modifiers.Win | Modifiers.Shift)) return "Used by Windows";
        return Rival(feature, others) is { } other ? $"Used by {other}" : null;
    }

    /// The other feature this shortcut would collide with, if any: the same
    /// keys, or — for the two captures — the same keys once the clipboard's
    /// are added.
    public Feature? Rival(Feature feature, IEnumerable<(Feature Feature, KeyShortcut Shortcut)> others)
    {
        var mine = Keys(feature, this);
        foreach (var (other, shortcut) in others)
        {
            if (other != feature && Keys(other, shortcut).Any(mine.Contains)) return other;
        }
        return null;

        static KeyShortcut[] Keys(Feature feature, KeyShortcut shortcut) =>
            (feature is Feature.Screen or Feature.Window) ? new[] { shortcut, shortcut.ToClipboard } : new[] { shortcut };
    }
    public string Label => Describe(Modifiers) + KeyName(Key);

    /// "Win+Shift+", in the order Windows itself writes shortcuts.
    public static string Describe(Modifiers modifiers)
    {
        var text = "";
        if (modifiers.HasFlag(Modifiers.Win)) text += "Win+";
        if (modifiers.HasFlag(Modifiers.Control)) text += "Ctrl+";
        if (modifiers.HasFlag(Modifiers.Alt)) text += "Alt+";
        if (modifiers.HasFlag(Modifiers.Shift)) text += "Shift+";
        return text;
    }

    private static readonly Dictionary<int, string> Named = new()
    {
        [0x08] = "Backspace", [0x09] = "Tab", [0x0D] = "Enter", [0x13] = "Pause", [0x1B] = "Esc", [0x20] = "Space",
        [0x21] = "PgUp", [0x22] = "PgDn", [0x23] = "End", [0x24] = "Home", [0x25] = "←", [0x26] = "↑", [0x27] = "→",
        [0x28] = "↓", [0x2C] = "PrtSc", [0x2D] = "Ins", [0x2E] = "Del",
    };

    /// The key as the keyboard prints it: the digit row reads 2 on a French
    /// keyboard too, since that is what the key is called.
    public static string KeyName(int key)
    {
        if (key is >= '0' and <= '9' or >= 'A' and <= 'Z') return ((char)key).ToString();
        if (key is >= 0x70 and <= 0x87) return $"F{key - 0x6F}";
        if (key is >= 0x60 and <= 0x69) return $"Num {key - 0x60}";
        if (Named.TryGetValue(key, out var name)) return name;
        const uint toCharacter = 2;
        var typed = (char)(Native.MapVirtualKey((uint)key, toCharacter) & 0x7FFF);
        return typed > ' ' ? char.ToUpperInvariant(typed).ToString() : $"Key {key}";
    }

    public static bool IsModifier(int key) => ModifierOf(key) != Modifiers.None;

    public static Modifiers ModifierOf(int key) => key switch
    {
        0x5B or 0x5C => Modifiers.Win,
        0x10 or 0xA0 or 0xA1 => Modifiers.Shift,
        0x11 or 0xA2 or 0xA3 => Modifiers.Control,
        0x12 or 0xA4 or 0xA5 => Modifiers.Alt,
        _ => Modifiers.None,
    };
}

/// The global shortcuts.
///
/// Windows keeps Win+Shift+digit for the taskbar, and refuses to register it
/// for anyone else. So, as on the Mac, ScreenHere takes the shortcuts over: a
/// keyboard hook sees the keys first and keeps the combinations it was given.
/// Nothing is written anywhere, so quitting gives everything back at once.
internal static class Hotkeys
{
    private static IntPtr hook;
    // Held for as long as the hook: the delegate is all that keeps it alive.
    private static Native.LowLevelKeyboardProc? callback;
    /// Replaced whole on every change, never edited: the hook reads it from
    /// its own thread.
    private static volatile Dictionary<KeyShortcut, Action> bindings = new();
    private static readonly HashSet<int> Swallowed = [];
    /// Where the shortcuts' actions run: the app's own thread.
    private static Dispatcher? dispatcher;
    /// Where the hook lives. Windows drops, without a word, a keyboard hook
    /// that takes too long to answer — and the app's own thread is sometimes
    /// busy encoding a capture or waiting for the clipboard. A thread that
    /// does nothing else always answers at once.
    private static Dispatcher? hookThread;

    /// While set, every key goes here instead: a shortcut is being typed.
    /// Called with the key (0 for a change of modifiers alone) and what is held.
    public static Action<int, Modifiers>? Recorder { get => recorder; set => recorder = value; }
    private static volatile Action<int, Modifiers>? recorder;

    /// While set, Esc goes here and nowhere else: a selection that never takes
    /// focus still has to be cancelled from the keyboard.
    public static Action? OnEscape { get => onEscape; set => onEscape = value; }
    private static volatile Action? onEscape;

    private static IntPtr mouseHook;
    private static Native.LowLevelKeyboardProc? mouseCallback;
    private static volatile Action<int, int>? onClick;

    /// While set, every press of a mouse button anywhere is reported here,
    /// in screen pixels, and still goes where it was going. For the list that
    /// closes when something else is clicked: losing the keyboard is not
    /// enough to know, since the desktop, the taskbar and a window that never
    /// had the keyboard take a click without taking it. The mouse is only
    /// listened to while something asks.
    public static void WatchClicks(Action<int, int>? handler)
    {
        onClick = handler;
        hookThread?.BeginInvoke(() =>
        {
            if (onClick != null && mouseHook == IntPtr.Zero)
            {
                mouseCallback = HandleMouse;
                mouseHook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, mouseCallback, Native.GetModuleHandle(null), 0);
            }
            else if (onClick == null && mouseHook != IntPtr.Zero)
            {
                Native.UnhookWindowsHookEx(mouseHook);
                mouseHook = IntPtr.Zero;
                mouseCallback = null;
            }
        });
    }

    private static IntPtr HandleMouse(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0 && wParam.ToInt32() is Native.WM_LBUTTONDOWN or Native.WM_RBUTTONDOWN or Native.WM_MBUTTONDOWN
            && onClick is { } handler)
        {
            var point = Marshal.PtrToStructure<Native.POINT>(lParam);
            dispatcher?.BeginInvoke(() => handler(point.X, point.Y));
        }
        return Native.CallNextHookEx(mouseHook, code, wParam, lParam);
    }

    public static bool IsInstalled => hook != IntPtr.Zero;

    /// Why Windows refused the hook, or zero.
    public static int InstallError { get; private set; }

    public static void Install()
    {
        if (IsInstalled || hookThread != null) return;
        dispatcher = Dispatcher.CurrentDispatcher;
        using var ready = new ManualResetEventSlim();
        var thread = new Thread(() =>
        {
            hookThread = Dispatcher.CurrentDispatcher;
            callback = Handle;
            hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, callback, Native.GetModuleHandle(null), 0);
            InstallError = hook == IntPtr.Zero ? Marshal.GetLastWin32Error() : 0;
            ready.Set();
            // The hook is called through this thread's messages.
            Dispatcher.Run();
            if (hook != IntPtr.Zero) Native.UnhookWindowsHookEx(hook);
            hook = IntPtr.Zero;
            callback = null;
        }) { IsBackground = true, Name = "ScreenHere shortcuts", Priority = ThreadPriority.AboveNormal };
        thread.Start();
        ready.Wait();
    }

    public static void Uninstall()
    {
        hookThread?.InvokeShutdown();
        hookThread = null;
    }

    /// Takes over every shortcut in `shortcuts`, and only those.
    public static void Rebind(Dictionary<KeyShortcut, Action> shortcuts) => bindings = shortcuts;

    private static IntPtr Handle(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code < 0) return Native.CallNextHookEx(hook, code, wParam, lParam);
        var info = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
        var key = (int)info.vkCode;
        // Our own mask key is nobody's shortcut. Keys other tools type are
        // taken like any other, so a macro pad can press Win+Shift+3 too.
        if (key == Native.MaskKey) return Native.CallNextHookEx(hook, code, wParam, lParam);
        var message = wParam.ToInt32();
        var down = message is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN;

        if (KeyShortcut.IsModifier(key))
        {
            if (Recorder is { } recorder)
            {
                // The key's own state is not in yet while the hook runs.
                var held = down ? Held() | KeyShortcut.ModifierOf(key) : Held() & ~KeyShortcut.ModifierOf(key);
                dispatcher?.BeginInvoke(() => recorder(0, held));
            }
            return Native.CallNextHookEx(hook, code, wParam, lParam);
        }

        if (!down)
        {
            // The release of a key we kept must not reach the app either.
            return Swallowed.Remove(key) ? 1 : Native.CallNextHookEx(hook, code, wParam, lParam);
        }

        var modifiers = Held();
        if (Recorder is { } typing)
        {
            Swallow(key, modifiers);
            dispatcher?.BeginInvoke(() => typing(key, modifiers));
            return 1;
        }

        if (key == 0x1B && modifiers == Modifiers.None && OnEscape is { } escape)
        {
            Swallowed.Add(key);
            dispatcher?.BeginInvoke(escape);
            return 1;
        }

        if (bindings.TryGetValue(new KeyShortcut(key, modifiers), out var action))
        {
            // A held key repeats; one press is one capture.
            if (!Swallowed.Contains(key)) dispatcher?.BeginInvoke(action);
            Swallow(key, modifiers);
            return 1;
        }
        return Native.CallNextHookEx(hook, code, wParam, lParam);
    }

    private static void Swallow(int key, Modifiers modifiers)
    {
        Swallowed.Add(key);
        if (modifiers.HasFlag(Modifiers.Win) || modifiers.HasFlag(Modifiers.Alt)) Native.SendMaskKey();
    }

    private static Modifiers Held()
    {
        static bool IsDown(int key) => (Native.GetAsyncKeyState(key) & 0x8000) != 0;
        var held = Modifiers.None;
        if (IsDown(0x5B) || IsDown(0x5C)) held |= Modifiers.Win;
        if (IsDown(0x11)) held |= Modifiers.Control;
        if (IsDown(0x12)) held |= Modifiers.Alt;
        if (IsDown(0x10)) held |= Modifiers.Shift;
        return held;
    }
}
