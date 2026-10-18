using TaxCollector;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        // Helper modes that aren't the tray app.
        if (Array.IndexOf(args, "--watchdog") >= 0) return Watchdog.RunWatchdog();
        var install = Array.IndexOf(args, "--install");
        if (install >= 0 && args.Length > install + 1) return Setup.Install(args[install + 1]);

        var selftest = Array.IndexOf(args, "--selftest") >= 0
                       || Environment.GetEnvironmentVariable("TAXCOLLECTOR_SELFTEST") == "1";
        if (selftest) return SelfTest.RunAndReport();

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        try { Application.SetHighDpiMode(HighDpiMode.PerMonitorV2); } catch { }

        var testing = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("TAXCOLLECTOR_DATA_DIR"));
        var dryRun = Environment.GetEnvironmentVariable("TAXCOLLECTOR_DRY_RUN") == "1";
        var startedByTask = Array.IndexOf(args, "--task") >= 0;

        Mutex? appMutex = null;
        var cts = new CancellationTokenSource();
        if (!testing)
        {
            appMutex = Watchdog.HoldAppAlive(out var createdNew);
            if (!createdNew) return 0; // another instance already owns the app
            if (!dryRun) Watchdog.EnsureWatchdogLoop(cts.Token);
        }

        try
        {
            using var ctx = new TrayApp(dryRun, testing, startedByTask);
            Application.Run(ctx);
        }
        finally
        {
            cts.Cancel();
            GC.KeepAlive(appMutex);
        }
        return 0;
    }
}
