using System.Text.Json;
using System.Windows;

namespace ScreenHere.Tests;

public class KeyShortcutTests
{
    private const Modifiers WinShift = Modifiers.Win | Modifiers.Shift;
    private const Modifiers CtrlShift = Modifiers.Control | Modifiers.Shift;

    private static readonly (Feature, KeyShortcut)[] Defaults =
        Enum.GetValues<Feature>().Select(f => (f, KeyShortcut.Default(f))).ToArray();

    [Fact]
    public void TheDefaultsAreTheMacsWithWinForCommand()
    {
        Assert.Equal("Win+Shift+3", KeyShortcut.Default(Feature.Screen).Label);
        Assert.Equal("Win+Shift+2", KeyShortcut.Default(Feature.Window).Label);
        Assert.Equal("Win+Shift+7", KeyShortcut.Default(Feature.Text).Label);
        Assert.Equal("Win+Shift+8", KeyShortcut.Default(Feature.History).Label);
        Assert.All(Defaults, d => Assert.Null(d.Item2.Problem(d.Item1, Defaults)));
    }

    [Fact]
    public void TheClipboardIsTheOtherOfWinAndCtrl()
    {
        Assert.Equal("Win+Ctrl+Shift+3", new KeyShortcut('3', WinShift).ToClipboard.Label);
        Assert.Equal("Win+Ctrl+Shift+3", new KeyShortcut('3', CtrlShift).ToClipboard.Label);
        Assert.Equal("Ctrl", new KeyShortcut('3', WinShift).ClipboardKey);
        Assert.Equal("Win", new KeyShortcut('3', CtrlShift).ClipboardKey);
        Assert.Equal("Ctrl+Alt+Shift+3", new KeyShortcut('3', Modifiers.Alt | Modifiers.Shift).ToClipboard.Label);
    }

    [Fact]
    public void AShortcutNeedsTwoModifiersAndLeavesWinCtrlToTheClipboard()
    {
        Assert.Equal("Add Win, Ctrl or Alt", new KeyShortcut('3', Modifiers.Shift).Problem(Feature.Screen, Defaults));
        Assert.Equal("Add Win, Ctrl or Alt", new KeyShortcut('3', Modifiers.None).Problem(Feature.Screen, Defaults));
        Assert.Equal("Add Shift", new KeyShortcut('C', Modifiers.Control).Problem(Feature.Screen, Defaults));
        Assert.Equal("Add Shift", new KeyShortcut(0x73, Modifiers.Alt).Problem(Feature.Screen, Defaults));
        Assert.Equal("Win+Ctrl is for the clipboard", new KeyShortcut('3', WinShift | Modifiers.Control).Problem(Feature.Screen, Defaults));
        Assert.Null(new KeyShortcut('3', CtrlShift).Problem(Feature.Screen, Defaults));
        Assert.Null(new KeyShortcut('X', Modifiers.Win | Modifiers.Alt).Problem(Feature.Window, Defaults));
    }

    [Fact]
    public void AShortcutAlreadyTakenIsRefusedByName()
    {
        Assert.Equal("Used by Windows", new KeyShortcut('S', WinShift).Problem(Feature.Window, Defaults));
        Assert.Equal("Used by Screen", new KeyShortcut('3', WinShift).Problem(Feature.Window, Defaults));
        Assert.Equal("Used by History", new KeyShortcut('8', WinShift).Problem(Feature.Text, Defaults));
        // Keeping the one it has is no conflict.
        Assert.Null(new KeyShortcut('3', WinShift).Problem(Feature.Screen, Defaults));
    }

    [Fact]
    public void TwoCapturesCannotShareAClipboardShortcut()
    {
        // Ctrl+Shift+3 would send to the clipboard with Win+Ctrl+Shift+3 — which
        // is where Win+Shift+3 already sends.
        Assert.Equal("Used by Screen", new KeyShortcut('3', CtrlShift).Problem(Feature.Window, Defaults));
    }

    [Theory]
    [InlineData(0x70, "F1")]
    [InlineData(0x7B, "F12")]
    [InlineData(0x20, "Space")]
    [InlineData(0x2C, "PrtSc")]
    [InlineData('A', "A")]
    [InlineData(0x60, "Num 0")]
    public void KeysAreNamedAsTheKeyboardPrintsThem(int key, string expected)
    {
        Assert.Equal(expected, KeyShortcut.KeyName(key));
    }

    [Fact]
    public void ModifiersAreWrittenInWindowsOrder()
    {
        Assert.Equal("Win+Ctrl+Alt+Shift+", KeyShortcut.Describe(Modifiers.Shift | Modifiers.Alt | Modifiers.Control | Modifiers.Win));
        Assert.Equal("", KeyShortcut.Describe(Modifiers.None));
        Assert.Equal(Modifiers.Win, KeyShortcut.ModifierOf(0x5C));
        Assert.Equal(Modifiers.Control, KeyShortcut.ModifierOf(0xA2));
        Assert.False(KeyShortcut.IsModifier('3'));
    }
}

public class DisplayTests
{
    private static readonly Rect Left = new(0, 0, 1920, 1080);
    private static readonly Rect Right = new(1920, 0, 1920, 1080);

    [Fact]
    public void ThePointerIsOnTheDisplayThatContainsIt()
    {
        Assert.Equal(0, Displays.IndexAt(new Point(100, 100), [Left, Right], 0));
        Assert.Equal(1, Displays.IndexAt(new Point(2500, 500), [Left, Right], 0));
        // The shared edge belongs to the display on the right, as Windows has it.
        Assert.Equal(1, Displays.IndexAt(new Point(1920, 500), [Left, Right], 0));
        Assert.Equal(0, Displays.IndexAt(new Point(1919, 1079), [Left, Right], 1));
    }

    [Fact]
    public void OffEveryDisplayItFallsBackRatherThanFailing()
    {
        Assert.Equal(1, Displays.IndexAt(new Point(-50, -50), [Left, Right], 1));
        Assert.Equal(1, Displays.IndexAt(new Point(-50, -50), [Left, Right], 7));
        Assert.Equal(0, Displays.IndexAt(new Point(5, 5), [], 3));
    }

    [Fact]
    public void TheMapKeepsTheArrangementAndItsProportions()
    {
        var fitted = DisplayMapLayout.Fit([Left, Right], new Point(2880, 540), new Size(274, 88), 4);
        var (a, b) = (fitted.Rects[0], fitted.Rects[1]);
        Assert.Equal(1920.0 / 1080, a.Width / a.Height, 3);
        Assert.Equal(a.Right, b.Left, 6);
        Assert.Equal(a.Top, b.Top, 6);
        // Centred in the space left over.
        Assert.Equal(a.Left, 274 - b.Right, 6);
        Assert.True(a.Top >= 4 && b.Bottom <= 84.0001);
        // The pointer lands in the middle of the display it is really on.
        Assert.Equal(b.Left + b.Width / 2, fitted.Pointer!.Value.X, 6);
        Assert.Equal(b.Top + b.Height / 2, fitted.Pointer!.Value.Y, 6);
    }

    [Fact]
    public void ADisplayAboveAndToTheLeftStaysThere()
    {
        var fitted = DisplayMapLayout.Fit([new Rect(0, 0, 1920, 1080), new Rect(-1280, -1024, 1280, 1024)], null, new Size(274, 88), 4);
        Assert.True(fitted.Rects[1].Right <= fitted.Rects[0].Left + 0.001);
        Assert.True(fitted.Rects[1].Bottom <= fitted.Rects[0].Top + 0.001);
        Assert.Null(fitted.Pointer);
    }

    [Fact]
    public void NoDisplaysIsAnEmptyMap()
    {
        Assert.Empty(DisplayMapLayout.Fit([], new Point(1, 1), new Size(274, 88), 4).Rects);
    }

    [Theory]
    [InlineData("Built-in Display", 26, "Built-in")]
    [InlineData("DELL U2723QE", 26, "DELL U2723QE")]
    [InlineData("An Extraordinarily Long Monitor Name", 16, "An Extraordinar…")]
    public void DisplayNamesStayShort(string name, int max, string expected)
    {
        Assert.Equal(expected, PanelWindow.ShortName(name, max));
    }
}

public class CaptureTests
{
    private static Native.RECT Frame(int left, int top, int right, int bottom) =>
        new() { Left = left, Top = top, Right = right, Bottom = bottom };

    [Fact]
    public void OnlyRealVisibleWindowsOfOtherAppsAreCaptured()
    {
        var frame = Frame(0, 0, 800, 600);
        Assert.True(WindowUnderPointer.Qualifies("Chrome_WidgetWin_1", isOwn: false, isVisible: true, frame));
        Assert.False(WindowUnderPointer.Qualifies("Chrome_WidgetWin_1", isOwn: true, isVisible: true, frame));
        Assert.False(WindowUnderPointer.Qualifies("Chrome_WidgetWin_1", isOwn: false, isVisible: false, frame));
        Assert.False(WindowUnderPointer.Qualifies("Chrome_WidgetWin_1", isOwn: false, isVisible: true, null));
    }

    [Theory]
    [InlineData("Progman")]
    [InlineData("WorkerW")]
    [InlineData("Shell_TrayWnd")]
    [InlineData("Shell_SecondaryTrayWnd")]
    [InlineData("#32768")]
    public void TheDesktopTheTaskbarAndMenusAreNoWindow(string className)
    {
        Assert.False(WindowUnderPointer.Qualifies(className, isOwn: false, isVisible: true, Frame(0, 0, 800, 600)));
    }

    [Fact]
    public void ATooltipSizedWindowIsNotOneAnyoneMeansToCapture()
    {
        Assert.False(WindowUnderPointer.Qualifies("tooltips_class32", false, true, Frame(0, 0, 200, 39)));
        Assert.True(WindowUnderPointer.Qualifies("Notepad", false, true, Frame(0, 0, 40, 40)));
    }

    [Fact]
    public void AMaximisedWindowLosesItsOverhangAndNothingElse()
    {
        var display = new Rect(0, 0, 1920, 1080);
        var trimmed = WindowUnderPointer.Trimmed(Frame(-1, -1, 1921, 1081), display);
        Assert.Equal((0, 0, 1920, 1080), (trimmed.Left, trimmed.Top, trimmed.Right, trimmed.Bottom));
        // A window that really straddles two displays is left whole.
        var straddling = WindowUnderPointer.Trimmed(Frame(1500, 100, 2400, 700), display);
        Assert.Equal((1500, 100, 2400, 700), (straddling.Left, straddling.Top, straddling.Right, straddling.Bottom));
    }

    [Theory]
    [InlineData(1920, 1080, 232 + 8, 130.5 + 8)]
    [InlineData(1080, 1920, 84.375 + 8, 150 + 8)]
    [InlineData(4000, 100, 232 + 8, 56 + 8)]
    [InlineData(0, 0, 232, 150)]
    public void ThePreviewKeepsTheCapturesShapeInsideItsBox(double width, double height, double cardWidth, double cardHeight)
    {
        var size = CapturePreview.SizeFor(width, height);
        Assert.Equal(cardWidth, size.Width, 3);
        Assert.Equal(cardHeight, size.Height, 3);
    }

    [Theory]
    [InlineData(400, 60, 3)]
    [InlineData(800, 300, 2)]
    [InlineData(1800, 1000, 2)]
    [InlineData(3000, 1500, 1)]
    public void SmallCapturesAreEnlargedBeforeReading(int width, int height, int expected)
    {
        Assert.Equal(expected, TextRecognizer.Factor(width, height));
    }
}

public class UpdaterTests
{
    private static JsonElement Releases(string json) => JsonDocument.Parse(json).RootElement;

    private const string Feed = """
        [
          {"tag_name":"v1.9.0","draft":false,"prerelease":false,"assets":[{"name":"ScreenHere.dmg","browser_download_url":"https://github.com/adrbn/screenhere/releases/download/v1.9.0/ScreenHere.dmg"}]},
          {"tag_name":"v1.8.1","draft":false,"prerelease":false,"assets":[{"name":"ScreenHere-Windows.exe","browser_download_url":"https://github.com/adrbn/screenhere/releases/download/v1.8.1/ScreenHere-Windows.exe"}]},
          {"tag_name":"v1.8.0","draft":false,"prerelease":false,"assets":[{"name":"ScreenHere-Windows.exe","browser_download_url":"https://github.com/adrbn/screenhere/releases/download/v1.8.0/ScreenHere-Windows.exe"}]},
          {"tag_name":"v2.0.0","draft":false,"prerelease":true,"assets":[{"name":"ScreenHere-Windows.exe","browser_download_url":"https://github.com/adrbn/screenhere/releases/download/v2.0.0/ScreenHere-Windows.exe"}]}
        ]
        """;

    [Fact]
    public void TheNewestReleaseWithAWindowsBuildIsOffered()
    {
        var found = Updater.Newest(Releases(Feed), "1.7.0");
        Assert.Equal("1.8.1", found!.Value.Version);
        Assert.EndsWith("/v1.8.1/ScreenHere-Windows.exe", found.Value.Url);
    }

    [Fact]
    public void NothingIsOfferedWhenUpToDateOrWhenOnlyTheMacMoved()
    {
        Assert.Null(Updater.Newest(Releases(Feed), "1.8.1"));
        Assert.Null(Updater.Newest(Releases(Feed), "1.9.0"));
    }

    [Fact]
    public void ADownloadFromAnywhereElseIsNotAnUpdate()
    {
        var feed = """[{"tag_name":"v9.0.0","assets":[{"name":"ScreenHere-Windows.exe","browser_download_url":"https://example.com/ScreenHere-Windows.exe"}]}]""";
        Assert.Null(Updater.Newest(Releases(feed), "1.7.0"));
    }
}
