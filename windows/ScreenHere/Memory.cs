using System.Diagnostics;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace ScreenHere;

/// A tray app spends nearly all its time doing nothing, and should weigh
/// next to nothing while it does. A capture is tens of megabytes of pixels for
/// a second; once things have gone quiet, they are handed back to Windows.
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
            try
            {
                using var process = Process.GetCurrentProcess();
                EmptyWorkingSet(process.Handle);
            }
            catch
            {
            }
        };
        return made;
    }

    [DllImport("psapi.dll")] private static extern bool EmptyWorkingSet(IntPtr process);
}
