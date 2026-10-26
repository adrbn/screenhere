using System.Runtime;
using System.Windows.Threading;

namespace ScreenHere;

/// A tray app spends nearly all its time doing nothing, and should weigh
/// next to nothing while it does. A capture is tens of megabytes of pixels for
/// a second; once things have gone quiet, they are collected.
///
/// What is no longer done here is emptying the working set. Handing every page
/// back to Windows read well in Task Manager, but the next panel or list then
/// read itself back from disk — with an antivirus between the two, that is
/// seconds of nothing before anything appears, which is what the app being
/// slow to open looked like from the outside.
internal static class Memory
{
    private static DispatcherTimer? timer;

    /// Asks for a clean-up once nothing has happened for a while. Asking
    /// again pushes it back, so it never runs in the middle of anything.
    public static void SettleSoon(double seconds = 8)
    {
        timer ??= Make();
        timer.Stop();
        timer.Interval = TimeSpan.FromSeconds(seconds);
        timer.Start();
    }

    private static DispatcherTimer Make()
    {
        var made = new DispatcherTimer();
        made.Tick += (_, _) =>
        {
            made.Stop();
            // Not while a window is up: it would only be paged back in.
            // Nor with a connection up: its pages are in use all the time.
            if (PanelWindow.IsOpen || HistoryWindow.IsOpen || SyncController.Shared.IsConnected)
            {
                SettleSoon();
                return;
            }
            GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
        };
        return made;
    }
}
