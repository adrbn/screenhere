using System.IO;
using System.Text;

namespace ScreenHere.Tests;

public class ClipboardHistoryTests
{
    private static readonly DateTime Now = new(2026, 10, 8, 12, 0, 0);

    [Fact]
    public void NewestComesFirst()
    {
        var history = ClipboardHistory.Empty.Adding("one", null, Now).Adding("two", null, Now);
        Assert.Equal(["two", "one"], history.Items.Select(i => i.Text));
    }

    [Fact]
    public void CopyingTheSameTextAgainMovesItToTheTop()
    {
        var history = ClipboardHistory.Empty.Adding("one", null, Now).Adding("two", null, Now).Adding("one", "Notepad", Now);
        Assert.Equal(["one", "two"], history.Items.Select(i => i.Text));
        Assert.Equal("Notepad", history.Items[0].Source);
    }

    [Fact]
    public void BlankAndOversizedTextIsSkippedNeverTruncated()
    {
        var history = ClipboardHistory.Empty.Adding("  \n ", null, Now).Adding(new string('x', ClipboardHistory.MaxLength + 1), null, Now);
        Assert.Empty(history.Items);
    }

    [Fact]
    public void KeepsOnlyTheCapacity()
    {
        var history = ClipboardHistory.Empty;
        for (var i = 0; i < ClipboardHistory.Capacity + 20; i++) history = history.Adding($"item {i}", null, Now);
        Assert.Equal(ClipboardHistory.Capacity, history.Items.Count);
        Assert.Equal($"item {ClipboardHistory.Capacity + 19}", history.Items[0].Text);
    }

    [Fact]
    public void PastTheImageBudgetTheOldestPicturesGoAndTheTextStays()
    {
        var big = ClipboardHistory.MaxImageBytes;
        var history = ClipboardHistory.Empty.Adding("kept", null, Now);
        for (var i = 0; i < 6; i++) history = history.Adding(new ClipImage($"d{i}", 10, 10, big), null, Now);
        Assert.Equal(["d5", "d4", "d3", "d2"], history.Items.Where(i => i.Image != null).Select(i => i.Image!.Digest));
        Assert.Contains(history.Items, i => i.Text == "kept");
    }

    [Fact]
    public void APictureTooBigOnItsOwnIsRefused()
    {
        var history = ClipboardHistory.Empty.Adding(new ClipImage("d", 10, 10, ClipboardHistory.MaxImageBytes + 1), null, Now);
        Assert.Empty(history.Items);
    }

    [Fact]
    public void TheSameFilesCopiedTwiceAreOneEntry()
    {
        var files = new[] { new ClipFile(@"C:\a.txt"), new ClipFile(@"C:\b.txt") };
        var history = ClipboardHistory.Empty.Adding(files, null, Now).Adding([new ClipFile(@"C:\a.txt"), new ClipFile(@"C:\b.txt")], null, Now);
        Assert.Single(history.Items);
    }

    [Fact]
    public void SearchIgnoresCaseAndAccentsAndWantsEveryWord()
    {
        var history = ClipboardHistory.Empty
            .Adding("Déjà vu à côté", null, Now)
            .Adding("something else", null, Now)
            .Adding(new ClipImage("d", 1920, 1080, 10), "Edge", Now)
            .Adding([new ClipFile(@"C:\Users\me\Downloads\Harbor contract.pdf")], "Explorer", Now);
        Assert.Equal("Déjà vu à côté", Assert.Single(history.Matching("deja COTE")).Text);
        Assert.Empty(history.Matching("deja missing"));
        Assert.NotNull(Assert.Single(history.Matching("image edge")).Image);
        Assert.NotNull(Assert.Single(history.Matching("downloads harbor")).Files);
        Assert.Equal(4, history.Matching("  ").Count);
    }

    [Fact]
    public void AFileKnowsItsNameAndItsFolderFromHome()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var file = new ClipFile(Path.Combine(home, "Downloads", "Harbor contract.pdf"));
        Assert.Equal("Harbor contract.pdf", file.Name);
        Assert.Equal(@"~\Downloads", file.Folder);
        Assert.Equal(@"D:\Work", new ClipFile(@"D:\Work\notes.txt").Folder);
    }

    [Fact]
    public void TheStoreRoundTripsEveryKind()
    {
        var folder = Directory.CreateTempSubdirectory("screenhere-tests").FullName;
        var store = new ClipboardHistoryStore(folder);
        var history = ClipboardHistory.Empty
            .Adding("text", "Notepad", Now)
            .Adding(new ClipImage("abc", 3, 4, 5), null, Now)
            .Adding([new ClipFile(@"C:\a.txt")], "Explorer", Now);
        store.Save(history);
        var loaded = store.Load();
        Assert.Equal(3, loaded.Items.Count);
        Assert.Equal(@"C:\a.txt", loaded.Items[0].Files![0].Path);
        Assert.Equal(new ClipImage("abc", 3, 4, 5), loaded.Items[1].Image);
        Assert.Equal("text", loaded.Items[2].Text);
        Assert.Equal(history.Items[2].Id, loaded.Items[2].Id);
    }

    [Fact]
    public void OneUnreadableEntryCostsThatEntryNotTheHistory()
    {
        var folder = Directory.CreateTempSubdirectory("screenhere-tests").FullName;
        File.WriteAllText(Path.Combine(folder, "history.json"),
            """{"items":[{"Id":"not-a-guid","Text":"broken"},{"Date":"2026-10-08T12:00:00"},{"Id":"0a0a0a0a-0000-0000-0000-000000000001","Text":"fine","Date":"2026-10-08T12:00:00"}]}""",
            Encoding.UTF8);
        Assert.Equal("fine", Assert.Single(new ClipboardHistoryStore(folder).Load().Items).Text);
    }

    [Fact]
    public void AMissingOrTornFileIsAnEmptyHistory()
    {
        var folder = Directory.CreateTempSubdirectory("screenhere-tests").FullName;
        Assert.Empty(new ClipboardHistoryStore(folder).Load().Items);
        File.WriteAllText(Path.Combine(folder, "history.json"), "{\"items\":[{\"Id\"");
        Assert.Empty(new ClipboardHistoryStore(folder).Load().Items);
    }

    [Theory]
    [InlineData(16, "16 sec. ago")]
    [InlineData(5 * 60, "5 min. ago")]
    [InlineData(2 * 3600, "2 hr. ago")]
    [InlineData(30 * 3600, "1 day ago")]
    [InlineData(3 * 86400, "3 days ago")]
    [InlineData(15 * 86400, "2 wk. ago")]
    [InlineData(90 * 86400, "3 mo. ago")]
    [InlineData(800 * 86400, "2 yr. ago")]
    public void TimeReadsShortAndInEnglish(int seconds, string expected)
    {
        Assert.Equal(expected, RelativeTime.Describe(Now.AddSeconds(-seconds), Now));
    }

    [Fact]
    public void ACopyFromTheFutureIsJustNow()
    {
        Assert.Equal("0 sec. ago", RelativeTime.Describe(Now.AddMinutes(5), Now));
    }

    [Fact]
    public void RowsCollapseWhitespaceAndNameFiles()
    {
        Assert.Equal("a b c", HistoryWindow.RowTitle(new ClipItem { Text = "a\n\n  b\tc" }));
        Assert.Equal("Image", HistoryWindow.RowTitle(new ClipItem { Image = new ClipImage("d", 1, 1, 1) }));
        Assert.Equal("a.txt + 2 more", HistoryWindow.RowTitle(new ClipItem { Files = [new(@"C:\a.txt"), new(@"C:\b.txt"), new(@"C:\c.txt")] }));
        Assert.Equal("1920 × 1080 · Edge · 16 sec. ago",
            HistoryWindow.Subtitle(new ClipItem { Image = new ClipImage("d", 1920, 1080, 1), Source = "Edge", Date = Now.AddSeconds(-16) }, Now));
    }
}

public class ClipboardFilterTests
{
    [Fact]
    public void FilesWinOverTextAndTextOverPictures()
    {
        Assert.Equal(ClipboardFilter.Kind.Files, ClipboardFilter.KindOf(["FileDrop", "UnicodeText", "Bitmap"]));
        Assert.Equal(ClipboardFilter.Kind.Text, ClipboardFilter.KindOf(["UnicodeText", "Bitmap", "HTML Format"]));
        Assert.Equal(ClipboardFilter.Kind.Image, ClipboardFilter.KindOf(["PNG", "DeviceIndependentBitmap"]));
        Assert.Null(ClipboardFilter.KindOf(["Some Private Format"]));
    }

    [Fact]
    public void CopiesMarkedPrivateAreNeverKept()
    {
        Assert.Null(ClipboardFilter.KindOf(["UnicodeText", "ExcludeClipboardContentFromMonitorProcessing"]));
        Assert.Null(ClipboardFilter.KindOf(["UnicodeText", "Clipboard Viewer Ignore"]));
        Assert.Null(ClipboardFilter.KindOf(["UnicodeText"], excludedFromHistory: true));
    }

    [Theory]
    [InlineData("https://example.com/a.png", true)]
    [InlineData("  http://example.com  ", true)]
    [InlineData("see https://example.com", false)]
    [InlineData("ftp://example.com", false)]
    [InlineData("hello", false)]
    public void ALinkIsOneAddressAndNothingElse(string text, bool expected)
    {
        Assert.Equal(expected, ClipboardFilter.IsLink(text));
    }

    [Theory]
    [InlineData("Network: Harbor Guest Password: blue-harbor-72", "Copied 7 words")]
    [InlineData("Bonjour", "Copied 1 word")]
    [InlineData(" … ", "No text found")]
    public void TheToastCountsWords(string text, string expected)
    {
        Assert.Equal(expected, TextCaptureStrings.Copied(text));
    }
}
