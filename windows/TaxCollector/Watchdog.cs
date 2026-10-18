using System.Diagnostics;

namespace TaxCollector;

/// Two processes guard each other through named mutexes: the app and a small
/// watchdog. Each holds its own "alive" mutex; each watches for the other's to
/// disappear and relaunches it. Killing one brings it straight back; killing both
/// leaves the scheduled task to restart the app within a minute, which then
/// restarts the watchdog.
internal static class Watchdog
{
    private const string AppAlive = @"Global\TaxCollector.App.Alive";
    private const string WatchAlive = @"Global\TaxCollector.Watch.Alive";

    /// The app holds this for its lifetime; also the single-instance guard.
    public static Mutex? HoldAppAlive(out bool createdNew)
    {
        try { return new Mutex(initiallyOwned: true, AppAlive, out createdNew); }
        catch { createdNew = true; return null; }
    }

    /// Called by the running app: make sure a watchdog is up, and keep it up.
    public static void EnsureWatchdogLoop(CancellationToken token)
    {
        _ = System.Threading.Tasks.Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                if (!MutexHeld(WatchAlive)) LaunchSelf("--watchdog");
                try { await System.Threading.Tasks.Task.Delay(2000, token); } catch { break; }
            }
        });
    }

    /// The watchdog process: hold the watch mutex, relaunch the app if it vanishes.
    public static int RunWatchdog()
    {
        Mutex? mine;
        bool createdNew;
        try { mine = new Mutex(initiallyOwned: true, WatchAlive, out createdNew); }
        catch { return 0; }
        if (!createdNew) return 0; // another watchdog already running
        using (mine)
        {
            while (true)
            {
                if (!MutexHeld(AppAlive)) LaunchApp();
                Thread.Sleep(2000);
            }
        }
    }

    private static bool MutexHeld(string name)
    {
        try { using var m = Mutex.OpenExisting(name); return true; }
        catch (WaitHandleCannotBeOpenedException) { return false; }
        catch { return true; } // err on the side of "alive" so we don't spawn duplicates
    }

    private static void LaunchApp()
    {
        var exe = File.Exists(Setup.InstallExe) ? Setup.InstallExe : (Environment.ProcessPath ?? "");
        if (exe.Length == 0) return;
        try { Process.Start(new ProcessStartInfo(exe, "--task") { UseShellExecute = false }); } catch { }
    }

    private static void LaunchSelf(string arg)
    {
        var exe = Environment.ProcessPath ?? (File.Exists(Setup.InstallExe) ? Setup.InstallExe : "");
        if (exe.Length == 0) return;
        try { Process.Start(new ProcessStartInfo(exe, arg) { UseShellExecute = false, CreateNoWindow = true }); } catch { }
    }
}
