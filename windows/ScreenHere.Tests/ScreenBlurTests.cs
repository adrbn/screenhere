using System.Windows;

namespace ScreenHere.Tests;

/// Which screens get frosted, and when: everything but the one the pointer is
/// on, a moment after it leaves.
public class ScreenBlurTests
{
    private static readonly DateTime Now = new(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
    private const double Delay = 1.5;

    private static DisplayInfo Display(string device, double x) =>
        new(IntPtr.Zero, device, new Rect(x, 0, 1920, 1080), new Rect(x, 0, 1920, 1040), x == 0);

    private static readonly DisplayInfo Left = Display(@"\\.\DISPLAY1", 0);
    private static readonly DisplayInfo Right = Display(@"\\.\DISPLAY2", 1920);
    private static readonly DisplayInfo Third = Display(@"\\.\DISPLAY3", 3840);

    private static HashSet<string> Covered(IReadOnlyList<DisplayInfo> displays, Point pointer,
                                           Dictionary<string, DateTime>? lastSeen = null) =>
        ScreenBlur.Covered(displays, pointer, lastSeen ?? [], Now, Delay);

    /// One display is the screen you are on; there is nothing beside it.
    [Fact]
    public void ASingleDisplayIsNeverFrosted()
    {
        Assert.Empty(Covered([Left], new Point(10, 10)));
    }

    /// A screen never visited is frosted at once: at launch, only the one
    /// under the pointer is clear.
    [Fact]
    public void EveryOtherScreenStartsFrosted()
    {
        Assert.Equal([Right.Device, Third.Device],
                     Covered([Left, Right, Third], new Point(10, 10)).Order());
    }

    /// The screen under the pointer is clear even when it was left a moment
    /// ago and came back.
    [Fact]
    public void TheScreenUnderThePointerIsClear()
    {
        var seen = new Dictionary<string, DateTime>
        {
            [Left.Device] = Now.AddSeconds(-60),
            [Right.Device] = Now,
        };
        Assert.Equal([Left.Device], Covered([Left, Right], new Point(2000, 10), seen));
    }

    /// Glancing at the other screen must not frost the one just left.
    [Fact]
    public void TheScreenJustLeftIsStillClear()
    {
        var seen = new Dictionary<string, DateTime>
        {
            [Left.Device] = Now,
            [Right.Device] = Now.AddSeconds(-10),
        };
        Assert.Empty(Covered([Left, Right], new Point(2000, 10), seen));
    }

    [Fact]
    public void TheScreenLeftLongEnoughIsFrosted()
    {
        var seen = new Dictionary<string, DateTime> { [Left.Device] = Now.AddSeconds(-Delay) };
        Assert.Equal([Left.Device], Covered([Left, Right], new Point(2000, 10), seen));
    }

    /// Between two displays — a gap in an odd arrangement — frosting the
    /// screen being used would be worse than frosting nothing.
    [Fact]
    public void NothingIsFrostedWhenThePointerIsOnNoDisplay()
    {
        Assert.Empty(Covered([Left, Right], new Point(-500, 10)));
    }

    /// The right edge belongs to the next display: a pointer at x=1920 is on
    /// the right screen, not on both.
    [Fact]
    public void TheRightEdgeBelongsToTheNextDisplay()
    {
        Assert.Equal([Left.Device], Covered([Left, Right], new Point(1920, 10)));
    }
}
